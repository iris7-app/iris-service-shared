# 0063. Order line refund state machine — transitions + audit

Date: 2026-04-27
Status: Proposed

## Context

Per [ADR-0059](0059-customer-order-product-data-model.md), the
`OrderLine` entity carries a per-line lifecycle status (`PENDING`,
`SHIPPED`, `REFUNDED`) that is **independent** of the parent
`Order.status`. The shared invariant captured in ADR-0059 §"Invariants"
already specifies the state graph informally :

> **OrderLine-status transitions** : valid graph is `PENDING → SHIPPED`
> and `SHIPPED → REFUNDED` ; no skip.

The transition logic is wired in code (Java's `OrderLineStatus.canTransitionTo()`
+ Python's `OrderLineStatus.can_transition_to()` — both already implement
the rule), but **no write endpoint exposes the transition** today. The
UI surfaces line status as a read-only badge ; partial refunds, defective
lines, and customer-service goodwill workflows that motivated the per-line
cycle in the first place are unreachable from the product surface.

This ADR specifies :

1. The full state graph + the rationale for the no-skip rule (audit
   requirement) — promoted from "invariant note" in ADR-0059 to a
   first-class architectural decision.
2. The write endpoint contract that BOTH backends MUST expose
   identically (java + python) so the UI consumer is byte-equivalent.
3. The audit-event contract — every transition is recorded, including
   refund reason + actor + timestamp.
4. The refund-amount contract — refunds use the immutable
   `unit_price_at_order` snapshot, NOT the current `Product.unit_price`
   (consistent with ADR-0059's snapshot immutability invariant).
5. The UI affordance — a "Refund line" button conditional on
   `status == "SHIPPED"` ; reason dialog ; PATCH submit ; refresh.

This ADR does NOT cover **money flow** — the actual refund to the
customer's payment instrument is a payment-processor concern (Stripe /
Adyen / etc) and belongs in a separate ADR when the integration lands.
The endpoint described here updates domain state and records the
intent ; the financial side-effect is out of scope.

## Decision

### State graph (formalised)

```
   ┌─────────┐         ┌──────────┐         ┌──────────┐
   │ PENDING │ ──────> │ SHIPPED  │ ──────> │ REFUNDED │
   └─────────┘         └──────────┘         └──────────┘
                                                  ▲
                                          (terminal — no exit)
```

- `PENDING → SHIPPED` : a line is dispatched ; the parent order may or
  may not be in `SHIPPED` status (partial shipments are explicitly
  supported by the per-line cycle).
- `SHIPPED → REFUNDED` : the line is returned / refunded ; terminal.
- `PENDING → REFUNDED` : **rejected**. The audit requirement is that a
  refund must follow a shipment ; refunding a line that was never
  shipped is modelled as a **cancellation** of the parent order (or a
  line deletion before shipping) — not as a refund.
- Self-transitions allowed (idempotent re-affirm) so the PATCH endpoint
  is safe to retry without surfacing a 409 on a duplicate request.
- Backwards transitions forbidden (no `REFUNDED → SHIPPED`, no
  `SHIPPED → PENDING`) — refunds and shipments are append-only events
  in the audit trail.

### Write endpoint — `PATCH /orders/{order_id}/lines/{line_id}/status`

Both backends expose the **same path** + **same body shape** + **same
error contract**.

**Request body** :
```json
{
  "status": "SHIPPED" | "REFUNDED",
  "reason": "string (required for REFUNDED, optional for SHIPPED, ≤ 500 chars)"
}
```

- `status` is required ; values restricted to `SHIPPED` or `REFUNDED`
  (the only two transitions reachable from a non-terminal state).
- `reason` is required when `status == "REFUNDED"` (audit requirement —
  blank refunds are rejected) ; optional but accepted for `SHIPPED`
  (shipping notes).

**Response** : the updated line as `OrderLineDto` / `OrderLineResponse`,
with `status` reflecting the new value + `updatedAt` advanced.

**Error contract** :

