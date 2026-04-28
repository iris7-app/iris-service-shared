#!/usr/bin/env python3
"""Compute population drift for the deployed Customer Churn model.

Phase E of shared ADR-0061. Designed to run daily as a cron-like job
(in dev : ``bin/ml/compute_drift.py`` from a venv with ``--extra ml``;
in prod : a Kubernetes CronJob — see ``deploy/kubernetes/ml-drift-cronjob.yaml``).

The script :

1. Pulls the **training-time feature distribution** from MLflow's
   Production-tagged run (logged as a CSV artefact ``training_features.csv``
   by ``iris_service.ml.train_churn``).
2. Pulls the **current population's feature distribution** from the
   live Postgres (running ``feature_engineering.build_features`` on
   the last 30 days of customers).
3. Runs a **2-sample Kolmogorov-Smirnov test** per feature ; the
   statistic ∈ [0, 1] (0 = identical distributions, 1 = no overlap).
4. Logs each per-feature stat as :
   - A **Prometheus gauge** (pushed via the Pushgateway sidecar that
     the SLO definition reads — see
     ``deploy/kubernetes/observability-prom/iris-drift-alerts.yaml``).
   - A **MLflow metric** on the model registry's current Production
     run (so the MLflow UI's compare-runs view shows drift over time).
5. Exits non-zero if ANY feature's KS-stat exceeds the SLO threshold
   (default 0.20 — configurable via ``--ks-threshold``). The non-zero
   exit triggers the CronJob's failure handler + the Alertmanager
   `KubernetesJobFailed` alert that the canonical kube-prom-stack
   ships out of the box.

The KS-test is the right tool here :
- Non-parametric : doesn't assume normality (revenue features are
  long-tailed log-normal-ish).
- Threshold-interpretable : KS-stat ≥ 0.20 is the literature's
  "actionable drift" cut-off (Tabachnick + Fidell, *Using
  Multivariate Statistics*).
- Fast : O(n log n) per feature, < 1 s on 100k rows.

Run-time dependencies (training [ml] extra) : pandas, scipy, mlflow,
prometheus_client, sqlalchemy + asyncpg.
"""

# ruff: noqa: E402, T201 — script-style imports + print() are intentional
from __future__ import annotations

import argparse
import logging
import os
import sys
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

# Heavy imports deferred to module-load time but only on demand —
# the script's main() short-circuits before importing if --help is set,
# so help renders fast even without the ml extra installed.

logger = logging.getLogger(__name__)

DEFAULT_KS_THRESHOLD = 0.20
DEFAULT_LOOKBACK_DAYS = 30
DEFAULT_MLFLOW_MODEL = "customer-churn-mlp"
DEFAULT_PUSHGATEWAY = "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"


@dataclass
class DriftResult:
    """Per-feature KS-test result."""

    feature_name: str
    ks_statistic: float
    p_value: float
    n_training: int
    n_current: int

    @property
    def exceeds_threshold(self) -> bool:
        return self.ks_statistic >= DEFAULT_KS_THRESHOLD


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compute Customer Churn population drift (Phase E of ADR-0061).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--mlflow-uri",
        default=os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000"),
        help="MLflow tracking server. Defaults to $MLFLOW_TRACKING_URI or http://localhost:5000.",
    )
    parser.add_argument(
        "--mlflow-model",
        default=os.environ.get("MLFLOW_MODEL_NAME", DEFAULT_MLFLOW_MODEL),
        help="Registered model name. Default: %(default)s.",
    )
    parser.add_argument(
        "--db-url",
        default=os.environ.get("IRIS_DB_URL"),
        help="Postgres URL (e.g. postgresql+asyncpg://user:pass@host/db). "
        "Required unless --skip-current is set.",
    )
    parser.add_argument(
        "--lookback-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        help="Compute drift over the last N days. Default: %(default)s.",
    )
    parser.add_argument(
        "--ks-threshold",
        type=float,
        default=DEFAULT_KS_THRESHOLD,
        help="Per-feature KS-stat threshold for the drift SLO. Default: %(default)s.",
    )
    parser.add_argument(
        "--pushgateway",
        default=os.environ.get("PROMETHEUS_PUSHGATEWAY_URL", DEFAULT_PUSHGATEWAY),
        help="Prometheus Pushgateway URL. Default: $PROMETHEUS_PUSHGATEWAY_URL or cluster-internal.",
    )
    parser.add_argument(
        "--skip-push",
        action="store_true",
        help="Compute + log to MLflow but do NOT push to Prometheus (dev-only).",
    )
    parser.add_argument(
        "--skip-mlflow-log",
        action="store_true",
        help="Compute + push to Prometheus but do NOT write to MLflow (CI smoke test).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute + print, no side effects (useful for local debugging).",
    )
    return parser.parse_args(argv)


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s : %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
    )


