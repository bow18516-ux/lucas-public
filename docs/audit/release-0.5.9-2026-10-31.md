# Lucas 0.5.9 发版记录

- 时间：2026-10-31 13:18–13:20 Asia/Shanghai
- 授权：老板 t2855u「你更新上去。」；发版前追加硬需求：豆包音色男女可选（路径 1：未开跑 publish 前先补齐再发）
- marketing：`0.5.9` · build：`202610311318`
- tip：`daea667`（含 `4c24a05` 豆包 realtime Key + `daea667` 男女音色点选）
- tag：`v0.5.9` → commit `daea667`

## 含
- 豆包 realtime TTS：设置 → 语音自填 Key；选用后走 openspeech realtime dialogue；失败回落系统语音；不代写 Key
- 音色按男女菜单点选：女声 vv / 小何；男声 云舟 / 小天（官方 O 版 `tts.speaker`）
- `DoubaoVoicePresets` 在 JaplosProtocol，App 不依赖 Kernel

## 产物与校验
- App / DMG：Developer ID 签名 + notary Accepted + stapler validate OK
- 生产 appcast：`https://updates.okcue.app/lucas/appcast.xml` 最新项 `0.5.9` / `202610311318`
- `LUCAS_CHECK_DEEP=1 bash scripts/check-updates.sh 0.5.9` → EdDSA verified，`result: OK`
- 部署：rsync 至 `ubuntu@43.132.224.242:/var/www/updates/lucas/` 成功

## 仓库
- 私人：`origin/fix/audit-20261030` @ `daea667`；tag `v0.5.9`
- 公开：`public/fix/audit-20261030`、`public/release/0.5.9` @ `daea667`；tag `v0.5.9`
- 未强推 `main`（Auto-review 拦 main；tip/tag 已在上述分支对齐）

## 未做
- 未在老板笔记本代点「检查更新」