| Condition | Status | Body |
|---|---|---|
| Line not found | `404` | `{ "detail": "OrderLine not found" }` |
| Order not found | `404` | `{ "detail": "Order not found" }` |
| Line does not belong to the path's order | `404` | same as above (don't leak which) |
| Invalid transition (e.g. `PENDING → REFUNDED` or `REFUNDED → *`) | `409` | `{ "detail": "Invalid transition <FROM> → <TO>" }` |
| `status` missing or unknown enum value | `422` | Pydantic / Bean-validation error |
| `reason` missing on `REFUNDED` request | `422` | Pydantic / Bean-validation error |
| Reason longer than 500 chars | `422` | Pydantic / Bean-validation error |

**Why PATCH and not POST** :
- The transition mutates an existing resource's state ; the resource
  identity (`/orders/{order_id}/lines/{line_id}`) does not change.
  PATCH is the canonical verb (RFC 5789 §1).
- POST would suggest creating a new sub-resource (e.g. a refund event),
  which is a valid alternate design but couples the write API to the
  audit-store schema. We keep them separate : the endpoint mutates
  domain state ; the audit hook records the intent.
- Follow-up : if the audit trail evolves into a queryable resource
  (`GET /orders/{order_id}/lines/{line_id}/audit`), it becomes a
  separate read endpoint — the PATCH stays the write entry point.

### Audit contract

Every successful transition writes one row via the existing audit hook :

- **Java** : `auditEventPort.recordEvent(actor, action, detail, ip)` —
  same port as login / token-refresh events, exposed by
  `com.iris.observability.port.AuditEventPort` (already wired across
  the Java codebase).
- **Python** : the equivalent audit-event hook (today implemented
  inline in `customer/audit_router.py` ; once the `audit_event` table
  ships per the python TASKS.md item, write through that). Until the
  table lands, log via the structured logger with the same keys so a
  later migration to the table is a swap-not-rewrite.

The audit row carries :

| Field | Value |
|---|---|
| `actor` | the authenticated principal username (JWT subject), `"system"` if invoked by an admin tool, never null |
| `action` | `ORDER_LINE_SHIPPED` or `ORDER_LINE_REFUNDED` |
| `detail` | `"order=<order_id> line=<line_id> reason=<reason>"` truncated to 500 chars |
| `ip` | source IP from the request, null if not available |
| `created_at` | server-side timestamp (NOT user-provided) |

**Why record the actor** : refunds are a moderation / customer-service
action ; the audit trail must answer "who refunded line X ?" without
requiring log-stitching. Login events already establish the `actor`
contract — the refund event piggybacks on the same surface.

### Refund amount contract

Refunds refund the **snapshot price** captured at order time
(`OrderLine.unit_price_at_order`) — NOT the current `Product.unit_price`.

Concretely, if a customer ordered Widget at €10 and the catalogue price
later moves to €15, refunding the line credits €10 × quantity, not €15.

This is consistent with ADR-0059 §"Snapshot immutability" :

> updating `Product.unit_price` does NOT change any existing
> `OrderLine.unit_price_at_order`.

The PATCH endpoint does NOT compute or return the refund amount itself —
that is a UI-side derivation from `quantity × unit_price_at_order` (both
already in the line DTO). The endpoint's job is the state transition +
audit ; the UI displays the implied amount in the confirm dialog.

When a payment-processor integration ships, this same snapshot is the
authoritative refund amount the integration computes — confirming the
choice now avoids retro-engineering when money flow lands.

### UI affordance (consumer side, for context)