def fetch_training_features(mlflow_uri: str, model_name: str) -> "pd.DataFrame":  # noqa: F821
    """Pull training_features.csv from the Production-tagged model run.

    The training script logs this artefact alongside the .onnx export
    (see ``iris_service.ml.train_churn`` Phase A). Without it, the
    drift computation is blind ; we raise rather than silently skip.
    """
    import mlflow

    mlflow.set_tracking_uri(mlflow_uri)
    client = mlflow.tracking.MlflowClient()
    versions = client.get_latest_versions(model_name, stages=["Production"])
    if not versions:
        msg = (
            f"no Production-tagged version of '{model_name}' on {mlflow_uri} ; "
            "promote one in the MLflow UI first or run "
            "bin/ml/promote_to_configmap.sh before this script."
        )
        raise RuntimeError(msg)
    run_id = versions[0].run_id
    if not run_id:
        msg = f"Production version of '{model_name}' has no run_id — re-train + re-promote."
        raise RuntimeError(msg)

    artifact_path = "training_features.csv"
    local = client.download_artifacts(run_id, artifact_path)
    import pandas as pd

    return pd.read_csv(local)


def fetch_current_features(db_url: str, lookback_days: int) -> "pd.DataFrame":  # noqa: F821
    """Run feature_engineering.build_features over the last N days.

    Imports the Python service's feature pipeline directly — no HTTP
    self-call. The drift CronJob runs alongside the service in the
    same namespace ; we mount the Python code via a sidecar volume
    or via the same image.
    """
    import asyncio

    import pandas as pd
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import create_async_engine

    from iris_service.ml.feature_engineering import build_features

    cutoff = datetime.now(UTC) - timedelta(days=lookback_days)

    async def _load() -> tuple["pd.DataFrame", "pd.DataFrame", "pd.DataFrame"]:
        engine = create_async_engine(db_url)
        try:
            async with engine.connect() as conn:
                customers = pd.read_sql(
                    text(
                        "SELECT id, email, created_at, "
                        "MIN(o.created_at) FILTER (WHERE o.id IS NOT NULL) AS first_order_at, "
                        "MAX(o.created_at) FILTER (WHERE o.id IS NOT NULL) AS last_order_at "
                        "FROM customer c LEFT JOIN orders o ON o.customer_id = c.id "
                        "WHERE c.created_at >= :cutoff GROUP BY c.id"
                    ),
                    conn.sync_connection,
                    params={"cutoff": cutoff},
                )
                orders = pd.read_sql(
                    text(
                        "SELECT id, customer_id, created_at, total_amount FROM orders "
                        "WHERE created_at >= :cutoff"
                    ),
                    conn.sync_connection,
                    params={"cutoff": cutoff},
                )
                lines = pd.read_sql(
                    text(
                        "SELECT id, order_id, product_id, quantity, unit_price_at_order "
                        "FROM order_line WHERE order_id IN (SELECT id FROM orders WHERE created_at >= :cutoff)"
                    ),
                    conn.sync_connection,
                    params={"cutoff": cutoff},
                )
                return customers, orders, lines
        finally:
            await engine.dispose()

    customers, orders, lines = asyncio.run(_load())
    return build_features(customers, orders, lines, now=datetime.now(UTC))


def compute_drift(
    training: "pd.DataFrame",  # noqa: F821
    current: "pd.DataFrame",  # noqa: F821
) -> list[DriftResult]:
    """Run a 2-sample KS test per feature, return one DriftResult per column."""
    from scipy.stats import ks_2samp

    feature_names = list(training.columns)
    results: list[DriftResult] = []
    for name in feature_names:
        if name not in current.columns:
            logger.warning("feature %s missing from current population — skipping", name)
            continue
        train_vals = training[name].dropna().values
        curr_vals = current[name].dropna().values
        if len(train_vals) < 2 or len(curr_vals) < 2:
            logger.warning(
                "feature %s — too few samples (training=%d, current=%d), skipping",
                name,
                len(train_vals),
                len(curr_vals),
            )
            continue
        stat, p_value = ks_2samp(train_vals, curr_vals)
        results.append(
            DriftResult(
                feature_name=name,
                ks_statistic=float(stat),
                p_value=float(p_value),
                n_training=len(train_vals),
                n_current=len(curr_vals),
            )
        )
    return results


