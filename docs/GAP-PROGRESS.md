# Lucas gap-close progress

> Updated: 2026-10-30 (Asia/Shanghai) · local clone only · no push/publish/release

## HEAD

See `git rev-parse HEAD` after the latest local commit.

## Store (`lucas.store`)

Namespace version: **v6** (recorded in `persistence_migrations`).

### Tables

**Core / plane (29):** metadata, configurations, sessions, turns, permission_grants, tool_invocations, configuration_history, custom_model_routes, speech_profiles, memories, agent_tasks, alarms, mcp_events, modules, runs, knowledge_documents, subscriptions, context_snapshots, cancellations, capability_delegations, information_revisions, generated_tool_artifacts, information_types, information_heads, information_processors, deliveries, situations, self_healing_events, persistence_migrations.

**Runtime ledgers v6 (28, simplified `id/updated_at/record_json`):** tool_package_publishers, task_plans, scheduled_work, run_attempts, runtime_tools, tool_projects, tool_source_revisions, tool_incidents, tool_packages, tool_package_installations, primary_sessions, memory_embeddings, memory_recognition_jobs, speech_replies, task_privacy, task_desktop_only, mcp_event_cursors, knowledge_chunks, knowledge_terms, knowledge_vectors, knowledge_libraries, knowledge_library_documents, knowledge_import_receipts, knowledge_import_library_receipts, knowledge_library_migrations, knowledge_deletions, knowledge_deletion_aliases, feishu_messages.

**Total tracked by `kernel.store.stats`:** 57 tables.

Japlos reconstructed schema has 53 named tables; Lucas covers them via short names + these ledgers (sessions≈agent_runtime_sessions, etc.).

### Ops (selected)

| Op | Notes |
|---|---|
| `information.*` / `deliveries.*` / `situations.*` / `selfhealing.events.*` | store v5 |
| `kernel.store.stats` | table → row count |
| `runtime.ledger.tables` | whitelist of v6 ledger names |
| `runtime.ledger.list` / `upsert` / `delete` | args: `table`, `id?`, `record?`, `limit?` |

## Self-healing

- `~/Library/Application Support/Lucas/self-healing/` (+ clone home)
- boot + `socket.bind.recover` → JSONL + SQLite

## Tools (safe)

hostname, os.version, app.support.paths, scoped user.defaults, clipboard types/hasImage. EventKit skipped (TCC).

## UI

Settings → 在线更新: store/self-heal card (`kernel.store.stats`).

## Hard blocks

- Volcengine live API keys / production cloud TTS
- Developer ID sign + notarize / Sparkle publish
- Bailongma BSK binary

## Soft surface

Japlos table scaffolds + named/whitelist ops for local parity are in. Remaining work that still needs secrets, signing, or third-party binaries is **hard** only.
