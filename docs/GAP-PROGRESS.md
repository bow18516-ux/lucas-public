# Lucas gap-close progress

> Updated: 2026-10-30 (Asia/Shanghai) · local clone only · no push/publish/release

## HEAD

See `git rev-parse HEAD` (latest local commits: store v5 → v6 → data-dir/Team-ID/uptime).

## Store (`lucas.store`)

Namespace version: **v7** (channels).

- Core/plane tables: 29 (incl. persistence_migrations)
- Runtime ledgers (simplified): 28
- **`kernel.store.stats` table count: 58** (+ wechat_connections)

Ops include information/deliveries/situations/selfhealing + `runtime.ledger.list|upsert|delete|tables`.

## Self-healing + support tree

On `lucasd` start:
- Ensure dirs: self-healing, credentials, Caches, Caches/wechat, DownloadStaging, feishu, feishu/credentials, wechat, wechat/credentials, Prompts, Injection, BuiltinSkills, bin, Logs/Lucas (+ empty feishu auth.sqlite)
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


## Channels (微信 / 飞书) — boss mandate 2026-10-30

**Status: scaffold landed in kernel + settings; live auth is hard-blocked.**

### Ops (KernelOperation + agent tools)
- WeChat: `runtime.wechat.connect|disconnect|status|verify|send_text|send_file`
- WeChat mgmt: `wechat.login.start|status|verify|events`, `wechat.connection.list|manage|read|remove`, `wechat.connections`
- Feishu: `runtime.feishu.connect|disconnect|status|session|send_text`
- Feishu mgmt: `feishu.configuration.open|cancel`, `feishu.connection.configure|disconnect|status|read|manage`
- Stub: `runtime.knowledge.import_feishu`

### Store / dirs
- Store **v7**: `wechat_connections` table
- `feishu_messages` ledger (existing)
- App Support: `wechat/credentials`, `Caches/wechat`, `feishu/credentials/auth.sqlite` (`auth_profile_store`)

### Secrets (empty OK; never logged)
- `feishu.app_id`, `feishu.app_secret`, `feishu.verification_token`, `feishu.tenant_access_token`
- `wechat.ilink.base_url` (optional override; default `https://ilinkai.weixin.qq.com`)

### Settings UI
- New sidebar **通道**: WeChat card (connect QR / disconnect / status) + Feishu card (app id/secret fields → SecretStore + connect)

### Hard blocks (boss)
1. **Feishu**: paste real `app_id` + `app_secret` (optional verification_token) in 设置→通道, then Connect.
2. **WeChat**: interactive ClawBot QR scan against `ilinkai.weixin.qq.com` (`ilink/bot/get_bot_qrcode` etc.). Without a successful scan, status stays disconnected / awaiting_scan — **never fabricates connected**.
3. Do not claim live channel delivery until verified with real auth.

### iLink paths (SoT strings)
`ilink/bot/get_bot_qrcode`, `get_qrcode_status`, `getupdates`, `getuploadurl`, `msg/notifystart|notifystop`, `sendmessage`


## Soft

Japlos schema scaffolds, ledger ops, prompts/scenes/skills pack hooks, support-tree, optional Team-ID gate, store stats UI — done. Remaining product depth (full UI projections, live OAuth, signed helper packaging) needs assets/secrets/signing → treated as hard or out-of-scope soft exhaustion.
