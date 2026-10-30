# Lucas gap-close progress

> Updated: 2026-10-30 (Asia/Shanghai) · local clone only · no push/publish/release

## HEAD

See `git rev-parse HEAD` after the latest local commit from this batch (store v5 + self-healing + tools + store stats UI).

Start of batch: `768229b`.

## Store (`lucas.store`)

Namespace version: **v5** (recorded in `persistence_migrations`).

### Tables (29 data + persistence_migrations)

metadata, configurations, sessions, turns, permission_grants, tool_invocations, configuration_history, custom_model_routes, speech_profiles, memories, agent_tasks, alarms, mcp_events, modules, runs, knowledge_documents, subscriptions, context_snapshots, cancellations, capability_delegations, information_revisions, generated_tool_artifacts, **information_types**, **information_heads**, **information_processors**, **deliveries**, **situations**, **self_healing_events**, persistence_migrations.

### New ops (v5)

| Op | Notes |
|---|---|
| `information.types.list` / `upsert` | PK `(type_id, schema_version)` |
| `information.heads.list` / `set` | head revision pointer |
| `information.processors.list` / `upsert` | module capability processors |
| `deliveries.list` / `upsert` | subscription delivery ledger |
| `situations.list` / `upsert` | agent runtime situations |
| `selfhealing.events.list` / `append` | Lucas-side self-heal ledger |
| `kernel.store.stats` | table → row count map |

## Self-healing scaffold

- On `lucasd` start: ensure `~/Library/Application Support/Lucas/self-healing/` (or `LUCAS_CLONE_HOME/self-healing/`).
- Append JSONL `events.jsonl` + SQLite `self_healing_events` row with kind `boot`.
- `UnixSocketServer.start`: on bind failure, unlink + retry once; if recovered, daemon logs and appends kind `socket.bind.recover`.

## Tools added / extended

| Tool | Notes |
|---|---|
| `system.hostname` | Host / ProcessInfo |
| `system.os.version` | macOS version tuple |
| `system.app.support.paths` | Lucas support / store / socket / logs / self-healing |
| `system.user.defaults` | get/set, **Lucas-scoped keys only** (`lucas.*`, onboarding/speech/voice/update) |
| `system.clipboard` | `action=types` + `hasImage` on get/types |

Skipped: EventKit calendar (TCC/entitlement risk); `system.finder.reveal` (covered by `system.path.open` reveal).

## UI

Settings → 在线更新: read-only **内核存储 / 自愈** card (`kernel.store.stats` + latest `selfhealing.events`).

## Hard blocks (not done this batch)

- Volcengine live API keys / cloud TTS production wiring
- Developer ID sign + notarize / Sparkle publish
- Bailongma BSK binary integration

## Soft work after this batch

If build is green and docs match HEAD: treat remaining soft surface as exhausted unless new Japlos reverse tables/ops appear. Cloud TTS beyond scaffold, MCP OAuth live flows, and signed release stay hard.
