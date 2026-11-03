# M2 offline contracts and recovery

No transport, endpoint, credentials, SDK or external connection is implemented.
`APIContracts.swift` is a client-side contract proposal, not proof of deployed API
compatibility. Only `BackendContracts.swift` documents existing request/legacy row
shapes. The existing service still accepts domain actions; a future adapter must
map approved commands explicitly, not serialize arbitrary UI actions as RPCs.

`APIField` distinguishes missing, explicit null and a value. `WeekSnapshotResponse`
retains all eight existing weekly fields independently, including nulls, and keeps
unknown attributes in its raw record. Financial cents are strict Int64. No partial
wire snapshot is converted into fabricated domain totals. The existing complete
`WeekResponse` remains strict for complete synthetic dashboard fixtures.
`OperationRequest` carries a caller-created UUID and Codable typed payload;
`OperationResponse` retains nullable result/error/operation identity. Consumers
must call `requireResult`; missing/null result and simultaneous result/error fail.
The legacy weekly decoder now rejects ambiguous envelopes instead of falling back.
Unknown server error codes/details remain structured data, never default success
or an inferred retry instruction. `APIValue` preserves JSON structure using
Int64/Decimal numbers; byte-for-byte JSON/numeric lexical preservation and arbitrary
precision are not promised. Response size/depth limits belong to a future adapter.

`HouseholdService` contains read/write/logout only. `SampleHouseholdService` adds
sample login/scenario controls. The current `HouseholdStore` deliberately requires
the sample protocol so a production repository cannot accidentally become sample
login or use synthetic scenarios. Production identity/store composition is M3.

The store publishes typed write states and conservative failure recovery. Each
unresolved equal intent retains its UUID even when another intent intervenes.
Retries are explicit, never automatic. Definitive local validation/permission
failure releases the ID; offline/read errors retain it. Lost responses, cancellation
and unknown errors retain identity and label the outcome uncertain. Cancellation
is not rollback. Mock mutation checks cancellation before its atomic actor block;
a returned receipt remains confirmed even if the caller is subsequently cancelled.
Refresh cancellation retains the last snapshot read-only until an explicit refresh.
Sign-out clears IDs/state/cache and generation checks discard late results.

Pending intent identities are memory-only and scoped to a sample session. Equal
unresolved payloads are treated as retries; after confirmed success identical new
purchases get new IDs. M5 needs durable user intent IDs, explicit unresolved-intent
UI, server reconciliation, retention bounds and verified idempotency support before
real writes. A server must bind IDs to identity/household/payload atomically; the
client UUID alone does not provide distributed exactly-once execution.

`SourceFreshnessResponse` distinguishes absent/null freshness and timestamps,
preserves unknown states/raw timestamp strings, and never invents an age threshold.
Sample source rows now use typed fresh/never-synced/unavailable states, visible in
the UI. Parsing timestamps, scheduling aging, per-source partial failure and stale
cache policy await agreed server contracts under M4/M8/M9. Freshness never promotes
purchases or recomputes budget/refund/week-close/fund/savings totals.

## Approval dependencies before integration

- Explicit approval of a separate synthetic staging project and allowed identities.
- API review of command mapping, envelope/error codes, nullable field semantics,
  UUID echo/atomic idempotency/reconciliation, source states/timestamp format and
  complete outgoing-debt/fund/savings/provenance payloads. These are proposed
  contracts, not requests to change existing production endpoints.
- Already documented product decisions: future-effective policy/override/reversal
  semantics, refund link resolution and admin departure/account deletion ownership.
- Separate approval for any cloud simulator run or provider/Apple capability work.

No approval is needed for continued offline tests. No existing financial rule is
reopened by these API questions.
