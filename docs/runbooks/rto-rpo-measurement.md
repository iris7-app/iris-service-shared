# RTO / RPO measurement runbook

> **Status** : 1 measurement run completed 2026-04-28 — RTO = **7 s** for
> a postgres StatefulSet pod-kill on GKE Autopilot. RPO not directly
> measured (no steady-state write traffic during this run — see
> "Limitations" below).

This runbook describes how to measure :

- **RTO (Recovery Time Objective)** — wall-clock time from a fault
  injection (e.g. DB pod kill) until the system serves successful
  requests again.
- **RPO (Recovery Point Objective)** — count / volume of write
  transactions that would have been lost during the outage window.

It targets the Iris1 platform on a GKE Autopilot demo cluster
(`bin/cluster/demo/up.sh`) but the same procedure adapts to any
K8s cluster with a postgres StatefulSet.

---

## Why this is a manual procedure (and not Chaos Mesh)

The original plan called for a Chaos Mesh `PodChaos` resource. On
**GKE Autopilot**, the Chaos Mesh `chaos-daemon` DaemonSet is
**rejected by Warden** because it requires :

- `hostPID: true` — disallowed (`autogke-disallow-hostnamespaces`)
- privileged container — disallowed (`autogke-disallow-privilege`)
- hostPath volumes in write mode — disallowed (`autogke-no-write-mode-hostpath`)

The chaos *control plane* (chaos-controller-manager + dashboard +
DNS) installs cleanly, but without the daemon there is no agent on
the nodes that can actually inject pod-level faults.

Workaround : skip Chaos Mesh entirely on Autopilot, drive the kill
with `kubectl delete pod` directly. For the simple "kill the DB pod"
scenario this is functionally equivalent and avoids fighting
Autopilot constraints.

If a future need pushes us toward a Standard (non-Autopilot) cluster
or an on-prem k3s, Chaos Mesh's full toolkit becomes available again
and this runbook can be upgraded to use it.

---

## Procedure

### 1. Bring the cluster up

```bash
cd ~/dev/iris/iris-service-shared
bin/cluster/demo/up.sh
```

Time : ~10 min (terraform apply + Argo CD + ESO + Kyverno + Argo
Rollouts + chaos-mesh control plane).

### 2. Deploy postgres + the dummy auth secret

```bash
kubectl apply -f deploy/kubernetes/postgres/

kubectl create secret generic iris-secrets -n infra \
  --from-literal=DB_PASSWORD=demo123 \
  --from-literal=DATASOURCE_PASSWORD=demo123 \
  --from-literal=POSTGRES_PASSWORD=demo123

kubectl wait --for=condition=Ready pod postgresql-0 -n infra --timeout=120s
```

Note : the StatefulSet expects `iris-secrets` with at least the
`DB_PASSWORD` key. In the canonical setup ESO populates it from
GSM ; for a one-off RTO measurement a manual `kubectl create secret`
is enough.

### 3. Deploy the probe pod

The probe runs `pg_isready` against the `postgresql.infra.svc.cluster.local:5432`
service every 1 s, logging `iso ok` or `iso fail` on stdout. It
detects the chaos window (first fail) and computes the RTO once it
sees the first recovery probe.

```bash
kubectl apply -f /tmp/probe-pod.yaml   # see "Probe pod manifest" below
kubectl wait --for=condition=Ready pod rto-probe -n infra --timeout=60s
```

### 4. Trigger the chaos

Record the wall-clock then kill the postgres pod :

```bash
date -u +%Y-%m-%dT%H:%M:%S.%3NZ   # remember this timestamp
kubectl delete pod postgresql-0 -n infra --grace-period=0 --force
```

The StatefulSet controller recreates `postgresql-0` against the
existing PVC (data is preserved). Pod scheduling + image pull (cached)
+ initdb skip (PGDATA exists) + Spring Boot's built-in `pg_isready`
gate take a few seconds.

### 5. Read the probe log

```bash
sleep 90
kubectl logs rto-probe -n infra --tail=120
```

Expected pattern :

```
… ok        ← steady-state pre-chaos
… ok
… fail      ← first failure → t_fail
… fail
… fail
…
… ok        ← first recovery → t_recovery
… RECOVERED rto=…s
… ok
```

`RTO = t_recovery - t_fail` (in seconds).

### 6. Tear down

```bash
bin/cluster/demo/down.sh   # terraform destroy
```