The UI ([`iris-ui`](https://gitlab.com/iris-7/iris-ui)) surfaces
the transition on the order-detail screen (`features/commerce/orders/`) :

1. Each line row carries the existing read-only status badge.
2. When `line.status === "SHIPPED"`, render a **"Refund line"** button
   next to the badge. When `PENDING`, render no action (refund
   unreachable). When `REFUNDED`, render no action (terminal).
3. Click → open a modal dialog asking for `reason` (textarea, required,
   ≤ 500 chars) + show the implied refund amount (computed UI-side from
   `quantity × unit_price_at_order`). Submit issues the PATCH.
4. On 200, refresh the order detail (re-fetch — the DTO already carries
   the new status). On 409, surface a "transition no longer valid"
   message (likely a concurrent refund — page reload reconciles).
5. The "Ship line" affordance follows the same pattern conditional on
   `status === "PENDING"` (less urgent — admin / fulfilment workflow,
   ships when warehouse integration matures).

The button is gated on the user's role — only `ROLE_ADMIN` or a future
`ROLE_REFUND_OPERATOR` may invoke the refund. Java uses
`@PreAuthorize("hasAuthority('ROLE_ADMIN')")` on the controller method ;
Python uses `Depends(require_role(Role.ADMIN))`.

## Why this pattern over alternatives

### Considered : "use the existing OrderLine PUT endpoint"

Add a generic `PUT /orders/{order_id}/lines/{line_id}` that accepts the
full line body and lets the caller change anything.

❌ **No invariant enforcement** — a PUT body could mutate
`unit_price_at_order` (breaks ADR-0059 snapshot immutability) or jump
states arbitrarily.
❌ **No audit by default** — a generic update endpoint records "line
modified" but loses the semantic event ("line refunded with reason X").

A scoped PATCH with a constrained body buys discipline at the cost of
one more endpoint. Worth it.

### Considered : single endpoint covering all transitions

Use one verb (e.g. POST `/orders/{order_id}/lines/{line_id}/transitions`)
with a body that names the transition (`{"to": "REFUNDED"}`).

✅ Pros : extensible — adding a future `RETURNED_TO_INVENTORY` state
is a body value, not a new endpoint.
❌ Cons : less REST-idiomatic ; the `to` field doubles up with the
target state expressed by the URL — the PATCH on the resource itself
is shorter to remember.

PATCH wins for the foundation ; if the lifecycle gains a third
transition path (e.g. partial refund of a partial line ?), revisit.

### Considered : no audit, just state mutation

Skip the audit hook. The DB row carries `status` + `updated_at` —
"good enough".

❌ Loses the **reason** (free text, customer-service context) — the
DB column doesn't exist and adding a `refund_reason` column couples the
schema to one transition reason. The audit table is the right home
because every transition can carry context, not just refunds.
❌ Loses the **actor** trail. `Order.updated_at` says "something
changed" ; only the audit row says "Alice from customer-service
refunded this".

The audit hook already exists for login events ; reusing it costs ~4
lines per backend. No reason to skip.

## Consequences

### Positive

- **Auditable refund trail** — every transition is recorded with actor,
  action, reason, timestamp. Customer-service queries ("who refunded
  order #X line #Y ?") become one SQL query.
- **UI affordance unblocked** — `iris-ui` can ship the refund button
  + dialog without further backend ambiguity. The existing read-only
  badge + the new PATCH endpoint complete the round-trip.
- **State machine enforced server-side** — the existing
  `canTransitionTo` / `can_transition_to` logic is reused, not
  re-implemented in controllers. Invalid transitions return 409 from
  the same code path, both backends.
- **Snapshot price upheld** — refund amount derives from
  `unit_price_at_order` ; the catalogue price drift is invisible to
  historical refunds. ADR-0059 invariant 3 carried through.

### Negative

- **Money flow not handled** — the endpoint records intent but does
  NOT credit the customer's payment instrument. A payment-processor
  integration is the follow-up ; until it ships, refunds are
  domain-only (the audit trail says "refunded" but the customer is not
  yet credited). Document this explicitly in the UI confirm dialog.
- **Reason field is free-text** — no structured taxonomy of refund
  reasons (defective / wrong-item / customer-service / etc). Free text
  is sufficient for the demo ; production-grade would add a
  `reason_code` enum on top.
- **Audit row lives in the existing `audit_event` table** — same trail
  as login events. Operational queries that filter by `action LIKE
  'ORDER_LINE_%'` are easy ; full separation (refund-only audit table)
  is overkill at this scale.
- **No idempotency-key on the PATCH** — the existing
  `IdempotencyFilter` (java) / equivalent middleware (python) does
  cover PATCH for replay safety. Self-transitions returning 200 is the
  app-level idempotency contract ; the filter adds belt-and-braces.

### Neutral

- **Per-line cycle vs parent order** — already independent per
  ADR-0059 ; this ADR doesn't change the parent `Order.status` graph.
  An order with all-REFUNDED lines stays in whatever status it was in
  (typically `SHIPPED`) ; the order-level lifecycle and the line-level
  lifecycle move on separate clocks. UI-side computed flags ("all
  lines refunded ?") derive from the lines, not from a new parent
  state.

## Operational reference

### Java implementation outline (follow-up MR)

```java
@PatchMapping("/{orderId}/lines/{lineId}/status")
@PreAuthorize("hasAuthority('ROLE_ADMIN')")
public ResponseEntity<OrderLineDto> transitionStatus(
        @PathVariable Long orderId,
        @PathVariable Long lineId,
        @Valid @RequestBody OrderLineStatusTransitionRequest req,
        Principal principal,
        HttpServletRequest httpRequest) {
    OrderLine line = orderLineRepo.findByOrderIdAndId(orderId, lineId)
        .orElseThrow(() -> new NotFoundException("OrderLine not found"));
    if (!line.getStatus().canTransitionTo(req.status())) {
        throw new ConflictException(
            "Invalid transition " + line.getStatus() + " -> " + req.status());
    }
    line.setStatus(req.status());
    OrderLine saved = orderLineRepo.save(line);
    auditEventPort.recordEvent(
        principal.getName(),
        "ORDER_LINE_" + req.status(),
        "order=" + orderId + " line=" + lineId + " reason=" + req.reason(),
        clientIp(httpRequest));
    return ResponseEntity.ok(OrderLineDto.from(saved));
}
```

### Python implementation outline (follow-up MR)

```python
@router.patch("/{order_id}/lines/{line_id}/status", response_model=OrderLineResponse)
async def transition_line_status(
    order_id: int,
    line_id: int,
    payload: OrderLineStatusTransitionRequest,
    session: DbSession,
    principal: Annotated[Principal, Depends(require_role(Role.ADMIN))],
) -> OrderLineResponse:
    line = await order_line_repo.find_by_order_and_id(order_id, line_id)
    if line is None:
        raise HTTPException(404, "OrderLine not found")
    current = OrderLineStatus(line.status)
    target = OrderLineStatus(payload.status)
    if not current.can_transition_to(target):
        raise HTTPException(409, f"Invalid transition {current} -> {target}")
    line.status = target.value
    saved = await order_line_repo.update(line)
    await audit_event_hook(
        actor=principal.username,
        action=f"ORDER_LINE_{target}",
        detail=f"order={order_id} line={line_id} reason={payload.reason}",
    )
    return OrderLineResponse.from_orm_entity(saved)
```

### UI hook outline (follow-up MR)

```typescript
// In features/commerce/orders/order-detail.component.ts
async refundLine(line: OrderLine): Promise<void> {
  const reason = await this.dialog.openRefundReason(line);
  if (!reason) return;
  await this.orderApi.transitionLineStatus(line.orderId, line.id, {
    status: 'REFUNDED',
    reason,
  });
  await this.refresh();
}
```

## References

- [shared ADR-0059 — Customer/Order/Product/OrderLine data model](0059-customer-order-product-data-model.md) — the per-line cycle invariant promoted to first-class status here
- [`iris-ui` TASKS.md](https://gitlab.com/iris-7/iris-ui/-/blob/main/TASKS.md) — "Per-line refund state machine" entry that motivated this ADR
- [`iris-service-java` follow-up MR](https://gitlab.com/iris-7/iris-service-java/-/merge_requests?scope=all&state=all&search=order-line-refund) — Java implementation
- [`iris-service-python` follow-up MR](https://gitlab.com/iris-7/iris-service-python/-/merge_requests?scope=all&state=all&search=order-line-refund) — Python implementation
- [`iris-ui` follow-up MR](https://gitlab.com/iris-7/iris-ui/-/merge_requests?scope=all&state=all&search=refund-line-action) — UI consumer switch
- RFC 5789 — HTTP PATCH method (the verb choice rationale)
- 2026-04-27 session — UI side surfaced the gap as a "to consider" item ; this ADR unblocks the spec without committing the implementation in the same MR.
