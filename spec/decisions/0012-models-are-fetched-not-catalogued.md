# 0012. Models are fetched, not catalogued

- Status: Accepted
- Date: 2026-09-21

## Context

[0010](0010-integrated-providers-are-presets.md) decided that an integrated
provider carries "a model catalogue recording, per model, which wire format
serves it", and rejected inferring an endpoint from a model name.

Implementing that produced a hardcoded table of model ids taken from the
vendors' published documentation. It was partial by construction, unverifiable
from here, and — as probing showed — actively wrong: it refused models that
work.

Measured on 2026-09-21:

| Endpoint | Result |
|---|---|
| `api.commandcode.ai/provider/v1/models` | 71 models, each with `supported_endpoints` |
| `opencode.ai/zen/v1/models` | 6.2KB of `{ id, object, created, owned_by }` |
| `opencode.ai/zen/go/v1/models` | 3.1KB, same shape |

CommandCode's distribution: **55 models support `/chat/completions`**, 8 are
`/messages`-only, 8 are `/chat/completions`-only. The hardcoded catalogue
described roughly one of those 71, and refused the other 54 that would have
worked — the opposite of the failure 0010 was trying to avoid.

Two further findings:

- **The lists are public.** All three answered without a credential.
- **A credential can make it worse.** Zen answers `401 Invalid credential` to a
  key it rejects on a list that is public otherwise, turning a 200 into a
  failure. So a credential is sent first and a rejection is retried without.

## Decision

**The model list is fetched from the provider, not written down.**

- Fetched over `GET <base>/models`, cached on disk with a 24-hour TTL, and
  **never fetched from the request path** — a network call mid-keystroke is not
  acceptable, so a request decides from cache or from the rules.
- **Where a gateway publishes routing, the catalogue is authoritative.**
  CommandCode's `supported_endpoints` decides, with no rule involved.
- **Where it publishes none** — Zen and Go — a narrow, documented prefix rule
  stands in, and is returned with reason `rule` rather than `catalogue`.
- Resolution order is **override → catalogue → rule**, and the reason is
  returned so a caller can tell an authoritative answer from a fallback.
- Providers are declarations in `lua/agent-smith/providers/`, one file each,
  with all behaviour in `base.lua`.

## Consequences

### Positive

- No model list to maintain, so drift is impossible rather than merely unlikely.
- 55 of CommandCode's 71 models became reachable purely by asking, instead of
  being refused by a table written from documentation.
- Adding a provider is a file of fields.
- Chat completions is preferred when a model offers it, so a model offering both
  is not routed to an adapter that does not exist yet.

### Negative / costs

- **A blocking network call**, mitigated by the cache and by never doing it
  implicitly. The fetch is still synchronous when it happens.
- **Zen and Go routing still rests on a rule**, which is precisely what 0010
  objected to. The rule is now confined to the two gateways that publish
  nothing, labelled as a fallback, and overridable per request — but it is a
  rule, and a vendor rename would still break it.
- **A stale cache can route wrongly.** The TTL bounds it and `refresh` exists,
  but a wrong entry fails as a vendor error rather than at configuration time.
- The catalogue is only as good as the endpoint, and only one of the three
  publishes routing at all.

## Alternatives considered

**Keep the hardcoded catalogue.** Rejected on measurement: it refused working
models and would have gone stale silently.

**Fetch on every request.** Rejected: a blocking network call between a
keystroke and a request is worse than a day-old model list.

**Infer routing for all three from model names.** Rejected in 0010 and still
rejected. It survives only where a gateway publishes nothing, where the
alternative is refusing every model on it.

**Read the vendor CLI's model list** (`opencode models`). Rejected: that is the
wrapper pattern [0001](0001-own-the-agent-loop.md) exists to replace. The HTTP
endpoint is right there and returns the same data.

## Related

- [0010](0010-integrated-providers-are-presets.md) — amended by this record
- [../providers.md](../providers.md) — base URLs, credentials, endpoints
