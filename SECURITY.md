# Security policy

## Reporting a vulnerability

`iris-service-shared` holds **infrastructure-as-code, observability
config, CI templates, and cross-cutting documentation** for the
[iris-7 project family](https://gitlab.com/iris-7). It's submoduled
into `iris-service-java` and `iris-service-python` under
`infra/shared/`.

Vulnerabilities here can affect the consuming services if e.g. a Kubernetes
manifest opens a port broadly, a Terraform module exposes a state bucket,
or a CI template leaks credentials.

**Please do not file public issues for security vulnerabilities.**

Report privately :

- **Email** : security@iris-7.com (monitored)
- **GitLab** : open a
  [confidential issue](https://gitlab.com/iris-7/iris-service-shared/-/issues/new?issue[confidential]=true)

Include : repro / affected file path / SHA / your assessment.

## Response timeline

| Step | Target |
|---|---|
| Acknowledgement | within 7 days |
| Initial triage | within 14 days |
| Fix or mitigation | 30 days for high/critical, 90 days for medium |

## Scope

In-scope :
- Kubernetes manifests under `deploy/kubernetes/**`
- Terraform modules under `deploy/terraform/**`
- Docker compose stacks under `compose/**` + `deploy/compose/**`
- OTel Collector + Grafana provisioning under `infra/observability/**`
- CI templates under `ci-templates/**`
- Dev / ops scripts under `bin/**`
- Cross-cutting ADRs under `docs/adr/**`

Out of scope :
- The downstream service repos (iris-service-java, iris-service-python,
  iris-ui) — file separate reports there.
- Third-party tools we wrap (Sloth, Argo CD, kube-prometheus-stack, etc).

## Security baseline

- **`.gitleaks.toml`** : checked in pre-commit + CI on the consuming repos.
- **Sensitive variables** : never committed ; stored in GitLab CI/CD
  Variables (group-level for shared, project-level when project-specific).
  See [CLAUDE.md "CI/CD variables hygiene"](https://gitlab.com/iris-7/iris-service-shared/-/blob/main/docs/...) (in
  individual project repos).
- **Pinned upstream references** : every Docker image, Helm chart, GitHub
  Action — `bin/ship/check-default-branch.sh` + `bin/dev/runner-healthcheck.sh`
  enforce hygiene around runner state + branch config.

## Hall of fame

*no entries yet — be the first ?*
