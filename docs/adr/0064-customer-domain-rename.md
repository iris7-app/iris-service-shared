# ADR-0064 : `Customer` domain rename — analysis, alternatives, migration plan

**Status** : Proposed (analysis only — decision deferred to user)
**Date** : 2026-04-28
**Sibling repos** :
- `iris-service-java` — JPA entity `Customer`, package `com.iris.customer.*`, Flyway V1/V3/R-seed, MCP tools `get_customer_360`/`predict_customer_churn`, Kafka `KafkaCustomerEventPublisher`
- `iris-service-python` — SQLAlchemy package `iris_service.customer.*`, MCP tool `get_customer_360`
- `iris-ui` — Angular feature `src/app/features/customer/`, route `/customers`, RBAC anchors
- `iris-service-shared` — this ADR + 2 sibling ADRs ([0059](0059-customer-order-product-data-model.md), [0061](0061-customer-churn-prediction.md)) embed the term in their decision text
- `iris-common` — none (no domain code lives here)
- Tags affected (if rename ships) : next [java stable-v](https://gitlab.com/iris-7/iris-service-java/-/tags), [python stable-py-v](https://gitlab.com/iris-7/iris-service-python/-/tags), [ui stable-v](https://gitlab.com/iris-7/iris-ui/-/tags) — see "Phased migration plan" for tag boundaries

## Context

The `iris-7` polyrepo currently uses `Customer` as the central
business actor — the FK root of the data model defined in
[ADR-0059](0059-customer-order-product-data-model.md) and the subject
of the ML pipeline defined in
[ADR-0061](0061-customer-churn-prediction.md). The README narrative
on each portfolio-facing repo positions the project as
**"Customer onboarding & enrichment + Order/Product/OrderLine domain"**.

User signal triggered 2026-04-28 ~07:30 — paraphrased : *"the term
`Customer` feels generic for recruiter framing ; could a more
distinctive name better signal mastery and domain depth ?"*. This
request was originally captured as a deferred TODO :
> *"Refactor 50+ files when there's a real recruiter signal that the
> term feels generic"*

A reference survey of the 5 active repos (per the layout in
[~/.claude/CLAUDE.md](file:///Users/benoitbesson/.claude/CLAUDE.md)
"Iris1 polyrepo layout — 2-tier flat α submodule pattern") shows
**532 file-level references** to `customer` / `Customer` —
broader than the 503 originally estimated :

| Repo | Files mentioning `customer` (case-insensitive) |
|---|---|
| `iris-service-java` | 254 (incl. 22 main + 18 test in `com.iris.customer/` ; rest = MCP, ML, security, observability cross-cutting) |
| `iris-service-python` | 111 (incl. 18 in `iris_service/customer/`) |
| `iris-ui` | 167 (incl. 25 in `features/customer/`) |
| `iris-service-shared` | 2 ADRs (0059, 0061) |
| `iris-common` | 0 |

The request is to **plan, not execute** the rename. This ADR proposes
a recommendation, surveys alternatives, and gives a phased migration
plan that the user can greenlight (or reject) as a separate decision.

## Decision

**Recommendation : REJECT the rename. Keep `Customer`.**

The cost-benefit asymmetry, plus narrative coherence + already-accepted
ADRs that embed the term, make this rename a high-risk, low-payoff
operation. See "Consequences" + "Rejected alternatives" below.

**Fallback target if user disagrees** : the strongest alternative is
**`Account`** — see "Naming alternatives" for why, and "Phased migration
plan" for how. Other candidates (`Subscriber`, `Member`, `Lead`,
`Contact`) all have smaller relative gains and comparable blast radius.

**Status remains `Proposed`**, not `Accepted`, until the user picks
between {keep, rename to Account, rename to other}. This ADR exists
to make the decision auditable.

## Surface area inventory — what would actually move

The 532 file references collapse into these surface types. Each is
named in the migration plan below ; the count is what the rename
would touch :

### Java (`iris-service-java`)

| Surface | Count | Notes |
|---|---|---|
| Package `com.iris.customer.*` | 22 main + 18 test files | Includes `Customer`, `CustomerController`, `CustomerService`, `CustomerRepository`, `CustomerDto`, `CustomerDtoV2`, `CreateCustomerRequest`, `PatchCustomerRequest`, `CustomerEnrichmentController`, `CustomerDiagnosticsController`, `CustomerStatsScheduler`, `RecentCustomerBuffer`, `EnrichedCustomerDto`, `CustomerSummary`, `package-info.java` |
| JPA `@Entity` + `@Table(name="customer")` | 1 entity + DB table | Table rename is a Flyway migration |
| Flyway migrations | 3 | `V1__create_customer.sql`, `V3__add_customer_createdat.sql`, `R__seed_demo_customers.sql` (R-seed re-runs on every checksum change) |
| REST endpoints | `/customers/*` | Controller `@RequestMapping` + tests + OpenAPI tag |
| OpenAPI tags / `@Tag(name="Customer")` | several | Compodoc / OpenAPI viewer tab labels |
| Kafka publisher | `KafkaCustomerEventPublisher.java` + topic name (likely `customer-events`) | Topic rename = consumer group reset = downtime if any consumer is in flight |
| MCP tools | `get_customer_360` (`CustomerToolService`), `predict_customer_churn` (`ChurnMcpToolService`) | Tool name rename breaks any pre-existing LLM transcript / Anthropic Console saved prompts |
| Cross-feature references | `OrderToolService` `@ToolParam("Customer ID — must reference an existing customer row")` ; `SecurityDemoController` ; observability spans tagged `com.iris.customer` ; MicroMeter timers `iris.customer.*` | Each is a string the LLM sees ; rename them or keep them is a separate sub-decision |
| ML domain | `ChurnMcpToolService`, churn-feature CSV column names, ONNX input feature names if any | The ML pipeline (ADR-0061) is built around `Customer` as the prediction subject |
| Stability-check / scripts | `bin/dev/stability-check.sh` sections may grep for `customer` | Rename ripple in 1-2 sections |

### Python (`iris-service-python`)

| Surface | Count | Notes |
|---|---|---|
| Package `iris_service.customer.*` | 18 files | SQLAlchemy model, Pydantic DTOs, FastAPI router, service layer |
| FastAPI router prefix | `/customers` | Mirrors Java OpenAPI contract — must rename in lockstep |
| Alembic migrations | 1+ (need verify) | Table rename = new alembic revision in addition to Java Flyway version |
| MCP tools | `get_customer_360` (`tools.py:649`) | Mirrors Java |
| Pydantic DTOs | `CustomerDto`, `CustomerCreate`, `CustomerPatch`, `EnrichedCustomerDto` | Mirrors Java |
| OpenTelemetry resource attributes | `iris_service.customer` | Spans + traces in Tempo would shift attribute name |

### UI (`iris-ui`)

| Surface | Count | Notes |
|---|---|---|
| Feature module | `src/app/features/customer/` | 25 files |
| Angular route | `path: 'customers'` in `app.routes.ts:23` | RouterLink anchors throughout sidebar + copy |
| HTTP client paths | `/api/customers/*` | `auth.interceptor.spec.ts` alone has 8 hard-coded references — mirror in real client + every spec |
| TypeScript interfaces | `CustomerDto`, `CustomerSummary`, `EnrichedCustomerDto`, `CreateCustomerRequest`, `PatchCustomerRequest` | Generated or hand-typed mirrors of the Java/Python DTOs |
| RBAC role anchors | likely `ROLE_CUSTOMER_*` / `ROLE_ADMIN_CUSTOMER_*` | Coupled to backend `@PreAuthorize` strings — must rename in lockstep |
| Copy / i18n text | "Customer", "Manage customers", "Add customer" | Either in template strings or i18n bundles ; user-visible |
| E2E tests | `npm run e2e` Playwright specs | Page selectors keyed on routes + headings |

### Cross-cutting (all 3 stacks)

| Surface | Notes |
|---|---|
| Already-accepted ADRs | [ADR-0059](0059-customer-order-product-data-model.md) (data model) + [ADR-0061](0061-customer-churn-prediction.md) (ML) embed the term in **decision text** + filename. Renaming requires either (a) renaming the ADR files (breaks audit trail), (b) writing new ADRs that supersede them, or (c) leaving them stale (creates confusion : ADR says "Customer", code says "Account") |
| README narrative | "Customer onboarding & enrichment" — at the top of every portfolio-facing README per [feedback_thematic_mastery_sections](file:///Users/benoitbesson/.claude/projects/-Users-benoitbesson-dev-iris/memory/feedback_thematic_mastery_sections.md). Rename = rewrite this line in 3 READMEs |
| Tag annotations | Every prior `stable-v*` annotation mentions "Customer" — those are immutable git history, untouched |
| CLAUDE.md (global + per-repo) | The iris-specific section in `~/.claude/CLAUDE.md` references the term ; per-repo `CLAUDE.md` files may too |

### What is NOT touched (good news)

- **Maven `groupId`** = `com.example` ; **`artifactId`** = `iris` — no `customer` in coordinates
- **Python package name** = `iris-service` — no rename impact
- **UI package name** = `iris-ui` — no rename impact
- **Repo names** : `iris-service-{java,python,shared}`, `iris-ui`, `iris-common` — none mention customer
- **Auth tables** `app_user`, `audit_event`, `refresh_token` — auth principal is "user/account" already ; the rename target must NOT collide

## Naming alternatives — 5 candidates with tradeoffs

The table below scores each candidate on 6 criteria the user signals
matter (recruiter readability, domain accuracy, narrative fit,
collision risk, blast radius, SEO).

| Candidate | Recruiter readability | Domain accuracy | Narrative fit ("onboarding & enrichment") | Collision risk | Blast radius vs Customer | Notes |
|---|---|---|---|---|---|---|
| **Account** (recommended fallback) | ✅ universal in B2B SaaS | ✅ matches "an entity who buys things" | 🟡 "Account onboarding & enrichment" sounds bank-y / auth-y | ⚠ **`app_user` is also called "account" in colloquial speech ; lint rule needed** | Same (~532 refs) | Industry-recognised, neutral, but the auth collision is real |
| **Subscriber** | ✅ SaaS / SVOD recognisable | 🟡 implies recurring-revenue billing which the project does NOT have | ✅ "Subscriber onboarding & enrichment" reads naturally | None | Same | Strong UX signal but DOMAIN-INACCURATE — Iris has Order/OrderLine, not subscriptions |
| **Member** | ✅ universal (loyalty, community) | 🟡 implies a club / membership tier system | ✅ "Member onboarding" is clear (gym / club analogy) | 🟡 may overlap with auth "membership" of an org | Same | Warm but generic ; risks sounding "yet another loyalty CRM" |
| **Contact** | ✅ canonical CRM term (Salesforce, HubSpot) | ✅ **exact match** — Contact records are enriched in CRMs | ✅ **best narrative fit** — "Contact onboarding & enrichment" is literal CRM vocab | ⚠ collides with "contact info" subfield ; would need to rename `contact_email`/`contact_phone` columns | Same | Strongest narrative match, but the "contact-of-a-contact" recursion is awkward |
| **Lead** | ✅ sales-funnel recognised | ⚠ implies pre-conversion ; once a Lead places an Order they're no longer a Lead | 🟡 "Lead onboarding & enrichment" works ONLY for the pre-purchase stage | ⚠ requires a 2-stage model (Lead → Account) which doubles the data model | Same + new entity | Forces a meaningful semantic shift, not just a string-replace |

### Recommended fallback rationale

If the user insists on a rename, **`Account`** wins because :

1. It is the **most common B2B-SaaS term** in 2026 — a recruiter
   reading the codebase has zero parsing cost.
2. It does NOT lock the project into a sub-domain (subscription /
   loyalty / sales-funnel) the way Subscriber / Member / Lead do.
3. The collision with `app_user` is solvable — a one-line ADR ("the
   word `account` refers to a business actor ; the auth principal
   is `app_user`") + an ESLint / Checkstyle rule that flags
   `account` in auth code paths.
4. `Account onboarding & enrichment` reads naturally as a B2B-SaaS
   feature even if it loses some warmth vs `Customer`.

`Contact` is a close second on narrative fit but the column-name
collision (`contact_email`, `contact_phone`) makes it noisier.

## Phased migration plan (if rename greenlit)

If the user chooses to rename — to `Account` or any other target —
this is the phasing. Each phase is a single MR per repo, lands behind
a green CI, and produces a tag boundary that can be rolled back to.

**Pre-flight (Phase 0)** :

- Confirm the target name (assume `Account` below).
- Write 3 supersedes ADRs : new sibling `0059bis-account-order-product-data-model.md`, `0061bis-account-churn-prediction.md`, and a deprecation stub in 0059 / 0061 pointing to the new ones.
- Reserve tag boundaries : `stable-v1.3.0` (java), `stable-py-v0.7.0` (python), `stable-v1.2.0` (ui) — the minor bump signals a breaking domain rename per Conventional Commits.
- Update the README "🧠 Fonctionnel" bullet on each portfolio repo to use the new term (this lands AT THE END, not the start — the rename is the truth-source ; README is the snapshot).

### Phase 1 — Java internal rename (1-2 days)

**Scope** : `com.iris.customer/*` → `com.iris.account/*` ;
class names ; package-info ; internal references.

**Excluded from this phase** : DB table name, REST endpoint paths,
OpenAPI tag, Kafka topic, MCP tool names — those are external
contracts, deferred to Phase 2.

**Steps** :
1. `git mv src/main/java/com/iris/customer src/main/java/com/iris/account` (idem for `src/test`).
2. IDE-assisted rename : `Customer` → `Account` across the moved files only. Compiler errors point to all callers.
3. Fix callers in `com.iris.{order,mcp,ml,security,observability}` — they import the moved types.
4. Keep the JPA `@Table(name="customer")` annotation **explicit** so the DB table is NOT renamed yet.
5. Keep `@RestController @RequestMapping("/customers")` so the external API does NOT change.
6. Run `./mvnw verify` → green.
7. Commit : `refactor(domain): rename Customer to Account (internal — Phase 1/6)`.

**Rollback** : single `git revert <commit>` ; no DB / API / contract change.

**CI checkpoint** : green main pipeline → tag `stable-v1.3.0-rc1`.

### Phase 2 — Java external surface (DB + REST + OpenAPI + Kafka + MCP) (2-3 days)

**Scope** : the things that other systems see. Renaming these breaks
contracts.

**Steps** :
1. **DB rename** : new Flyway `V20__rename_customer_to_account.sql` —
   `ALTER TABLE customer RENAME TO account; ALTER TABLE orders RENAME COLUMN customer_id TO account_id;` + index rename.
   Update JPA `@Table(name="account")` + `@JoinColumn(name="account_id")` on `Order`.
2. **REST path** : `@RequestMapping("/customers")` → `/accounts`. Add a temporary `@RequestMapping("/customers")` shadow that 301-redirects to `/accounts` for backward compatibility (carries a `@Deprecated` exit ticket — remove in Phase 6).
3. **OpenAPI tag** : `@Tag(name="Customer")` → `@Tag(name="Account")`.
4. **Kafka topic** : create new `account-events` topic in `application.yml` ; keep `customer-events` in parallel for one phase ; dual-publish ; deprecate the old topic in Phase 6 once consumers (Python + UI) migrate.
5. **MCP tools** : add `get_account_360` + `predict_account_churn` tools alongside the existing `get_customer_360` / `predict_customer_churn`. Mark old tools deprecated in their `description` field. Old tools removed in Phase 6.
6. Run full test pass per the "Tag annotations document what was verified" rule : `./mvnw verify` + `./mvnw verify -Dcompat -Djava21` + `bin/dev/stability-check.sh` + `bin/dev/api-smoke.sh`.
7. Commit chain : `feat(db): rename customer to account (Flyway V20)`, `refactor(api): /customers → /accounts (Phase 2/6)`, `feat(kafka): dual-publish account-events alongside customer-events`, `feat(mcp): add get_account_360 + predict_account_churn (Phase 2/6)`.

**Rollback** : `git revert` the chain ; redeploy the previous tag. The Flyway migration is forward-only, but the previous tag's code reads from `customer` (old table) — a sibling `V21__rollback_account_to_customer.sql` is prepared in advance and held out-of-tree until rollback decision.

**CI checkpoint** : green main pipeline + smoke test + MCP tool invocation via `claude mcp` → tag `stable-v1.3.0`.

### Phase 3 — Python internal (1 day)

**Scope** : `iris_service.customer/*` → `iris_service.account/*` ;
class names ; SQLAlchemy `Mapped` declarations.

**Steps** mirror Phase 1, on the Python repo. Lockstep with Phase 4
(Python external) so the test suite stays green.

**CI checkpoint** : green main pipeline → tag `stable-py-v0.7.0-rc1`.

### Phase 4 — Python external (DB + REST + MCP) (1-2 days)

**Scope** : alembic migration mirroring Java's Flyway V20 (must produce the SAME schema state) ; FastAPI router prefix `/customers` → `/accounts` ; MCP tool `get_customer_360` → `get_account_360`.

**Steps** mirror Phase 2. Critical : the alembic version must be
committed in lockstep with the Java Flyway V20 so that running
either backend against the same DB produces a coherent state. The
shared DB is the source of truth ; the alembic + flyway are duplicate
declarations of the same migration.

**CI checkpoint** : green main pipeline → tag `stable-py-v0.7.0`.

### Phase 5 — UI types + routes + RBAC + copy (1-2 days)

**Scope** : every UI surface. The user-facing rename happens here ;
this is when the screen header changes from "Customers" to "Accounts".

**Steps** :
1. `git mv src/app/features/customer src/app/features/account`.
2. Rename TypeScript interfaces in lockstep with the new OpenAPI contract.
3. Update Angular route `path: 'customers'` → `'accounts'`. Add a 301 redirect from `/customers` to `/accounts` via a `Routes` `redirectTo` so old bookmarks survive — remove in Phase 6.
4. Update RBAC role strings `ROLE_CUSTOMER_*` → `ROLE_ACCOUNT_*` (must lockstep with backend `@PreAuthorize`).
5. Update i18n / template copy : "Customer" → "Account".
6. Update Playwright E2E selectors keyed on the route + headings.
7. Run `npm run build -- --configuration production` + `npm test` + `npm run e2e` on mobile (390 px) and desktop (1280 px) viewports per the "UI must work on mobile" rule.

**CI checkpoint** : green main pipeline + manual visual check on iPhone 12 viewport → tag `stable-v1.2.0`.

### Phase 6 — Cleanup + ADR closure (0.5 day)

**Scope** : remove the Phase 2 / 5 backward-compat shadows.

**Steps** :
1. Drop `customer-events` Kafka topic (after verifying lag = 0 and no consumer is reading).
2. Drop deprecated MCP tools `get_customer_360` / `predict_customer_churn`.
3. Drop the `/customers` → `/accounts` 301 redirect.
4. Drop the UI `/customers` route redirect.
5. Update [ADR-0059](0059-customer-order-product-data-model.md) + [ADR-0061](0061-customer-churn-prediction.md) status to `Superseded by ADR-0059bis / 0061bis`.
6. Update each repo's README "🧠 Fonctionnel" bullet to read `Account onboarding & enrichment + Order/Product/OrderLine domain`.
7. Update the global `~/.claude/CLAUDE.md` section that references "Customer onboarding & enrichment" if needed.
8. Commit : `chore(rename): drop backward-compat shadows (Phase 6/6 — rename complete)`.

**Final tag** : `stable-v1.3.1` (java), `stable-py-v0.7.1` (python), `stable-v1.2.1` (ui) — patch-bump all three on the same day with the comprehensive verification annotation per the "Tag annotations document what was verified" rule.

### Total estimate

- 6-9 working days of focused work (assuming no surprises)
- 18+ commits, 6 MRs, 3 minor-version-bump tags + 3 patch tags
- ~2 weeks of calendar time at sustainable cadence

## Rejected alternatives — names considered + dropped

| Candidate | Why dropped |
|---|---|
| **Onboardee** | Not a real industry term ; awkward in plurals (`onboardees`) and possessives (`onboardee's`) ; SEO-poor |
| **Party** | DDD-pure (Cockburn / Fowler "Party" pattern) but too generic ; recruiters won't recognise it as a domain term |
| **Counterparty** | Over-signals financial industry (banking / trading) when the project is generic ecommerce ; sets wrong domain expectations |
| **Patron** | Too retail / nonprofit / loyalty-tier coded ; narrow connotation |
| **Subject** | Too academic / legal / GDPR ("data subject") ; loaded with privacy-domain meaning |
| **Buyer** | Too transactional ; loses the "onboarding & enrichment" framing (a Buyer is mid-transaction, not pre-/post-) |
| **Client** | Common in agency / consulting but ambiguous in software (HTTP client, Spring client, etc.) ; high collision |
| **Tenant** | Implies multi-tenancy isolation primitive ; sets wrong architectural expectations (Iris is single-tenant) |
| **User** | Already taken by `app_user` (auth principal) ; would silently confuse the two roles |

## Consequences

### If recommendation accepted (KEEP `Customer`)

✅ **Zero risk** — no CI red, no contract break, no consumer migration, no deprecation cycle.
✅ **Narrative coherence preserved** — the "Customer onboarding & enrichment" framing in the README + thematic mastery axes stays load-bearing.
✅ **2 ADRs (0059, 0061) remain truth-of-record** without rewriting.
✅ **Recruiter readability is already high** — `Customer` is universal vocabulary.
✅ **Time + attention stays on substantive features** (auth flows, ML pipeline depth, observability dashboards) instead of cosmetic refactor.

⚠ **The original "term feels generic" signal is unaddressed.** If the user genuinely feels `Customer` weakens the portfolio framing, the fix is to **strengthen the surrounding narrative** — sharper README copy ("Customer 360 with churn prediction"), better screenshots, more thematic mastery bullets — rather than rename the actor.

⚠ **A future reader may STILL ask the question.** This ADR documents the rejection so the next session inherits the rationale and doesn't re-litigate.

### If recommendation rejected (RENAME to `Account`)

✅ **Slightly tighter B2B-SaaS framing** in the package + class names.
✅ **One-time signal of refactor discipline** — a clean phased rename across 5 repos is itself a portfolio artefact (visible in `git log --all --oneline | grep rename`).

⚠ **6-9 days of work** with non-trivial risk : Kafka topic dual-publishing is brittle, Flyway forward-only rename requires careful rollback prep, MCP tool deprecation breaks any saved Anthropic Console prompts users may have shared.
⚠ **2 ADRs require supersedes** + their references in CLAUDE.md update.
⚠ **`Account` ↔ `app_user` collision** must be policed by lint + ADR clarification ; subtle bugs possible if someone uses "account" colloquially in auth code.
⚠ **Old tag annotations become anachronistic** — `stable-v1.2.9` says "Customer onboarding" ; new tags say "Account onboarding". Acceptable (tags are immutable history) but creates a time-boundary in the audit trail.

### If a different name is chosen

The phased migration plan applies as-is, with the target name
substituted. The blast radius is identical ; only the recruiter
readability + collision-risk profile differs (see "Naming alternatives").

## Implementation note — when this ADR is greenlit

If user accepts the rejection (KEEP) :
1. Update this ADR's `Status` to `Accepted (rejection)`.
2. Drop the deferred TODO from any remaining backlog reference.
3. No code change needed.
4. **Optional follow-up** : strengthen the README "🧠 Fonctionnel" bullet copy to reduce the "generic" perception without renaming.

If user accepts the rename :
1. Update this ADR's `Status` to `Accepted` and write the chosen target inline.
2. Schedule a `/loop` or `/schedule` for the 6-phase plan.
3. Open a tracking MR sequence per the phasing.
4. Re-run this ADR's "Tag annotations document what was verified" pass at each tag boundary.

## References

- [java ADR-0008 — feature-slicing](https://gitlab.com/iris-7/iris-service-java/-/blob/main/docs/adr/0008-feature-slicing.md) — defines `com.iris.customer/*` as a feature slice ; the rename respects this layout
- [shared ADR-0059 — Customer / Order / Product / OrderLine domain data model](0059-customer-order-product-data-model.md) — embeds the term in the schema diagram
- [shared ADR-0061 — Customer churn prediction](0061-customer-churn-prediction.md) — embeds the term in the ML pipeline
- [common ADR-0001 — polyrepo via submodule](https://gitlab.com/iris-7/iris-common/-/blob/main/docs/adr/0001-shared-repo-via-submodule.md) — explains why this ADR lives in `iris-service-shared` (cross-cutting backend) rather than per-repo
- [common ADR-0060 — flat α submodule inheritance](https://gitlab.com/iris-7/iris-common/-/blob/main/docs/adr/0060-flat-vs-transitive-submodule-inheritance.md) — explains why bumping this ADR's repo doesn't cascade ; each consumer pulls when ready
- Eric Evans, *Domain-Driven Design* (2003), ch. 5 § "Entities" — same reference used in ADR-0059 ; reinforces that renaming an entity is a domain-language decision, not a refactor
- Robert C. Martin, *Clean Code* (2008), ch. 2 § "Use Intention-Revealing Names" — the test the user implicitly applied : does `Customer` reveal intent ? The recommendation argues yes ; the alternative argues no
