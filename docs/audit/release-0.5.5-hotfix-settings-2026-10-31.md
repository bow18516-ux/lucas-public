# Lucas 0.5.5 hotfix（设置页假版本）发版记录

- 时间：2026-10-31 09:45–09:50 Asia/Shanghai
- 授权：老板 t2831u「发」
- marketing：`0.5.5` · build：`202610310945`（替换生产 `202610310400`）
- 修复：`b3f0928` fix(updates): stop fake「最新版本 0.5.3」on settings pane
- 本地 HEAD / 双仓 tip：见本记录末（推送后填写）
- tag：`v0.5.5` → 新 tip（同营销版本 hotfix，移动 tag）

## 产物与校验
- App / DMG：Developer ID 签名 + notary Accepted + stapler validate OK
- 生产 appcast：`https://updates.okcue.app/lucas/appcast.xml` 最新项 `0.5.5` / `202610310945`
- `LUCAS_CHECK_DEEP=1 bash scripts/check-updates.sh 0.5.5` → EdDSA verified，`result: OK`
- 部署：首轮 rsync 失败（known_hosts 路径含空格未引号 / 代理）；改 `ssh -4` + `~/.config/lucas-release/known_hosts` 后成功。未回滚。
- 旧包备份：`updates/_pre-hotfix-backup/Lucas-0.5.5-{zip,dmg}`（不进 feed）

## 说明
- 同 marketing 0.5.5 覆盖 `Lucas-0.5.5.zip`；Sparkle 以 build 比较，`202610310400` 用户会收到升到 `202610310945`
- appcast 中 delta 条目与既往发版一样未实际上传（404），客户端回退全量 zip（已验签）
- 未在老板笔记本代点「检查更新」

## 仓库（推送后填）
- 私人：https://github.com/bow18516-ux/lucas-private
- 公开：https://github.com/bow18516-ux/lucas-public
