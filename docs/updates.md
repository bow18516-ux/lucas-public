# 在线更新速查

> 完整架构、签名、公证与服务器配置见 **[PROJECT.md](PROJECT.md)** 第 13、14、15 章。
> 本文只保留日常发版最常用的命令与线上地址。

## 线上地址

| 用途 | URL |
|---|---|
| appcast | `https://updates.okcue.app/lucas/appcast.xml` |
| 最新 DMG | `https://updates.okcue.app/lucas/Lucas-0.5.4.dmg` |
| 最新 ZIP | `https://updates.okcue.app/lucas/Lucas-0.5.4.zip` |
| 更新说明 | `https://updates.okcue.app/lucas/Lucas-0.5.4.html` |

服务器：`ubuntu@43.132.224.242`，目录 `/var/www/updates/lucas/`，nginx + Let's Encrypt。

## 发一个新版本

```bash
cd ~/Desktop/japlosv2/clone

# 1) 写更新说明（可选；不写会自动从 git 提交生成）
cat > updates/Lucas-0.5.4.html <<'EOF'
<ul>
<li>修复……</li>
<li>新增……</li>
</ul>
EOF

# 2) 一条命令：构建 → 签名 → 公证 → staple → zip/dmg → appcast → 上传
./scripts/publish.sh 0.5.4
```

脚本会读取 `Config/release.env`（已 gitignore），其中包含：

- `LUCAS_SIGN_IDENTITY`：Developer ID Application
- `LUCAS_NOTARY_PROFILE` / `LUCAS_NOTARY_KEYCHAIN`：公证凭据
- `LUCAS_FEED_URL` / `LUCAS_DOWNLOAD_PREFIX`
- `LUCAS_DEPLOY_TARGET` / `LUCAS_SSH_KEY`：rsync 上传

## 监控

```bash
./scripts/check-updates.sh 0.5.4
./scripts/install-monitor.sh install   # 每 6 小时检查，日志在 ~/Library/Logs/Lucas
```

## 发布后自检

```bash
./scripts/check-updates.sh 0.5.4
LUCAS_CHECK_DEEP=1 LUCAS_CHECK_RESOLVE=43.132.224.242 ./scripts/check-updates.sh 0.5.4
curl -sI https://updates.okcue.app/lucas/appcast.xml | head -3
curl -s https://updates.okcue.app/lucas/appcast.xml | head -20
shasum -a 256 updates/Lucas-0.5.4.zip
codesign -dv --verbose=4 build/Lucas.app
spctl -a -t exec -vv build/Lucas.app
```

## 常见问题

| 现象 | 处理 |
|---|---|
| `No Keychain password item found for profile` | 检查 `LUCAS_NOTARY_KEYCHAIN` 与 `--keychain` 参数；确认钥匙串已解锁 |
| `Cannot store both ... credentials` | API Key 参数不要混用 `--team-id`；App 专用密码不要带 `--key-id` |
| certbot HTTP-01 超时 | 云防火墙放行 80/443，DNS 设为灰云 |
| 上传后仍是旧 feed | 确认 `updates/appcast.xml` 已重新生成并被 rsync |
| 生成 appcast 报 cache 权限 | 在普通终端运行，不要用受限沙箱 |

更完整的排错见 [PROJECT.md](PROJECT.md) 第 13.7、14.6 节。