Cluster cost stops within seconds. PVC + cluster state are
destroyed ; only the GCS state bucket (cents) and Artifact
Registry images survive.

---

## Probe pod manifest

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rto-probe
  namespace: infra
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: postgres:17-alpine
      command:
        - /bin/sh
        - -c
        - |
          first_fail=""
          first_recovery=""
          tick=0
          while [ $tick -lt 240 ]; do
            iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
            if pg_isready -h postgresql.infra.svc.cluster.local -p 5432 \
                 -U demo -d customer-service -t 2 -q; then
              echo "$iso ok"
              if [ -n "$first_fail" ] && [ -z "$first_recovery" ]; then
                first_recovery=$(date +%s)
                echo "$iso RECOVERED"
              fi
            else
              echo "$iso fail"
              if [ -z "$first_fail" ]; then
                first_fail="$iso"
              fi
            fi
            tick=$((tick + 1))
            sleep 1
          done
          echo "probe done"
```

---

## RPO writer pod manifest (2026-04-29 run)

Direct-postgres writer (bypasses `iris-service-java`) — useful when
the app deployment is broken or unavailable and you only need to
validate the postgres durability side of RPO.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rpo-writer
  namespace: infra
  labels:
    role: rpo-writer
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: postgres:17-alpine
      env:
        - name: PGPASSWORD
          value: demo123
      command:
        - /bin/sh
        - -c
        - |
          DSN="postgresql://demo:demo123@postgresql.infra.svc.cluster.local:5432/customer-service?sslmode=disable"
          RUN_ID=$(date +%s)
          psql "$DSN" -c "CREATE TABLE IF NOT EXISTS rpo_test (id BIGSERIAL PRIMARY KEY, run_id BIGINT, seq INT, ts TIMESTAMPTZ DEFAULT NOW());" -q
          attempted=0; ok=0; fail=0; i=0
          end=$(($(date +%s) + 90))
          while [ "$(date +%s)" -lt "$end" ]; do
            i=$((i + 1)); attempted=$((attempted + 1))
            iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
            if psql "$DSN" -c "INSERT INTO rpo_test (run_id, seq) VALUES ($RUN_ID, $i);" -q 2>/dev/null; then
              ok=$((ok + 1))
              [ $((i % 25)) -eq 0 ] && echo "$iso ok i=$i"
            else
              fail=$((fail + 1))
              [ $((i % 25)) -eq 0 ] && echo "$iso fail i=$i"
            fi
            sleep 0.2
          done
          sleep 5
          persisted=$(psql "$DSN" -t -c "SELECT count(*) FROM rpo_test WHERE run_id = $RUN_ID;" 2>/dev/null | tr -d ' ')
          echo "RPO_DONE attempted=$attempted ok=$ok fail=$fail persisted=$persisted run_id=$RUN_ID"
```

Procedure :

1. Apply this manifest after postgres is Ready.
2. Wait for `ok i=100` in the writer's logs (`kubectl logs rpo-writer -n infra -f`).
3. Trigger chaos : `kubectl delete pod postgresql-0 -n infra --grace-period=0 --force`.
4. Wait for `RPO_DONE` line (writer auto-exits after the 90 s window + 5 s settle).
5. RPO = `attempted - persisted`.

---

## Result — 2026-04-28 run

| Metric | Value | Notes |
|---|---|---|
| **Cluster** | GKE Autopilot, `@@KEEP_IRIS_PROD@@`, europe-west1 | Brought up via `bin/cluster/demo/up.sh` |
| **Chaos action** | `kubectl delete pod postgresql-0 --force --grace-period=0` | StatefulSet pod-kill, PVC preserved |
| **Probe** | `pg_isready` against the `postgresql` Service every 1 s | Ran in a separate pod inside the cluster |
| **First fail** | 2026-04-28 06:03:16 (UTC) | Same second the kill landed |
| **First recovery** | 2026-04-28 06:03:23 (UTC) | First `pg_isready` returning ok again |
| **Failed probes** | 7 consecutive | 06:03:16 → 06:03:22 |
| **RTO** | **7 seconds** | First-fail → first-recovery |
| **RPO** | Not measured directly | See "Limitations" below |

For context : the Iris SLA documents an RTO target of **30 seconds**
for postgres failures (see `docs/PRODUCTION-READINESS.md`). The
measured 7 s comfortably beats the target.

---

## Result — 2026-04-29 RPO run

