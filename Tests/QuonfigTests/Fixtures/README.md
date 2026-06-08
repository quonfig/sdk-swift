# Wire fixtures (SOURCE-DERIVED — not a live capture)

These JSON fixtures pin the two HTTP wire shapes the Swift SDK codes against:
the `eval-with-context` response envelope and the telemetry upload body, plus
the ETag / `If-None-Match` 304 conditional-GET exchange.

> **Provenance: these are SOURCE-DERIVED, not captured from a live server.**
> At the time qfg-2t2d.1 ran, `api-delivery` was not running locally
> (`GET http://localhost:6550/` refused the connection). Per the bead's fallback
> instruction, every shape below was transcribed field-by-field from the
> authoritative Go types and the closest frontend analog (`sdk-javascript`), NOT
> paraphrased from the plan. The values (IDs, hashes, counts, timestamps) are
> illustrative; the **shapes, key names, casing, and which optionals are present
> vs. omitted** match the source exactly. When `api-delivery` is reachable,
> replace these with a real capture and drop this caveat.

## Sources each fixture was derived from

| Fixture | Authoritative source |
|---------|----------------------|
| `eval-with-context.response.json` | `api-delivery/internal/config/types.go` (`EvalEnvelope`, `EvalResult`, `Value`, `Meta`) and `api-delivery/internal/serve/eval_context.go` (`ServeHTTP`). Cross-checked against `sdk-javascript/src/types.ts` (`EvaluationPayload`, `Evaluation`). |
| `etag-exchange.json` | `eval_context.go` `ServeHTTP` (ETag header set on 200, `If-None-Match` → 304 with empty body) + `evalContextETag`. Client side: `sdk-javascript/src/loader.ts` (`If-None-Match` request header, 304 handling). |
| `telemetry-post.body.json` | `sdk-javascript/src/telemetry/evaluationSummaryAggregator.ts` (`TelemetryEvents` / `ConfigEvaluationSummaries` / `ConfigEvaluationSummary`) and `sdk-javascript/src/types.ts` (`ConfigEvaluationCounter`, `ConfigEvaluationMetadata`). Endpoint + headers: `sdk-javascript/src/telemetry/uploader.ts`. |

## eval-with-context response envelope

`GET /api/v2/configs/eval-with-context/{base64url(contextJSON)}?collectContextMode=PERIODIC_EXAMPLE`

Envelope (camelCase):

```
{ evaluations: { <key>: { value: { type, value }, configId, configType, valueType,
                          reason?, ruleIndex?, weightedValueIndex? } },
  meta: { version, environment, workspaceId? } }
```

Optional fields use Go `omitempty` — **absent when empty, never `null`**. The
fixture exercises every optional combination so the Swift decoder must use
`decodeIfPresent`:

- `STATIC` evaluation (`new-checkout`, `rate-limit`, `pricing`): `reason` present,
  but `ruleIndex` and `weightedValueIndex` **omitted** (eval_context.go emits
  indexes only for `TARGETING_MATCH` / `SPLIT`).
- `TARGETING_MATCH` (`button-color`): `reason` + `ruleIndex` present,
  `weightedValueIndex` **omitted**.
- `SPLIT` (`checkout-experiment`): `reason` + `ruleIndex` + `weightedValueIndex`
  all present.
- `meta.workspaceId` is **omitted** here — `ServeHTTP` builds `Meta` with only
  `Version` + `Environment`, so the live frontend response never carries it
  (`workspaceId,omitempty` in `types.go`). The Swift `Meta` decoder must treat it
  as optional.

`value.type` (the inner `Value.Type`) is one of the `ValueType` constants in
`types.go`: `bool | int | double | string | json | string_list | log_level |
weighted_values | schema | provided`. `valueType` (the outer config's declared
type) draws from the same set.

### Reason enum (verified spelling/casing)

`eval_context.go` `resolutionReason` emits exactly three values, UPPER_SNAKE_CASE:

```
STATIC | TARGETING_MATCH | SPLIT
```

The SDK additionally synthesizes `DEFAULT` (key missing from envelope) and
`ERROR` (served stale/from cache) caller-side — those never appear on the wire.
Per the plan §2.3, an unknown wire `reason` must decode to `ERROR`, not fail.

### collectContextMode (verified)

`telemetry/collectmode_test.go` confirms the accepted query values
(UPPER_SNAKE_CASE), default `PERIODIC_EXAMPLE`:

```
NONE | SHAPE_ONLY | PERIODIC_EXAMPLE
```

## ETag / If-None-Match 304 exchange

`eval_context.go` sets `ETag` on the 200 and returns a **bare 304 with an empty
body** when the request's `If-None-Match` equals the current ETag (the SDK keeps
the prior payload — see `loader.ts`). The ETag is opaque (hex; first 16 bytes of
a SHA-256 over version + context + environment + keyType), so the client must
echo it verbatim and never parse it. `etag-exchange.json` captures both halves.

## Telemetry POST body

`POST {telemetry-host}/api/v1/telemetry/` (host = `telemetry.<QUONFIG_DOMAIN>`,
served by **api-telemetry**, not api-delivery). Headers from `uploader.ts`:
`Authorization: Basic …`, `Content-Type: application/json`, `Accept:
application/json`.

Body shape (`evaluationSummaryAggregator.ts`):

```
{ instanceHash, clientName, clientVersion,
  events: [ { summaries: { start, end,
              summaries: [ { key, type,
                counters: [ { configRowIndex, conditionalValueIndex, configId,
                              reason?, ruleIndex?, weightedValueIndex?,
                              selectedValue: { <config.type>: <value> },
                              count } ] } ] } } ] }
```

The Swift client sets `clientName: "swift"` (plan §2.3). `selectedValue` is a
single-key object whose key is the config's value type and whose value is the
massaged selected value (`massageSelectedValue`). The client posts evaluation
summaries **only** — context shapes and example contexts are posted server-side
by api-delivery (gated by `collectContextMode`); the client never sends them.
