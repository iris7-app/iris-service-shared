# ADR-0059 : Customer / Order / Product / OrderLine — domain data model

**Status** : Accepted
**Date** : 2026-04-26
**Sibling repos** :
- `iris-service-java` — JPA entities under `com.iris.{order,product}.*` ; migrations V7/V8/V9
- `iris-service-python` — SQLAlchemy 2.x async models under `src/iris_service/{order,product}/` ; alembic 0002/0003/0004
- `iris-ui` — TypeScript interfaces in `core/api/api.service.ts` ; pages under `features/commerce/`
- Tags : [java stable-v1.2.3](https://gitlab.com/iris-7/iris-service-java/-/tags/stable-v1.2.3), [python stable-py-v0.6.4](https://gitlab.com/iris-7/iris-service-python/-/tags/stable-py-v0.6.4), [ui stable-v1.1.3](https://gitlab.com/iris-7/iris-ui/-/tags/stable-v1.1.3)

## Context

The portfolio demo previously had **only `Customer`** as a domain entity
(plus auth-related tables `app_user`, `audit_event`, `refresh_token`). For
a recruiter / hiring-manager evaluating breadth-of-skill, this is too
narrow — every interesting demonstration (transaction, FK cascades,
property-based invariants, cross-entity tests) needs at least one
business relation.

Three options were considered to expand the surface :

- **A.** Extend `Customer` with sub-entities (addresses, contact methods)
  → breadth-of-table count grows but no real business semantics.
- **B.** Add a single `Order` table with embedded line array
  (jsonb / `@ElementCollection`) → cheap, but no per-line state, no
  refund granularity, no property-test invariants worth showing.
- **C.** Pattern A simplified : 3 e-commerce entities — `Order`, `Product`,
  `OrderLine` — with `OrderLine` as a **first-class entity** (not a join).

C wins because it gives :
- A real FK chain (`Customer ← Order → OrderLine ← Product`).
- Per-line lifecycle (PENDING / SHIPPED / REFUNDED) — refund-by-line
  is a recognisable real-world workflow.
- A snapshot price (`unit_price_at_order`) — the immutability invariant
  is an excellent property-test target (Hypothesis / jqwik).
- A computed-total invariant (`total_amount == Σ(line.qty × line.unit_price_at_order)`)
  — another property-test target ; also surfaces consistency bugs.

## Decision

Adopt **Pattern C** : add `Order`, `Product`, `OrderLine` as 3 new
entities to both backends + the UI, while keeping `Customer` (and all
auth tables) untouched.

### Schema

```
┌──────────┐       ┌───────────┐       ┌────────────┐       ┌──────────┐
│ customer │──◇───<│   order   │──◇───<│ order_line │>───◇──│ product  │
│  (V1)    │  1..n │ (V8/0003) │  1..n │ (V9/0004)  │  n..1 │ (V7/0002)│
└──────────┘       └───────────┘       └────────────┘       └──────────┘
```

(`◇` = aggregate root ; `<` = FK side. `Order` aggregates `OrderLine`,
`OrderLine` references `Product` for catalogue lookup but carries its
own snapshot fields.)

### Field detail

#### `Product`

| Column | Type | Notes |
|---|---|---|
| `id` | `BIGSERIAL` PK | |
| `name` | `VARCHAR(200) NOT NULL` | |
| `description` | `TEXT` | nullable |
| `unit_price` | `NUMERIC(12,2) NOT NULL CHECK (unit_price > 0)` | |
| `stock_quantity` | `INTEGER NOT NULL CHECK (stock_quantity >= 0)` | |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

#### `Order` (table named `orders` to dodge the SQL keyword)

| Column | Type | Notes |
|---|---|---|
| `id` | `BIGSERIAL` PK | |
| `customer_id` | `BIGINT NOT NULL REFERENCES customer(id)` | |
| `status` | `VARCHAR(16) NOT NULL CHECK (status IN ('PENDING','CONFIRMED','SHIPPED','CANCELLED'))` | |
| `total_amount` | `NUMERIC(14,2) NOT NULL DEFAULT 0` | recalculated on line change |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

#### `OrderLine`

| Column | Type | Notes |
|---|---|---|
| `id` | `BIGSERIAL` PK | |
| `order_id` | `BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE` | cascade so `DELETE order` clears lines |
| `product_id` | `BIGINT NOT NULL REFERENCES product(id) ON DELETE RESTRICT` | restrict so a referenced product can't vanish |
| `quantity` | `INTEGER NOT NULL CHECK (quantity > 0)` | |
| `unit_price_at_order` | `NUMERIC(12,2) NOT NULL` | **immutable** : snapshot of `product.unit_price` at insert time |
| `status` | `VARCHAR(16) NOT NULL CHECK (status IN ('PENDING','SHIPPED','REFUNDED'))` | per-line cycle |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

## Why `OrderLine` is an entity, not a join table

A pure many-to-many join carries only the 2 FKs and maybe a quantity. We
need more :

1. **Snapshot price** — when a `Product.unit_price` changes after an order
   ships, we must NOT retroactively rewrite the order's total. Storing
   `unit_price_at_order` immutably makes the line audit-correct.
2. **Per-line cycle** — partial refunds and partial shipments are real
   workflows (e.g. "ship items A and B now, item C is back-ordered").
   That requires `OrderLine.status` independent from `Order.status`.
3. **Future extensibility** — discount-per-line, line-level VAT,
   serialised inventory tracking all want a row to attach to.
4. **The "is-it-an-entity?" test** — if an instance has its own ID + state
   that mutates beyond the FKs (status, snapshot fields), it's an entity.
   `OrderLine` passes both criteria.

## Cross-language consistency

| Aspect | Java (Spring Data JPA) | Python (SQLAlchemy 2.x async) |
|---|---|---|
| Migrations | Flyway V7/V8/V9 | Alembic 0002/0003/0004 |
| ORM | `@Entity`, `@OneToMany(cascade = REMOVE)` | `Mapped[...]`, `relationship(cascade="all, delete-orphan")` |
| DTO layer | OpenAPI-annotated controllers | Pydantic v2 with strict mode |
| Endpoints | `/products`, `/orders`, `/orders/{id}/lines/{lineId}` | identical paths |
| Async | virtual threads (Java 25 default) | `asyncpg` driver, `async def` endpoints |

OpenAPI contract MUST be byte-identical between the 2 backends so the UI
([iris-ui](https://gitlab.com/iris-7/iris-ui)) can switch
backends transparently via the `EnvService` flag.

## Invariants — property-test surface

These are the invariants the test suite (jqwik on Java, Hypothesis on
Python) MUST verify :

1. **Total consistency** : `Order.total_amount == Σ(line.quantity × line.unit_price_at_order)` for all lines.
2. **Stock non-negativity** : `Product.stock_quantity >= 0` after any sequence of CRUD operations.
3. **Snapshot immutability** : updating `Product.unit_price` does NOT change any existing `OrderLine.unit_price_at_order`.
4. **Order-status transitions** : valid graph is `PENDING → CONFIRMED → SHIPPED` and `* → CANCELLED` (any state can cancel).
5. **OrderLine-status transitions** : valid graph is `PENDING → SHIPPED` and `SHIPPED → REFUNDED` ; no skip.
6. **Cascade safety** : `DELETE order` removes all `OrderLine` rows but does NOT touch referenced `Product` rows.

## Excluded scope

- **Inventory reservation / stock decrement on order** — the foundation
  ships only the schema. Whether `stock_quantity` decrements on
  `Order.CONFIRMED` is a follow-up decision. The current code does NOT
  decrement (intentional : keeps the foundation small ; revisit when
  the chaos demo needs it).
- **Multi-currency, tax, discount** — out of scope ; `unit_price` is
  treated as a single currency (EUR), VAT included, no per-line discount.
- **Audit log** — `audit_event` table exists for `Customer` ; extending
  to Order/OrderLine is a follow-up (would tighten the demo's
  audit story).
- **Idempotency on `POST /orders`** — already covered by the existing
  `IdempotencyFilter` (java) / equivalent middleware (python). No
  schema change.

## Consequences

✅ **Cross-cutting test surface** — 6 invariants × 2 property-test frameworks = 12 high-value tests that the 90% coverage gate will be backed by.
✅ **Recruiter-readable** — "Customer / Order / OrderLine" is recognised in 1 second ; demonstrates SQL FK literacy + cycle modelling.
✅ **Refund / cancellation demo** — surfaces a real per-line workflow that resonates beyond CRUD.

⚠ **More CRUD endpoints** — 3 entities × 4 verbs = 12 base endpoints (plus the nested `/orders/{id}/lines/{lineId}`). Most are foundation-level (no business logic yet) ; the architectural cost is contained.
⚠ **Migration numbering coupled** — V7/V8/V9 (java) and 0002/0003/0004 (python) must land in this order ; renumbering is painful.
⚠ **`Product.unit_price` change UX** — UI must NOT promise that updating a Product's price retroactively changes any past order. The Product-edit screen needs an explicit hint.

## References

- [Java foundation MR](https://gitlab.com/iris-7/iris-service-java/-/merge_requests?scope=all&state=merged&search=feature%2Forder)
- [Python foundation MR](https://gitlab.com/iris-7/iris-service-python/-/merge_requests?scope=all&state=merged&search=feature%2Forder)
- [UI Orders foundation MR !155](https://gitlab.com/iris-7/iris-ui/-/merge_requests/155)
- [Common ADR-0001 — polyrepo via submodule](https://gitlab.com/iris-7/iris-common/-/blob/main/docs/adr/0001-shared-repo-via-submodule.md)
- [java ADR-0008 — feature-slicing](https://gitlab.com/iris-7/iris-service-java/-/blob/main/docs/adr/0008-feature-slicing.md) (where `com.iris.order.*` lives)
- Eric Evans, *Domain-Driven Design* (2003), ch. 5 § "Entities" — the criterion that motivated treating `OrderLine` as an entity.