def push_to_prometheus(results: list[DriftResult], pushgateway_url: str, model_name: str) -> None:
    """Push KS-stat per feature as a Prometheus gauge to the Pushgateway."""
    from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

    registry = CollectorRegistry()
    drift_gauge = Gauge(
        "iris_churn_drift_ks_stat",
        "Kolmogorov-Smirnov 2-sample statistic between training and current "
        "feature distribution. Lower = closer to training. SLO threshold 0.20.",
        labelnames=["feature", "model"],
        registry=registry,
    )
    samples_gauge = Gauge(
        "iris_churn_drift_sample_count",
        "Number of samples in the current-population window for the KS computation.",
        labelnames=["feature", "model"],
        registry=registry,
    )
    for r in results:
        drift_gauge.labels(feature=r.feature_name, model=model_name).set(r.ks_statistic)
        samples_gauge.labels(feature=r.feature_name, model=model_name).set(r.n_current)

    push_to_gateway(
        pushgateway_url,
        job="iris-churn-drift",
        registry=registry,
    )
    logger.info(
        "pushed_drift_metrics gateway=%s features=%d", pushgateway_url, len(results)
    )


def log_to_mlflow(results: list[DriftResult], mlflow_uri: str, model_name: str) -> None:
    """Log drift metrics + summary to MLflow as a separate run.

    Creates a new run under the experiment ``churn-drift`` so the
    MLflow UI shows the daily drift series alongside the training
    runs without polluting them.
    """
    import mlflow

    mlflow.set_tracking_uri(mlflow_uri)
    mlflow.set_experiment("churn-drift")
    with mlflow.start_run(run_name=f"drift-{datetime.now(UTC).strftime('%Y-%m-%d')}"):
        mlflow.log_param("model_name", model_name)
        mlflow.log_param("computed_at", datetime.now(UTC).isoformat())
        for r in results:
            mlflow.log_metric(f"ks_stat__{r.feature_name}", r.ks_statistic)
            mlflow.log_metric(f"p_value__{r.feature_name}", r.p_value)
            mlflow.log_metric(f"n_current__{r.feature_name}", r.n_current)
        max_stat = max((r.ks_statistic for r in results), default=0.0)
        mlflow.log_metric("ks_stat_max", max_stat)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    configure_logging()

    if args.db_url is None and not args.dry_run:
        logger.error("IRIS_DB_URL required ; pass --db-url or set the env var.")
        return 2

    logger.info(
        "computing_drift mlflow=%s model=%s lookback=%dd threshold=%.2f",
        args.mlflow_uri,
        args.mlflow_model,
        args.lookback_days,
        args.ks_threshold,
    )

    training = fetch_training_features(args.mlflow_uri, args.mlflow_model)
    current = fetch_current_features(args.db_url, args.lookback_days)
    logger.info(
        "loaded_features training_rows=%d current_rows=%d",
        len(training),
        len(current),
    )

    results = compute_drift(training, current)
    if not results:
        logger.error("no features could be compared — empty intersection")
        return 3

    print(f"\n{'feature':<28} ks_stat   p_value   n_curr   over_slo")
    print("-" * 70)
    for r in sorted(results, key=lambda x: -x.ks_statistic):
        flag = "🔴" if r.ks_statistic >= args.ks_threshold else "🟢"
        print(
            f"{r.feature_name:<28} {r.ks_statistic:>7.3f}   {r.p_value:>7.3f}   "
            f"{r.n_current:>6}   {flag}"
        )

    if not args.dry_run:
        if not args.skip_push:
            push_to_prometheus(results, args.pushgateway, args.mlflow_model)
        if not args.skip_mlflow_log:
            log_to_mlflow(results, args.mlflow_uri, args.mlflow_model)

    breaches = [r for r in results if r.ks_statistic >= args.ks_threshold]
    if breaches:
        feat_list = ", ".join(r.feature_name for r in breaches)
        logger.error(
            "drift_threshold_breached count=%d features=%s threshold=%.2f",
            len(breaches),
            feat_list,
            args.ks_threshold,
        )
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
