# Lucas gap-close progress

> Updated: 2026-10-30 (Asia/Shanghai) · local clone only · no push/publish/release

## HEAD

See `git rev-parse HEAD` (latest local commits: store v5 → v6 → data-dir/Team-ID/uptime).

## Store (`lucas.store`)

Namespace version: **v6**.

- Core/plane tables: 29 (incl. persistence_migrations)
- Runtime ledgers (simplified): 28
- **`kernel.store.stats` table count: 57**

Ops include information/deliveries/situations/selfhealing + `runtime.ledger.list|upsert|delete|tables`.

## Self-healing + support tree

On `lucasd` start:
- Ensure dirs: self-healing, credentials, Caches, DownloadStaging, feishu, Prompts, Injection, BuiltinSkills, bin, Logs/Lucas
- Seed prompts/scenes/skills when empty
- Append self-heal boot (+ socket.bind.recover)

## Peer auth

- UID peer check (always)
- Optional Team ID: env `LUCAS_REQUIRE_TEAM_ID=TeamID[,adhoc]` (default **off**)

## Tools (safe extras)

hostname, os.version, app.support.paths (full tree), uptime, scoped user.defaults, clipboard types/hasImage.

## Hard blocks only

- Volcengine live API keys / production cloud TTS
- Developer ID sign + notarize / Sparkle publish
- Bailongma BSK binary (`bailongma-bsk-mcp`)

## Soft

Japlos schema scaffolds, ledger ops, prompts/scenes/skills pack hooks, support-tree, optional Team-ID gate, store stats UI — done. Remaining product depth (full UI projections, live OAuth, signed helper packaging) needs assets/secrets/signing → treated as hard or out-of-scope soft exhaustion.
