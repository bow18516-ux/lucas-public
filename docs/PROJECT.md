# Lucas Agent 项目文档

> 适用版本：**0.5.4 (build 202610301026)** · 最后更新：2026-10-30
> 读者：接手开发、构建、发布或运维的工程师。
> 目标：读完这一篇，能独立完成「改代码 → 构建 → 公证 → 发布 → 用户更新」全流程。

---

## 目录

1. [项目概览](#1-项目概览)
2. [快速开始](#2-快速开始)
3. [技术栈](#3-技术栈)
4. [仓库结构](#4-仓库结构)
5. [整体架构](#5-整体架构)
6. [协议层](#6-协议层)
7. [内核层](#7-内核层)
8. [Runtime 层](#8-runtime-层)
9. [App 层](#9-app-层)
10. [数据与存储](#10-数据与存储)
11. [安全与权限](#11-安全与权限)
12. [构建与运行](#12-构建与运行)
13. [在线更新（Sparkle）](#13-在线更新sparkle)
14. [服务器与部署](#14-服务器与部署)
15. [发布流程与检查清单](#15-发布流程与检查清单)
16. [测试与验证](#16-测试与验证)
17. [开发指南：新增能力](#17-开发指南新增能力)
18. [已知限制与技术债](#18-已知限制与技术债)
19. [交接清单与运维手册](#19-交接清单与运维手册)
20. [附录](#20-附录)

---

## 1. 项目概览

**Lucas Agent** 是一个 macOS 原生桌面 Agent：用户用自然语言下达任务，它可以对话、执行 Shell、读写文件、截屏、控制音乐、调用 MCP 工具，并在高风险操作前请求确认。

它是对商业产品 **Japlos v2 (1.1.35)** 的行为等价复刻：协议、权限模型、工具集与界面结构按逆向结论重新实现，**不复用原版二进制、资源或提示词文本**。逆向报告在仓库上层的 `../REPORT.md`。

| 项 | 值 |
|---|---|
| 产品名 | Lucas Agent |
| Bundle ID | `com.lucas.app` |
| 当前版本 | `0.5.4` |
| Bundle 版本 | `202610301026`（时间戳） |
| 最低系统 | macOS 13.0 |
| 架构 | arm64 |
| 更新源 | `https://updates.okcue.app/lucas/appcast.xml` |
| 下载页文件 | `https://updates.okcue.app/lucas/Lucas-0.5.4.dmg` |
| 代码位置 | `~/Desktop/japlosv2/clone`（SwiftPM 包） |
| 原版参考 | `../REPORT.md`、`../extracted/` |

### 1.1 产品边界

- **不做** App Store 上架；走 Developer ID + 公证 + 自建 appcast 分发。
- **不做** 账号体系；本地单用户 `local-user`。
- **模型**由用户自带：任何 OpenAI 兼容接口（DeepSeek / MiMo / Pollinations / 自定义）。
- **语音**使用 Apple 系统 Speech / AVSpeechSynthesizer（没有接火山、MiMo 的云端语音）。
- **数据**全部在本机 `~/Library/Application Support/Lucas`。

### 1.2 一分钟理解架构

两个进程：

- `Lucas`（UI）：SwiftUI + AppKit，负责界面、设置、引导、语音、更新提示。
- `lucasd`（内核）：常驻进程，负责权限、SQLite、工具、MCP、模型调用与 ReAct 循环。

两者通过 **Unix domain socket** 通信，帧格式是 **4 字节大端长度 + JSON**。UI 永远不直接执行工具，所有能力都经过内核的能力校验。

---

## 2. 快速开始

### 2.1 环境

| 依赖 | 版本 |
|---|---|
| macOS | 13+（开发机为 macOS 26.6） |
| Xcode / Swift | Xcode 26，Swift 6.4 |
| SwiftPM | tools 5.9 |
| 第三方库 | 仅 Sparkle 2.10.1（SPM 自动拉取） |

### 2.2 构建与运行（开发）

```bash
cd ~/Desktop/japlosv2/clone

# 编译
swift build --disable-sandbox

# 打包成 .app（ad-hoc 签名，适合本机开发）
./scripts/build-app.sh release
open build/Lucas.app
```

> `--disable-sandbox` 是必须的：SwiftPM 的 manifest 沙箱在本机环境会报 `sandbox_apply: Operation not permitted`。

### 2.3 开发模式：隔离数据

默认数据目录是 `~/Library/Application Support/Lucas`。开发时用环境变量隔离，避免污染真实数据：

```bash
LUCAS_CLONE_HOME="$PWD/run/dev" ./build/Lucas.app/Contents/MacOS/Lucas
```

常用调试变量见 [16.4](#164-调试环境变量)。

### 2.4 冒烟测试

```bash
./scripts/smoke_test.sh
```

16 个步骤，覆盖握手、权限、会话、流式、取消、审批、工具、MCP、模型目录等。要求 16/16 通过。

### 2.5 发布

```bash
./scripts/publish.sh 0.5.3
```

详见 [第 15 章](#15-发布流程与检查清单)。

---

## 3. 技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| 语言 | Swift 6.4（语言模式 5） | 无 Objective-C 混编 |
| UI | SwiftUI + AppKit | SwiftUI 负责内容，AppKit 管理 `NSWindow` 生命周期 |
| 进程 | 两个可执行文件 | `Lucas`（UI）与 `lucasd`（内核） |
| IPC | Unix domain socket | `SOCK_STREAM`，4 字节大端长度 + JSON，单帧上限 16 MiB |
| 持久化 | SQLite3 | 系统 `libsqlite3`，WAL 模式 |
| 模型 | OpenAI 兼容 HTTP | `/chat/completions` SSE 流式、`/models` |
| MCP | stdio JSON-RPC / Streamable HTTP | 换行分隔 JSON、`Mcp-Session-Id`、SSE |
| 语音识别 | `Speech` + `AVAudioEngine` | 系统离线/在线识别 |
| 语音合成 | `AVSpeechSynthesizer` | 系统音色 |
| 音频设备 | CoreAudio | 枚举输入设备并切换 |
| 更新 | Sparkle 2.10.1 | EdDSA 签名 appcast，原生更新弹窗与进度条 |
| 签名 | Developer ID + Hardened Runtime | `codesign` + entitlements |
| 公证 | `notarytool` + `stapler` | App Store Connect API Key |
| 分发 | ZIP + DMG + nginx | Sparkle 用 ZIP，人用 DMG |
| 服务器 | Ubuntu 26.04 + nginx 1.28.3 + certbot 4.0.0 | Let's Encrypt HTTPS |
| 测试脚本 | Bash + Python | 无 XCTest UI 测试；协议层有单元测试 |

依赖只有 Sparkle 一个，其余全部系统框架。

---

## 4. 仓库结构

```
clone/
├── Package.swift                 # SwiftPM 清单（5 个 target）
├── Sources/
│   ├── JaplosProtocol/           # 协议、帧、JSON、权限、工具模型（无 UI/网络）
│   │   ├── KernelProtocol.swift
│   │   ├── Framing.swift
│   │   ├── JSONValue.swift
│   │   ├── Policy.swift
│   │   └── Tools.swift
│   ├── JaplosKernel/             # 内核：socket、存储、权限、工具、MCP
│   │   ├── UnixSocketServer.swift
│   │   ├── KernelCore.swift
│   │   ├── KernelStore.swift
│   │   ├── SQLiteDatabase.swift
│   │   ├── PolicyEngine.swift
│   │   ├── ToolRegistry.swift
│   │   ├── BuiltinTools.swift
│   │   ├── ExtendedTools.swift
│   │   ├── SystemInfoTools.swift
│   │   ├── DocumentTools.swift
│   │   └── MCPClient.swift
│   ├── JaplosRuntime/            # 对话运行时：ReAct、模型、提示词、场景
│   │   ├── ChatService.swift
│   │   ├── ModelClient.swift
│   │   ├── PromptLibrary.swift
│   │   └── SceneRouter.swift
│   ├── japlosd/main.swift        # 内核入口（可执行文件名 lucasd）
│   └── JaplosApp/                # UI 层
│       ├── JaplosApp.swift       # AppDelegate、菜单、窗口
│       ├── CoreSurface.swift     # 三栏主界面、Theme、DashboardLayout
│       ├── SettingsView.swift    # 设置页 + 设计 token
│       ├── OnboardingView.swift  # 首次引导
│       ├── AppModel.swift        # 全局状态与业务编排
│       ├── KernelClient.swift    # socket 客户端 + 守护进程拉起
│       ├── UpdateController.swift# UpdateService（Sparkle 封装）
│       ├── SpeechInput.swift
│       ├── SpeechOutput.swift
│       ├── AudioDevices.swift
│       ├── MarkdownView.swift
│       └── AppLog.swift
├── Tests/JaplosProtocolTests/    # 协议/策略单元测试
├── Assets/                       # 图标源文件与 AppIcon.icns
├── Config/
│   ├── Lucas.entitlements        # 签名权限
│   ├── sparkle_public_key.txt    # EdDSA 公钥（可提交）
│   ├── release.env.example       # 发布配置模板（可提交）
│   └── release.env               # 真实发布配置（**不提交**）
├── scripts/                      # 构建、测试、发布、MCP 测试服务
├── docs/                         # 截图、更新文档、本篇
├── build/                        # 构建产物（不提交）
├── updates/                      # 发布产物：zip/dmg/appcast（不提交）
├── run/                          # 开发数据目录（不提交）
└── .secrets/                     # 私钥与部署密钥（**绝不提交**）
```

### 4.1 关键文件速查

| 想知道什么 | 看哪里 |
|---|---|
| 有哪些内核操作 | `Sources/JaplosProtocol/KernelProtocol.swift` |
| 操作需要什么能力 | `Sources/JaplosKernel/KernelCore.swift` + `Policy.swift` |
| 数据库表结构 | `Sources/JaplosKernel/KernelStore.swift` |
| 工具清单/风险级别 | `Sources/JaplosKernel/*Tools.swift` |
| 对话怎么循环 | `Sources/JaplosRuntime/ChatService.swift` |
| 模型请求格式 | `Sources/JaplosRuntime/ModelClient.swift` |
| 提示词分层 | `Sources/JaplosRuntime/PromptLibrary.swift` |
| 主界面布局 | `Sources/JaplosApp/CoreSurface.swift` |
| 设置页结构 | `Sources/JaplosApp/SettingsView.swift` |
| 更新实现 | `Sources/JaplosApp/UpdateController.swift` |
| 发布流程 | `scripts/release.sh` |
| 服务器配置 | 本文第 14 章 |

---

## 5. 整体架构

### 5.1 进程与职责

```
┌─────────────────────────────────────┐
│ Lucas（UI 进程）                     │
│                                     │
│ AppDelegate / NSWindow              │
│ AppModel（状态与编排）               │
│ CoreSurface / Settings / Onboarding │
│ SpeechInput / SpeechOutput          │
│ UpdateService（Sparkle）             │
│ KernelClient ───────────────┐       │
└─────────────────────────────┼───────┘
                              │ Unix socket
                              │ 4B BE length + JSON
┌─────────────────────────────┼───────┐
│ lucasd（内核进程）           ▼       │
│                                     │
│ UnixSocketServer（帧、流、审批）     │
│ KernelCore（路由 + 能力校验）        │
│ PolicyEngine（授权）                 │
│ KernelStore ↔ SQLite                │
│ ToolRegistry → 15 个系统工具         │
│ MCPClient（stdio / HTTP）            │
│ ChatService（ReAct 循环）            │
│ ModelClient（OpenAI / SSE）          │
│ PromptLibrary / SceneRouter          │
└─────────────────────────────────────┘
```

### 5.2 一次「发消息」的完整链路

```
用户输入
  → CoreSurface 组装 draft
  → AppModel.send()
  → KernelClient.chat(sessionID, text)
  → 写 socket：{operation:"chat.send", arguments:{...}}
  → UnixSocketServer 读取帧
  → KernelCore 校验 chat.manage@1
  → ChatService.executeChat()
      ├─ 读历史（KernelStore）
      ├─ 组装系统提示词（identity/behavior/execution/tool-policy/scene）
      ├─ 合并 MCP 动态工具
      ├─ ModelClient.stream() ──HTTPS/SSE──> 模型服务
      ├─ 收到 tool_calls → ToolRegistry.invoke() → 工具执行
      ├─ 高风险工具 → 发 approval 帧 → UI 弹窗 → tool.approval 帧回来
      └─ 最多 8 轮，或直到模型给出最终回答
  → 流式写回：delta（文本）/ tool（工具回执）/ approval / done
  → AppModel 增量更新消息气泡
  → 会话与 turn 落库
```

### 5.3 为什么是双进程

- 权限与工具执行和 UI 解耦：UI 崩溃不影响内核会话；未来可以把内核做成独立服务。
- 能力边界清晰：所有操作经过 `KernelCore` 的统一校验，而不是散落在 UI 里。
- 与原版 Japlos 的架构对齐，便于按逆向结论验证行为。

### 5.4 流式帧

内核在 `chat.send` 上不是一次性返回，而是写多帧：

| 帧 `type` | 含义 | UI 行为 |
|---|---|---|
| `delta` | 文本增量 | 追加到当前助手消息 |
| `tool` | 工具调用开始/结束 | 插入工具 chip，展示名称与结果摘要 |
| `approval` | 需要用户确认 | 弹出允许/拒绝对话框 |
| `done` | 完成 | 结束流，刷新会话列表 |
| `error` | 失败 | 展示错误气泡 |

实现：`UnixSocketServer` 的流式分支 + `KernelClient.ChatStream`。

---

## 6. 协议层

### 6.1 帧格式

```
┌──────────────┬──────────────────────────┐
│ 4 字节大端长度 │ JSON body（UTF-8）        │
└──────────────┴──────────────────────────┘
```

- 单帧上限 **16 MiB**。
- 连接为长连接，一个连接上可顺序处理多个请求。
- 流式请求在同一个连接上持续写多帧，直到 `done`/`error`。

实现：`Sources/JaplosProtocol/Framing.swift`。

### 6.2 KernelRequest

```swift
struct KernelRequest {
    var protocolVersion: String   // 当前 "1.0"
    var id: String                // UUID
    var principal: String         // "local-user"
    var operation: KernelOperation// 例 "chat.send"
    var resource: String?         // 可选资源，如工具名
    var arguments: JSONValue
    var reason: String?
    var deadline: Date?
    var idempotencyKey: String?
    var correlationID: String?
    var cancellationID: String?
}
```

`KernelOperation` 是开放字符串，新增操作不需要改客户端枚举。

### 6.3 操作清单

| 分组 | 操作 | 能力 |
|---|---|---|
| 生命周期 | `kernel.status` / `kernel.ping` / `kernel.shutdown` | `kernel.root@1` |
| 权限 | `policy.grants.list` / `policy.evaluate` | `kernel.root@1` |
| 配置 | `configuration.list` / `configuration.set` | `kernel.root@1` |
| 会话 | `chat.session.create` / `chat.sessions.list` / `chat.session.rename` / `chat.turn.append` / `chat.send` | `chat.manage@1` |
| 历史 | `chat.history` | `chat.read@1` |
| 工具 | `tool.list` / `tool.invoke` / `tool.approval` | `tool.read@1` / `tool.invoke@1` / `chat.manage@1` |
| MCP | `mcp.status` / `mcp.refresh` | `tool.read@1` / `tool.manage@1` |
| 模型 | `model.test` / `model.catalog` | `model.invoke@1` |

### 6.4 能力（Capability）

`Sources/JaplosProtocol/Policy.swift` 定义 20 个：

```
kernel.root@1          chat.read@1            chat.manage@1
model.invoke@1         tool.read@1            tool.manage@1
tool.invoke@1          policy.read@1          policy.manage@1
filesystem.read@1      filesystem.write@1     process.execute@1
screen.capture@1       clipboard.read@1       clipboard.write@1
applications.control@1 music.control@1        audio.control@1
system.read@1          notification.send@1
```

- 本地用户 `local-user` 在首次启动时被授予 `kernel.root@1`。
- 每次请求由 `CapabilityRouting.capability(for:)` 映射到能力，再交给 `PolicyEngine.evaluate`。
- 当前路由实际使用的是 `kernel.root@1`、`chat.manage@1`、`chat.read@1`、`tool.read/invoke/manage@1`、`model.invoke@1`；其余能力预留给工具执行与未来扩展（工具声明里会直接引用，如 `process.execute@1`）。
- 授权记录在 SQLite `permission_grants`，支持过期与撤销。

### 6.5 错误约定

失败返回 `KernelResponse{ok:false,error:{code,message}}`，常见 code：

| code | 含义 |
|---|---|
| `permission_denied` | 能力不足 |
| `invalid_argument` | 参数缺失/非法 |
| `model_not_configured` | 未配置模型，UI 会弹引导/设置 |
| `tool_failed` | 工具执行失败 |
| `cancelled` | 用户取消 |
| `internal_error` | 未分类错误 |

---

## 7. 内核层

### 7.1 UnixSocketServer

- 默认 socket：`~/Library/Application Support/Lucas/kernel.sock`（权限 0600）。
- 启动时清理陈旧 socket 文件。
- 每个连接一个读循环；请求按序处理。
- 流式请求通过 `emit` 回调写 `delta/tool/approval/done`。
- **ApprovalBroker**：内核发出 `approval` 帧后，在同一连接等待 `tool.approval` 请求，超时/拒绝均按拒绝处理。

### 7.2 KernelCore

职责：

1. 解析请求，映射能力（`CapabilityRouting`）。
2. 调 `PolicyEngine.evaluate`。
3. 路由到 store / ChatService / ToolRegistry / MCPClient。
4. 统一错误包装与日志。

新增操作时要同时更新：`KernelOperation` 常量、`CapabilityRouting`、`KernelCore.handle` 分支、必要时 `Policy`。

### 7.3 PolicyEngine

- 规则：`principal + capability + resource pattern`，支持通配符。
- `permission_grants` 表字段：`expires_at`、`revoked_at`、`constraints_json`。
- 引导授权：首次启动把 `kernel.root@1` 授予 `local-user`。
- 决策结果包含 `allowed`、`reason`、`requiredCapability`，拒绝会原样返回给 UI。

### 7.4 KernelStore 与 SQLite

数据库：`~/Library/Application Support/Lucas/kernel.sqlite3`（WAL）。

| 表 | 用途 | 关键字段 |
|---|---|---|
| `metadata` | 迁移版本等 | `key`, `value` |
| `configurations` | 配置（含模型连接） | `path`, `scope`, `value_json`, `revision` |
| `sessions` | 会话 | `id`, `title`, `created_at`, `updated_at` |
| `turns` | 消息/工具轮次 | `session_id`, `role`, `text`, `tool_calls_json`, `tool_call_id`, `tool_name` |
| `permission_grants` | 能力授权 | `principal`, `capability`, `resource_pattern`, `expires_at`, `revoked_at` |
| `tool_invocations` | 工具审计 | `tool`, `ok`, `duration_ms`, `arguments_json`, `output_json` |

模型连接存在 `configurations` 的：

```
path = agents.default.model.connection
value = { baseURL, model, apiKey, temperature }
```

> **API Key 不再存 SQLite**：`configurations.value_json` 里的 `apiKey` 始终为空，真实密钥由 `SecretStore` 管理：
> - 签名构建：macOS **Keychain**（service `com.lucas.app.secrets`）
> - 未签名开发构建，或 Keychain 不可用时：`<home>/secrets.json`（权限 0600），并在 `lucasd.log` 记录降级
> - 旧数据库里的明文 `apiKey` 会在内核启动时自动迁移，用户无需重新填写

### 7.5 ToolRegistry

- 每个工具声明：`name`、`title`、`summary`、`inputSchema`、`capability`、`risk`。
- `risk` 决定是否需要审批：`high` 一定审批；`medium` 按配置；`low` 直接执行。
- 调用前再次做能力校验，成功后写 `tool_invocations`。

### 7.6 内置工具（15 个）

| 工具 | 能力 | 风险 | 说明 |
|---|---|---|---|
| `system.time` | root | low | 当前时间 |
| `system.command.shell.execute` | process.execute | **high** | `/bin/zsh -lc` 执行命令 |
| `system.application` | applications.control | medium | 打开/激活/退出应用 |
| `system.filesystem` | filesystem.write | medium | 读/写/列目录/删除 |
| `system.screen.capture` | screen.capture | medium | `screencapture` 截屏 |
| `system.clipboard` | clipboard.write | medium | 读写剪贴板 |
| `system.music` | music.control | low | Apple Music 播放控制 |
| `system.audio` | audio.control | low | 音量/静音 |
| `system.url.open` | applications.control | low | 打开 URL |
| `system.window.list` | system.read | low | 窗口列表（CoreGraphics） |
| `system.process.list` | system.read | low | 进程列表（libproc） |
| `system.network.info` | system.read | low | 网络接口/地址 |
| `system.document.pdf.create` | filesystem.write | low | 文本转 PDF |
| `system.download.fetch` | filesystem.write | medium | 下载文件到本地 |
| `system.notification` | notification.send | low | 系统通知 |

### 7.7 MCPClient

支持两种传输：

- **stdio**：启动子进程，按行 JSON-RPC；握手 `initialize` → `tools/list` → `tools/call`。
- **Streamable HTTP**：POST JSON，响应可能是 JSON 或 SSE；保存 `Mcp-Session-Id` 并在后续请求带上。

配置存在 `configurations` 的 `mcp.servers`（见设置页）。工具动态并入 `tool.list`，`capability` 使用 `tool.invoke@1`，风险默认 `medium`。

---

## 8. Runtime 层

### 8.1 ChatService（ReAct 循环）

输入：`chat.send` 参数（sessionID、text、可选 model）。

流程：

1. 读取会话历史（`chat.history`）。
2. 按 **48k 字符预算**从最近回合截断，保持 tool call 与 result 成对。
3. 组装系统提示词（见 8.3）。
4. 合并内置工具 + MCP 工具为 OpenAI `tools` 数组。
5. 调 `ModelClient.stream`。
6. 若返回 `tool_calls`：
   - 逐个执行（必要时审批），把工具结果作为 `role=tool` 消息追加。
   - 回到第 5 步，最多 **8 轮**。
7. 若达到轮次上限，追加一条兜底说明。
8. 把最终回答与工具记录落库，写 `done`。

取消：UI 关闭 socket 或发送取消，内核 `Task` 取消，模型/工具不再继续。

### 8.2 ModelClient

- 请求：`POST {baseURL}/chat/completions`，`stream: true`。
- 解析 SSE：`data: {...}`，累积 `choices[0].delta.content` 与 `tool_calls`。
- 模型目录：`GET {baseURL}/models`。
- 兼容性处理：
  - `tool` 消息**不带** `name` 字段（部分供应商会拒绝带点的工具名）。
  - 错误响应解析为可读 message。
- 超时与取消通过 `URLSession` task 控制。

### 8.3 PromptLibrary（分层提示词）

系统提示由多个片段按顺序拼接：

| 片段 | 内容 |
|---|---|
| identity | 「你是 Lucas Agent，一个运行在用户 Mac 上的桌面 Agent」 |
| behavior | 回答风格、语言、澄清策略 |
| execution | 工具使用原则、风险操作确认、失败处理 |
| tool-policy | 工具清单与调用格式 |
| scene | 场景注入（音乐、应用、截屏、文件、命令、时间、剪贴板） |

可在 `~/Library/Application Support/Lucas/Prompts/<id>.md` 覆盖同名片段，便于不发版调提示词。

### 8.4 SceneRouter

正则匹配用户输入，决定注入哪个场景片段：

- 音乐 / 应用 / 截屏 / 文件 / 命令 / 时间 / 剪贴板
- 命中多个时按优先级取第一个。

---

## 9. App 层

### 9.1 启动流程

```
main() → NSApplication + AppDelegate
  → applicationDidFinishLaunching
      ├─ 创建 NSWindow（AppKit，不用 WindowGroup）
      ├─ 固定初始 1400×875，居中，禁用状态恢复
      ├─ 构建主菜单（App / 编辑 / 对话 / 窗口）
      ├─ 创建 UpdateService（仅真实 .app 且 Info.plist 有 SUFeedURL）
      ├─ 启动 SwiftUI 根视图 CoreSurfaceView
      └─ 1 秒可见性兜底（防止窗口不显示）
  → AppModel.bootstrap()（异步）
      ├─ 迁移旧数据（JaplosClone → Lucas）
      ├─ 定位/拉起 lucasd
      ├─ 连接 socket、握手
      ├─ 读配置、判断是否显示引导
      ├─ 读取工具、会话、历史
      └─ 首次无配置 → 显示 OnboardingView
```

窗口细节：

- `isRestorable = false`，`setFrameAutosaveName("")`，避免系统恢复旧尺寸。
- 初始内容尺寸固定 **1400×875**（16:10），启动后异步再校正一次。
- 最小尺寸 **1120×700**；用户可自由拉伸。
- 关闭窗口不退出进程；Dock 点击重新显示。

### 9.2 AppModel（全局状态）

主要 `@Published`：

- `settings: ModelConnection`（baseURL/model/apiKey/temperature）
- `hasStoredConnection`、`storedAPIKey`
- `availableModels`
- `sessions`、`currentSessionID`、`messages`
- `isSending`、`pendingApproval`
- `settingsPresented`、`onboardingPresented`
- `connected`、`statusText`
- `voice: SpeechOutput`

关键方法：

| 方法 | 作用 |
|---|---|
| `bootstrap()` | 拉起内核、加载配置/工具/会话 |
| `send()` | 发送消息，消费流式帧 |
| `stop()` | 取消生成 |
| `saveSettings()` | 写 `agents.default.model.connection` |
| `testModel()` | 调 `model.test` 做真实连通性测试 |
| `refreshModels()` | 调 `model.catalog` |
| `switchModel(_:)` | 顶栏切换模型并持久化 |
| `resolveApproval(_:)` | 允许/拒绝高风险工具 |
| `presentOnboardingIfNeeded()` | 首次引导判定 |

### 9.3 KernelClient / DaemonController

- 计算 `home`：`LUCAS_CLONE_HOME` 覆盖，否则 `~/Library/Application Support/Lucas`。
- socket 路径：`<home>/kernel.sock`。
- `ensureRunning`：
  1. 尝试连接 socket；
  2. 失败则按顺序找 `lucasd`：bundle 内 `Contents/MacOS/lucasd`、`.build/debug/lucasd`、`.build/release/lucasd`；
  3. `Process` 启动并重定向日志到 `~/Library/Logs/Lucas/lucasd.log`；
  4. 轮询连接，超时报错。
- 请求封装：4 字节长度 + JSON；响应按帧读取；流式返回 `ChatStream`。

### 9.4 界面结构

三栏（`CoreSurface.swift`）：

```
顶栏（58pt，含 LUCAS 字标、v1、齿轮、模型胶囊、连接状态、刷新）
├─ 左栏 284pt：大语言模型卡 / 记忆卡 / 日历
├─ 中栏 自适应：粒子球 + 对话/空状态 + 输入条
└─ 右栏 284pt：资料 / 任务
```

**全局布局常量** `DashboardLayout`：

| 常量 | 值 |
|---|---|
| `outerMargin` | 24 |
| `columnWidth` | 284 |
| `gutter` | 24 |
| `conversationWidth` | 680 |
| `topBarTopPadding` | 22 |
| `topBarHeight` | 58 |
| `contentTopPadding` | 8 |

**设置页设计 token** `SettingsMetrics`（`SettingsView.swift`）：

| Token | 值 | 用途 |
|---|---|---|
| pageTitleSize | 26 | 页面标题 |
| pageSubtitleSize | 13 | 副标题 |
| cardTitleSize | 16 | 卡片标题 |
| cardSubtitleSize | 12 | 卡片说明 |
| labelSize | 13 | 字段名 |
| bodySize | 13 | 正文/输入 |
| captionSize | 11 | 辅助文字 |
| microSize | 10 | 小徽标 |
| cardPadding | 22 | 卡片内边距 |
| cardSpacing | 18 | 卡片间距 |
| rowSpacing | 14 | 行距 |
| labelWidth | 104 | 字段名列宽 |
| pagePadding | 10 | 内容左右留白 |

**主题** `Theme`：背景 `#090A0B`、面板 `#121215`、强调琥珀 `#D1A661`、成功绿、次级灰。

### 9.5 设置页

`SettingsSection`：大模型设置 / 语音设置 / MCP 服务 / Skill 列表 / 工具列表 / 在线更新。

- 左侧固定 268pt 导航，右侧内容列最大 900pt。
- 四个设置页共用 `SettingsMetrics`，不要新增裸字号。
- 在线更新页：当前版本卡 + 最新版本卡 + 自动更新开关；有更新时侧栏和齿轮显示圆点。
- MCP 页支持增删 stdio/HTTP 服务，保存后刷新工具。
- 工具页列出 15 个内置工具与动态 MCP 工具。

### 9.6 首次引导

`OnboardingView` 三步：

1. 欢迎（功能简介）
2. 连接模型（服务商预设、Base URL、Key、模型；自动刷新模型列表；真实测试连接）
3. 完成（展示服务/模型/地址）

判定：`!hasStoredConnection && !UserDefaults.LucasOnboardingCompleted` → 显示。
- 点「稍后再说」会写 `LucasOnboardingSkipped = true`，以后启动不再自动弹出
- 点「开始使用」写 `LucasOnboardingCompleted = true`
- 菜单 **帮助 → 重新显示新手引导** 会清除两个标记并重新打开引导
- 想用命令重置：

```bash
defaults delete com.lucas.app LucasOnboardingCompleted
defaults delete com.lucas.app LucasOnboardingSkipped
```

### 9.7 语音

- `SpeechInput`：`AVAudioEngine` + `SFSpeechRecognizer`，流式转写；支持选择输入设备与语言。
- `SpeechOutput`：`AVSpeechSynthesizer`，可选中文音色、语速、试听。
- `AudioDevices`：CoreAudio 枚举输入设备。
- 首次使用触发 TCC：麦克风、语音识别。

### 9.8 Markdown

`MarkdownView` 支持代码块（含复制）、标题、列表、引用、行内样式；用 `NSTextView`/AttributedString 渲染。

### 9.9 更新入口

- 菜单：`Lucas Agent → 检查更新…`（⌘U）
- 设置页：在线更新
- 顶栏齿轮圆点、侧栏圆点：发现新版本时显示

### 9.10 调试钩子

`LucasApp` 支持环境变量控制窗口尺寸、截图、自动关闭、打开设置页等，见 [16.4](#164-调试环境变量)。

---

## 10. 数据与存储

| 路径 | 内容 |
|---|---|
| `~/Library/Application Support/Lucas/kernel.sock` | 内核 socket |
| `~/Library/Application Support/Lucas/kernel.sqlite3` | 会话、配置、授权、工具审计 |
| `~/Library/Application Support/Lucas/Prompts/` | 可选提示词覆盖 |
| `~/Library/Application Support/Lucas/` | 其他内核状态 |
| `~/Library/Logs/Lucas/app.log` | UI 日志 |
| `~/Library/Logs/Lucas/lucasd.log` | 内核日志 |
| `~/Library/Preferences/com.lucas.app.plist` | UserDefaults（引导完成标记、Sparkle 状态） |

数据迁移：旧版 `JaplosClone` 目录在首次启动时复制到 `Lucas`（不删除旧目录）。

---

## 11. 安全与权限

### 11.1 TCC 权限

| 权限 | 触发时机 |
|---|---|
| 麦克风 | 首次语音输入 |
| 语音识别 | 首次语音输入 |
| 屏幕录制 | 首次截屏工具 |
| 自动化（Apple Events） | 控制音乐 / Finder 定位 / AppleScript |
| 文件与文件夹 | 访问桌面/文稿/下载 |

### 11.2 签名权限（entitlements）

`Config/Lucas.entitlements`：

```xml
<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
```

签名时同时启用 **Hardened Runtime** 与时间戳。

### 11.3 工具风险与审批

- 高风险（`shell.execute`）执行前必须弹窗确认。
- 审批走 `approval` 帧，UI 返回 `tool.approval`。
- 拒绝时工具不执行，模型收到拒绝结果。
- 工具审计写入 `tool_invocations`。

### 11.4 密钥与凭据清单

| 凭据 | 位置 | 是否可提交 |
|---|---|---|
| Sparkle EdDSA 公钥 | `Config/sparkle_public_key.txt` | ✅ |
| Sparkle EdDSA 私钥 | `.secrets/sparkle_ed_key` | ❌ 备份 |
| App Store Connect API Key `.p8` | `.secrets/AuthKey_*.p8` | ❌ |
| 公证 profile | 独立钥匙串 `.secrets/notary.keychain-db` | ❌ |
| 发布配置（含本机路径） | `Config/release.env` | ❌ |
| 服务器部署私钥 | `.secrets/deploy_key` | ❌ |
| SSH 登录密码 | 仅口头/密码管理器 | ❌ |
| 用户模型 API Key | Keychain `com.lucas.app.secrets`；降级时 `<home>/secrets.json`（0600） | ❌（用户数据） |

> ⚠️ 当前模型 API Key 明文存 SQLite。下一步应迁移到 Keychain（见 18 章）。

### 11.5 服务器安全

- 仅开放 22 / 80 / 443。
- 部署使用专用 ed25519 key，`~/.ssh/authorized_keys` 追加。
- HTTPS 由 Let's Encrypt 签发，certbot 自动续期。
- 静态目录只读服务，无数据库、无脚本执行。

---

## 12. 构建与运行

### 12.1 直接构建

```bash
swift build --disable-sandbox            # debug
swift build --disable-sandbox -c release # release
swift test --disable-sandbox             # 单元测试
```

### 12.2 打包 .app

```bash
./scripts/build-app.sh release
```

可配置环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `LUCAS_VERSION` | 0.4.0 | CFBundleShortVersionString |
| `LUCAS_BUILD` | 时间戳 | CFBundleVersion |
| `LUCAS_FEED_URL` | 占位 | SUFeedURL |
| `LUCAS_SIGN_IDENTITY` | 空 | 设置则 Developer ID 签名，否则 ad-hoc |
| `LUCAS_ENABLE_AUTO_UPDATES` | 空 | 设置则 SUEnableAutomaticChecks=true |

产物：`build/Lucas.app`，包含：

- `Contents/MacOS/Lucas`（UI）
- `Contents/MacOS/lucasd`（内核）
- `Contents/Frameworks/Sparkle.framework`
- `Contents/Resources/AppIcon.icns`
- Info.plist（版本、feed、公钥、TCC 描述、Sparkle 配置）

签名时给可执行文件加 `@executable_path/../Frameworks` rpath。

### 12.3 发布脚本

```bash
./scripts/publish.sh 0.5.3
```

它读取 `Config/release.env`，调用 `scripts/release.sh`：

1. 校验必需环境（真实 feed、签名身份、公证 profile）
2. `build-app.sh release`（签名）
3. `notarytool submit --wait`
4. `stapler staple`
5. 打 `updates/Lucas-<version>.zip`
6. `generate_appcast`（EdDSA 签名）
7. `package-dmg.sh` 生成 DMG
8. `rsync` 上传

任何一步失败都会中止，不会上传半成品。

### 12.4 版本号规则

- `CFBundleShortVersionString`：语义化版本 `0.5.3`。
- `CFBundleVersion`：发布时的时间戳 `YYYYMMDDHHmm`，必须递增。
- Sparkle 用 `CFBundleVersion` 比较新旧。

---

## 13. 在线更新（Sparkle）

### 13.1 组件

```
Lucas.app
  └─ Sparkle.framework
       ├─ 读取 Info.plist: SUFeedURL / SUPublicEDKey
       ├─ 下载 appcast.xml（HTTPS）
       ├─ 比对 CFBundleVersion
       ├─ 弹窗展示版本 + release notes
       ├─ 下载 zip（进度条）
       ├─ 校验 EdDSA 签名 + ZIP + Developer ID
       └─ 安装并重启

服务器 /lucas/
  ├─ appcast.xml          （EdDSA 签名）
  ├─ Lucas-x.y.z.zip      （更新包，EdDSA 签名在 appcast 里）
  ├─ Lucas-x.y.z.html     （release notes）
  └─ Lucas-x.y.z.dmg      （人工下载）
```

### 13.2 Info.plist 关键键

| 键 | 当前值 | 说明 |
|---|---|---|
| `SUFeedURL` | `https://updates.okcue.app/lucas/appcast.xml` | 更新源 |
| `SUPublicEDKey` | `44mLp9g1dEz3kMN62axV9cPHQYALZ0HFcscD05d67+I=` | EdDSA 公钥 |
| `SUEnableAutomaticChecks` | `true` | 启动自动检查 |
| `SUAutomaticallyUpdate` | `false` | 不静默安装 |
| `SUAllowsAutomaticUpdates` | `false` | 用户确认 |
| `SURequireSignedFeed` | `true` | 强制签名 feed |
| `SUVerifyUpdateBeforeExtraction` | `true` | 解压前校验 |

### 13.3 EdDSA 密钥

- 私钥：`.secrets/sparkle_ed_key`（**必须备份**；丢失后旧版本无法验证新更新）
- 公钥：写入 Info.plist，并可在 `Config/sparkle_public_key.txt` 查看
- 签名工具：`tools/bin/generate_appcast`、`tools/bin/sign_update`

### 13.4 appcast 生成

```bash
./tools/bin/generate_appcast \
  --ed-key-file .secrets/sparkle_ed_key \
  --download-url-prefix https://updates.okcue.app/lucas/ \
  updates
```

要求：

- `updates/` 里同时有 `Lucas-<version>.zip` 与同名 `.html`（release notes）。
- 生成后 `appcast.xml` 带两个签名：每个 enclosure 的 `sparkle:edSignature`，以及 feed 自身的签名块。
- 生成过程需要写 `~/Library/Caches/Sparkle_generate_appcast`；在受限沙箱里会失败，普通终端正常。

### 13.5 更新说明（release notes）

- 文件名必须与 zip 同名：`Lucas-0.5.4.html`。
- 内容是 HTML 片段（`<ul><li>…</li></ul>` 即可），generate_appcast 会嵌入 `<description><![CDATA[…]]></description>`。
- Sparkle 更新弹窗直接渲染这份 HTML。
- App 内「在线更新」页会读取同一段 description，并把 HTML 转成纯文本展示。

### 13.6 用户侧流程

1. 启动检查 / 手动 ⌘U。
2. 弹窗显示：当前版本 → 新版本、release notes、`稍后` / `安装更新`。
3. 点安装：同一窗口显示下载进度条。
4. 下载完成：校验签名 → `安装并重新启动`。
5. App 退出、替换、自动重启；数据保留。
6. 新版本启动后，在线更新页显示已是新版。

### 13.7 staple 报 Error 73

`stapler` 偶尔会在反复重建的 `build/Lucas.app` 上报 `Error 73`，但同一份 zip 解出来的 App 可以正常 staple。`release.sh` 已改为：

1. 用提交公证的 zip 解压到临时目录
2. 对临时目录里的 App 执行 `stapler`
3. 用 stapled 的 App 替换 `build/Lucas.app`
4. 再打最终 zip / DMG

如果手工遇到，按同样步骤处理即可。

### 13.8 常见失败

| 现象 | 原因 |
|---|---|
| 弹窗“无法检查更新” | feed URL 404 / HTTPS 不可达 |
| “更新签名无效” | zip 与 appcast 不匹配，或私钥/公钥不一致 |
| 安装时提示签名不一致 | 新旧包 Developer ID 不同（换证书后首次更新会这样） |
| 更新后权限重新弹 | 签名身份变化 |
| `generate_appcast` 报 cache 权限 | 在受限沙箱运行；换普通终端 |

---

## 14. 服务器与部署

### 14.1 基本信息

| 项 | 值 |
|---|---|
| 公网 IP | `43.132.224.242` |
| 域名 | `updates.okcue.app` |
| DNS | Cloudflare（`alice.ns.cloudflare.com` / `john.ns.cloudflare.com`），A 记录指向上述 IP，**仅 DNS（灰云）** |
| 系统 | Ubuntu 26.04 LTS |
| SSH 用户 | `ubuntu`（免密 sudo） |
| Web 服务器 | nginx 1.28.3 |
| 证书 | Let's Encrypt，certbot 4.0.0 自动续期 |
| 站点根目录 | `/var/www/updates` |
| 应用目录 | `/var/www/updates/lucas` |
| 公网地址 | `https://updates.okcue.app/lucas/` |

> 登录密码、部署私钥、公证口令等敏感信息只保存在密码管理器 / `.secrets/` / `Config/release.env`，**不在本文档中**。

### 14.2 nginx 配置

`/etc/nginx/sites-available/lucas-updates`（certbot 会改写 443 部分）：

```nginx
server {
    server_name updates.okcue.app;
    root /var/www/updates;

    location / {
        try_files $uri =404;
        add_header Cache-Control "no-cache";
    }

    listen [::]:443 ssl ipv6only=on; # managed by Certbot
    listen 443 ssl;                  # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/updates.okcue.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/updates.okcue.app/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if ($host = updates.okcue.app) {
        return 301 https://$host$request_uri;
    }
    listen 80;
    listen [::]:80;
    server_name updates.okcue.app;
    return 404;
}
```

要点：

- `root` 是 `/var/www/updates`，所以 URL `/lucas/appcast.xml` 映射到 `/var/www/updates/lucas/appcast.xml`。
- `try_files $uri =404`：不列目录，不执行脚本。
- `Cache-Control: no-cache`：避免客户端缓存旧 appcast。

### 14.3 首次部署服务器（新机器）

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx

sudo mkdir -p /var/www/updates/lucas
sudo chown -R ubuntu:ubuntu /var/www/updates

# 写入上面的 nginx 配置并启用
sudo ln -sf /etc/nginx/sites-available/lucas-updates /etc/nginx/sites-enabled/lucas-updates
sudo nginx -t && sudo systemctl reload nginx
```

**先在云控制台放行 TCP 80 / 443**（轻量应用服务器 → 防火墙；CVM → 安全组），否则 certbot 会 HTTP-01 超时。

签发证书：

```bash
sudo certbot --nginx -d updates.okcue.app \
  --non-interactive --agree-tos --register-unsafely-without-email --redirect
```

### 14.4 部署密钥

本机已生成 `.secrets/deploy_key`（ed25519），公钥追加到服务器 `~/.ssh/authorized_keys`。

`release.sh` 通过：

```bash
rsync -av --delete \
  -e "ssh -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=.secrets/known_hosts \
      -i .secrets/deploy_key" \
  updates/ ubuntu@43.132.224.242:/var/www/updates/lucas/
```

`--delete` 会删除服务器上本地不存在的文件，因此 `updates/` 就是线上目录的唯一事实源。

### 14.5 续期与监控

```bash
sudo certbot renew --dry-run          # 验证自动续期
systemctl list-timers | grep certbot
curl -I https://updates.okcue.app/lucas/appcast.xml
```

`certbot.timer` 默认每天检查，证书到期前 30 天自动续。

### 14.6 故障排查

| 现象 | 排查 |
|---|---|
| certbot HTTP-01 超时 | 云防火墙 80 未放行；或 DNS 非灰云 |
| 外网 80/443 超时、22 正常 | 安全组只开了 22 |
| `appcast.xml` 404 | nginx root 配错；或 rsync 目标路径错 |
| 上传报 host key changed | 用 `.secrets/known_hosts`；或删除旧 known_hosts 条目 |
| 本地访问域名解析到 `198.18.x.x` | 本机 DNS 代理 fake-IP，验证时用 `curl --resolve updates.okcue.app:443:43.132.224.242` |
| 上传后仍是旧 feed | 检查 `updates/appcast.xml` 是否重新生成、rsync 是否成功 |

---

## 15. 发布流程与检查清单

### 15.1 标准发布

```bash
cd ~/Desktop/japlosv2/clone

# 1) 写更新说明（建议）
cat > updates/Lucas-0.5.4.html <<'EOF'
<ul>
<li>修复……</li>
<li>新增……</li>
</ul>
EOF

# 2) 一条命令
./scripts/publish.sh 0.5.3
```

### 15.2 发版说明自动生成

`publish.sh` 会在发布前调用 `scripts/release-notes.sh <version>`：

- 如果 `updates/Lucas-<version>.html` 已存在，直接使用（人工写的优先）
- 否则从 **上一个 git tag 到 HEAD** 的提交标题生成 HTML 列表
- 没有新提交时写“本次更新包含若干修复与改进。”
- 发布成功后自动打 tag `v<version>`，下个版本的说明只包含新提交

因此发版前请先把改动提交到 git；目录不是 git 仓库时会退化为占位说明。

### 15.3 脚本内部顺序

```
release.sh
 ├─ 校验 LUCAS_FEED_URL（非 example.com）、SIGN_IDENTITY、NOTARY_PROFILE
 ├─ build-app.sh release
 │    ├─ swift build -c release
 │    ├─ 组装 .app + Sparkle.framework + icns
 │    ├─ 写 Info.plist（版本、feed、公钥、TCC）
 │    └─ codesign（Hardened Runtime + entitlements + timestamp）
 ├─ notarytool submit --wait（keychain profile）
 ├─ stapler staple / validate
 ├─ ditto 打 zip
 ├─ generate_appcast（EdDSA）
 ├─ package-dmg.sh（hdiutil）
 └─ rsync 上传
```

### 15.4 发布前检查清单

- [ ] 版本号递增，build 号大于线上
- [ ] `updates/Lucas-<version>.html` 已写
- [ ] 本机 `swift test` 通过
- [ ] `./scripts/smoke_test.sh` 16/16
- [ ] `codesign -dv build/Lucas.app` 显示 Developer ID
- [ ] `spctl -a -t exec -vv build/Lucas.app` 为 `accepted / Notarized Developer ID`
- [ ] `curl -I https://updates.okcue.app/lucas/appcast.xml` 200
- [ ] 下载 zip 校验 `sparkle:edSignature`
- [ ] 旧版本装一次，走完“检查 → 弹窗 → 进度 → 重启”

### 15.5 发布后验证

```bash
curl -sI https://updates.okcue.app/lucas/appcast.xml | head -3
curl -s https://updates.okcue.app/lucas/appcast.xml | head -20
curl -s --resolve updates.okcue.app:443:43.132.224.242 \
  -o /tmp/Lucas.zip https://updates.okcue.app/lucas/Lucas-0.5.4.zip
shasum -a 256 /tmp/Lucas.zip updates/Lucas-0.5.4.zip
```

---

## 16. 测试与验证

### 16.1 冒烟测试（16 步）

`scripts/smoke_test.sh` 覆盖：

1. 构建 lucasd
2. 启动内核 + 握手
3. `kernel.status`
4. 授权
5. 会话创建
6. 历史
7. 流式（mock model）
8. 取消
9. 工具调用
10. 审批允许
11. 审批拒绝
12. 系统信息工具
13. PDF 生成
14. MCP stdio
15. MCP HTTP
16. 模型目录

运行：

```bash
./scripts/smoke_test.sh
```

### 16.2 单元测试

```bash
swift test --disable-sandbox
```

覆盖协议编解码、帧、能力策略等（7 个用例）。

### 16.3 真实模型验证

`docs/real-conversation.md` 记录了用 Pollinations（OpenAI 兼容）完成的真实对话 + 工具调用（时间工具）验证。

### 16.4 更新源健康检查

```bash
./scripts/check-updates.sh 0.5.3
LUCAS_CHECK_DEEP=1 LUCAS_CHECK_RESOLVE=43.132.224.242 ./scripts/check-updates.sh 0.5.3
```

- 校验 feed 可访问、版本号、enclosure 与签名是否存在
- `LUCAS_CHECK_DEEP=1` 会下载 zip 并用公钥验证 EdDSA
- `LUCAS_CHECK_RESOLVE=<IP>` 绕过本地 fake-IP DNS，直连服务器
- 可放进 cron / UptimeRobot 做监控

### 16.5 调试环境变量

| 变量 | 作用 |
|---|---|
| `LUCAS_CLONE_HOME` | 覆盖数据目录 |
| `LUCAS_SOCKET` | 覆盖 socket 路径（脚本用） |
| `LUCAS_WINDOW_SIZE` | 窗口尺寸，如 `1600x1000` |
| `LUCAS_WINDOW_CAPTURE` | 启动后截图到指定路径并退出 |
| `LUCAS_CAPTURE_DELAY` | 截图延迟秒数 |
| `LUCAS_SNAPSHOT` | 渲染单帧快照 |
| `LUCAS_OPEN_SETTINGS` | 启动即打开设置（`1`） |
| `LUCAS_SETTINGS_SECTION` | 指定设置页，如 `语音设置` |
| `LUCAS_SHOW_ONBOARDING` | 强制显示首次引导 |
| `LUCAS_ONBOARDING_STEP` | 引导起始步骤 `connect` / `done` |
| `LUCAS_ONBOARDING_PROVIDER` | 预选服务商 |
| `LUCAS_ONBOARDING_AUTOTEST` | 自动走保存 + 测试连接 |
| `LUCAS_DISABLE_UPDATER` | 禁用 Sparkle（调试） |
| `LUCAS_CHECK_UPDATES_ON_LAUNCH` | 启动后强制检查更新 |
| `LUCAS_AUTOCLOSE_TEST` | 自动关闭窗口（测试） |

### 16.6 更新源监控

本机安装一个每 6 小时检查一次 feed 的 LaunchAgent：

```bash
./scripts/install-monitor.sh install
./scripts/install-monitor.sh uninstall
```

- 生成 `~/Library/LaunchAgents/com.lucas.updates-check.plist`
- 日志：`~/Library/Logs/Lucas/updates-monitor.log`
- 检查失败时 LaunchAgent 的 last exit code 非 0，可被系统监控发现
- 在受限沙箱里运行时会自动把 plist 放到 `Config/` 并打印一键安装命令

### 16.7 手动回归清单

- [ ] 首次引导：无配置 → 三步 → 完成
- [ ] 模型切换：右上角胶囊 → 选择 → 下一条消息生效
- [ ] 顶栏连接状态：重启内核后自动恢复
- [ ] 工具审批：Shell 命令 → 弹窗 → 拒绝不执行
- [ ] MCP：stdio 与 HTTP 各加一个，工具出现在列表
- [ ] 语音：麦克风 → 转写 → 自动发送；播报可停止
- [ ] 在线更新：有新版 → 圆点 → 检查 → 弹窗带说明
- [ ] 窗口：启动 1400×875；拉伸后左右 24pt 边距不变

---

## 17. 开发指南：新增能力

### 17.1 新增一个内核操作

1. `KernelProtocol.swift` 加 `static let xxx = KernelOperation("group.action")`。
2. `KernelCore.swift` 的 `CapabilityRouting` 映射到能力。
3. `KernelCore.handle` 加 `case` 分支。
4. 需要持久化就在 `KernelStore` 加方法（避免在 Core 里写 SQL）。
5. 更新本文档第 6.3 表。

### 17.2 新增一个工具

1. 在 `BuiltinTools.swift` / 新文件实现 `Tool` 协议：
   - `definition`：name、title、summary、inputSchema、capability、risk
   - `invoke(arguments:context:)`
2. 在 `ToolRegistry` 注册。
3. 高风险工具记得在 `invoke` 前置审批（参考 Shell）。
4. 写冒烟测试步骤。
5. 更新本文档 7.6 表 + README 工具数。

命名规范：`system.<domain>.<action>`，全小写、点分隔。

### 17.3 新增设置页

1. `SettingsSection` 加 case + icon。
2. `content` switch 加 pane。
3. 新 pane 用 `SettingsMetrics` 与 `Theme`，不要写裸字号。
4. `scripts/build-app.sh` 不需要改。

### 17.4 改提示词

优先改 `PromptLibrary` 片段；临时调整可放 `~/Library/Application Support/Lucas/Prompts/<id>.md` 覆盖，不需要发版。

---

## 18. 已知限制与技术债

| 项 | 说明 | 建议 |
|---|---|---|
| ~~API Key 明文存储~~ | 0.5.3 起已迁移到 Keychain / 0600 文件，SQLite 只保留空字段 | 已完成 |
| 内部模块名仍为 `Japlos*` | `JaplosProtocol` / `JaplosKernel` / `JaplosRuntime` | 用户不可见；彻底改名需全量改 import |
| appcast channel 标题为 `Lucas` | generate_appcast 读取可执行名 | 可改 zip/包名或后处理，影响很小 |
| ~~首次引导「稍后再说」不持久化~~ | 0.5.4 起已持久化，并支持帮助菜单重置 | 已完成 |
| 语音只有系统实现 | 没有火山/MiMo 云端语音 | 需要凭据与流式协议，另立项目 |
| 无 UI 自动化测试 | 只有协议单测 + 冒烟 | 可加 XCUITest，但成本高 |
| DMG 未单独公证 | App 已公证，DMG 仅签名 | 需要时可 `notarytool submit dmg` 再 staple |
| 更新说明需手写 | 不会自动从 git log 生成 | 在 release.sh 里接 `git log` 或模板 |
| 服务器单点 | 无 CDN/备份 | appcast 可加 Cloudflare 缓存；定期备份 `/var/www` |

---

## 19. 交接清单与运维手册

### 19.1 接手第一天

1. 读本文 + `README.md` + `../REPORT.md`。
2. `swift build --disable-sandbox && ./scripts/smoke_test.sh`。
3. 确认钥匙串有 `Developer ID Application: wei bo (C49X44B3DA)`。
4. 确认 `.secrets/` 下有：`sparkle_ed_key`、`deploy_key`、`notary.keychain-db`、`AuthKey_*.p8`（可选）。
5. 确认 `Config/release.env` 存在且指向 `updates.okcue.app`。
6. 跑一次 `./scripts/publish.sh <下一个版本>`（可先发测试版）。

### 19.2 证书与凭据续期

| 项 | 周期 | 操作 |
|---|---|---|
| Developer ID 证书 | 约 1 年 | Xcode → Manage Certificates 重新生成 |
| 公证 API Key | 不过期 | App Store Connect → Integrations 撤销/重建 |
| Sparkle 密钥 | 永久 | **离线备份**，不要重置 |
| Let's Encrypt | 90 天 | certbot 自动续；`certbot renew --dry-run` 验证 |
| 服务器 SSH key | 长期 | 泄露时从 `authorized_keys` 删除并重建 |

### 19.3 密钥轮换

- **Sparkle**：换密钥会导致旧版本无法验证新更新，必须保留旧私钥直到所有用户升级；不要轻易轮换。
- **公证**：换 API Key 后重新 `store-credentials`，更新 `LUCAS_NOTARY_PROFILE`。
- **部署 key**：新 key 加到服务器后再删旧 key。

### 19.4 回滚

- 应用回滚：把旧版本 zip + 对应 appcast 重新上传（Sparkle 只按 build 号比较，旧 build 不会“降级”，因此回滚需要发一个 build 号更高的修复版）。
- 服务器回滚：`updates/` 保留历史 zip 时可直接重新生成 appcast。

### 19.5 监控建议

```bash
# 一次性检查
./scripts/check-updates.sh 0.5.4

# 每 6 小时自动检查（普通终端执行）
./scripts/install-monitor.sh install

# 查看最近结果
tail -20 ~/Library/Logs/Lucas/updates-monitor.log
```

- 每天 curl 一次 appcast（可用 UptimeRobot 等）。
- 每周检查服务器磁盘、证书到期。
- 发布后 24 小时观察用户更新成功率（目前无埋点，可后续加）。

---

## 20. 附录

### 20.1 常用命令

```bash
# 构建 & 运行
swift build --disable-sandbox
./scripts/build-app.sh release
open build/Lucas.app

# 测试
swift test --disable-sandbox
./scripts/smoke_test.sh

# 发布
./scripts/publish.sh 0.5.3
./scripts/package-dmg.sh

# 服务器
ssh -i .secrets/deploy_key ubuntu@43.132.224.242
sudo nginx -t && sudo systemctl reload nginx
sudo certbot renew --dry-run
curl -I https://updates.okcue.app/lucas/appcast.xml

# 签名校验
codesign -dv --verbose=4 build/Lucas.app
spctl -a -t exec -vv build/Lucas.app
xcrun stapler validate build/Lucas.app
```

### 20.2 关键 URL

| 用途 | URL |
|---|---|
| appcast | `https://updates.okcue.app/lucas/appcast.xml` |
| 最新 DMG | `https://updates.okcue.app/lucas/Lucas-0.5.4.dmg` |
| 最新 ZIP | `https://updates.okcue.app/lucas/Lucas-0.5.4.zip` |
| 更新说明 | `https://updates.okcue.app/lucas/Lucas-0.5.4.html` |

### 20.3 术语

| 术语 | 含义 |
|---|---|
| 内核 / daemon | `lucasd` 进程 |
| 能力 / capability | 权限系统中的字符串，如 `tool.invoke@1` |
| grant | 一条能力授权记录 |
| principal | 调用方身份，当前固定 `local-user` |
| 帧 | 4 字节长度 + JSON 的消息单元 |
| approval | 高风险工具执行前的用户确认 |
| appcast | Sparkle 的更新清单 XML |
| EdDSA | Sparkle 更新签名算法（ed25519） |
| staple | 把公证票据附加到 App 上 |

### 20.4 文档维护

改动以下内容时请同步更新本文：

- `KernelProtocol` 操作表 → 6.3
- 能力列表 → 6.4
- 数据库 schema → 7.4
- 工具清单 → 7.6
- 设置页/设计 token → 9.4/9.5
- Info.plist / Sparkle 键 → 13.2
- nginx / 域名 / 路径 → 14
- 发布脚本行为 → 15

---

*本文档由代码与线上配置核对生成；如与代码冲突，以代码为准，并请修正文档。*
