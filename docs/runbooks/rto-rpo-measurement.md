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