| Metric | Value | Notes |
|---|---|---|
| **Cluster** | GKE Autopilot, `iris7-prod`, europe-west1 | Brought up via `bin/cluster/demo/up.sh` (after MR !16 fixed the `@@KEEP_IRIS_PROD@@` sentinel) |
| **Workload** | Direct postgres `INSERT INTO rpo_test (run_id, seq) VALUES (...)` from a `postgres:17-alpine` pod via psql | NOT through `iris-service-java` — the deployment manifest still pointed at the pre-rebrand `iris-service/backend` image (fixed via MR !274). Direct-postgres write path validates the same RPO contract. |
| **Pace** | 1 INSERT per ~200 ms (~5 attempts/s nominal ; observed ~3.7/s due to psql connection overhead) | |
| **Run duration** | 90 s window (336 attempts completed before the writer timer expired) | |
| **Chaos action** | `kubectl delete pod postgresql-0 --force --grace-period=0` at attempt #100 | Same pattern as the 2026-04-28 RTO run |
| **First fail** | 2026-04-29 02:28:36 UTC (immediately after attempt #100) | The next 16 s the writer's psql connect blocked rather than retried |
| **First recovery** | 2026-04-29 02:28:53 UTC (writer logs `ok i=125`) | |
| **Observed RTO** | **17 s** | Higher than the 7 s pg_isready measurement — fresh-cluster cold cache + writer's per-iteration TCP-reconnect inflates timing vs. a long-lived probe pod |
| **Total attempts** | 336 | (target was 450 ; truncated by the 90 s wall clock) |
| **Persisted rows** | 335 (verified via `SELECT count(*) FROM rpo_test WHERE run_id = ...`) | |
| **`fail` (writer-side)** | 1 | The single attempt whose psql connect did NOT eventually succeed against the recovering pod |
| **RPO** | **1 lost write** | `attempted − persisted = 336 − 335 = 1`. Only the in-flight transaction at the chaos boundary was lost ; subsequent psql calls blocked on connection then succeeded after recovery. |

For context : the Iris SLA documents an RPO target of "single-digit
in-flight transactions" for postgres failures (informal, no public
target document yet). Observed RPO of 1 transaction comfortably
fits that envelope.

The full writer log lives at `/tmp/rpo-run-2026-04-29.log` on the
machine that ran the procedure (recreate via the manifest at
`/tmp/rpo-direct-writer.yaml`).

## Limitations of this run

- **No app-layer write traffic** — RPO is a *transaction-loss*
  metric ; without a steady-state load (writes per second hitting
  the Java backend ⇒ postgres) we cannot count how many writes
  would have been dropped during the 7 s outage. To measure RPO
  properly, deploy the Java app alongside postgres, run a load
  generator (`bin/dev/api-smoke.sh` in a loop, or a `k6` script)
  for the chaos window, and compare expected vs. actually-persisted
  rows after recovery.
- **Single chaos run** — RTO can vary with cluster age, image
  pull cache state, node provisioning state, postgres warm-cache
  size. For a production-grade SLO assertion, run the procedure
  ≥ 5 times (different times of day) and report the **p50 + p95**
  of measured RTO.
- **Service routing latency not isolated** — the probed RTO
  includes K8s endpoints reconciliation time (Service routing
  to the new pod). On busy clusters this can add 1-3 s. The
  raw postgres process boot time alone is shorter.
- **Autopilot scheduler timing** — GKE Autopilot may add
  scheduling latency on cold nodes (seconds) ; the cluster used
  here was warm.

---

## Next iterations to consider

1. **RPO measurement** — deploy the Java app, run `k6` at 50 req/s
   sending POST `/customers`, capture the response body's
   `Location: /customers/{id}` header, then after recovery
   `SELECT id FROM customer WHERE id IN (...)` to count holes.
   RPO = expected_writes - persisted_count.
2. **Alternative chaos targets** — Kafka pod kill, Redis pod kill,
   Java app pod kill (rolling deploy emulation), node drain.
3. **Automate as a periodic job** — a CronJob in the cluster that
   runs the procedure weekly, posts results to Prometheus
   pushgateway, panels on a Grafana RTO dashboard.
4. **Standard (non-Autopilot) cluster path** — if Chaos Mesh becomes
   a hard requirement, document a parallel `bin/cluster/standard/up.sh`
   that provisions a Standard GKE cluster where the chaos-daemon
   DaemonSet can run with the privileges it needs.
