# 代码审查报告 — commit 5246a10（WorkBuddy）

范围：13 文件，+325/-54。审批闸统一（ToolApprovalGate）、TrustRoots 壳路径加固、DangerousCommand 新规则、截屏/桌面文件场景修复。

验证手段：① swift test --disable-sandbox 全过（Protocol 11 + Kernel 5 + Runtime 4 = 20 用例）；② 编写了引用 JaplosKernel 的独立验证程序，对 16 条攻击样例实测 DangerousCommand + TrustRoots（下述「实测」均出自此）。

## 🔴 阻断问题（合并前必须修）

### 1. 场景修复对存量用户完全无效

- 位置：SceneRouter.swift:75-87（seedScenesIfNeeded）+ japlosd/main.swift:113
- 事实：loadFromDisk 优先读 App Support 覆盖文件，而 seedScenesIfNeeded 在文件已存在时直接 return false。已部署用户（updates/ 里有历史 DMG，证明存在存量）的旧 scenes.json 仍带宽松 pattern 截图|截|屏幕|桌面——「桌面上的文件」继续命中截屏场景。本次提交的第三个目标对最需要修复的用户群静默失效，且新增的 4 个回归测试全部读 bundled JSON，测不出此问题。
- 改法：在 scenes.json 根节点加 schemaVersion（字段已存在但未使用），seedScenesIfNeeded 检测旧版本时执行迁移（按 id 合并覆盖或提示重新种子化）。
- 验证：单测——预先写入旧版 override 文件，断言 SceneRouter.match("桌面上的文件")?.id == "filesystem"。

### 2. authorized_keys 新规则一行命令绕过（安全声明与实现不符）

- 位置：BuiltinTools.swift DangerousCommand 规则 >\s*~/?\.ssh/authorized_keys / tee 两条
- 实测绕过（均放行）：
  - `printf 'ssh-ed25519 AAA' > /Users/w/.ssh/authorized_keys` —— 规则只匹配 ~ 和 $HOME 前缀，忘了绝对路径形式，且该路径在 home 内、TrustRoots 也放行
  - `cp ~/key.pub ~/.ssh/authorized_keys` —— 只封了 > 和 tee，没封 cp/mv/dd/install
- 改法：放宽为路径级匹配 `(?i)\.ssh/authorized_keys\b`，对出现在任何重定向/cp|mv|tee|dd|install|rsync 目标位置的一律拒绝；或干脆封「命令文本中出现 authorized_keys」——误伤率极低。
- 验证：DangerousCommandTests 补上述两条样例。缓解因素（事实）：shell 为 risk .high，所有命令仍需用户逐条审批，此层是第二防线——但提交信息明确声称已封堵 authorized_keys 写入，实测未达成，按生产标准判阻断。

## 🟠 高优先级改进

### 3. rm 规则漏分写/长选项标志（实测均放行）
`rm -r -f ~/important`、`rm --recursive --force ~/important`。所有 rm 规则只匹配合并式 `-rf`。改法：先归一化 `-\w+` 标志序列再匹配 r 与 f 同时出现（含 `--recursive`/`--force`）。验证：补单测。

### 4. pipe-to-shell 规则可绕（实测均放行）
`curl … | tee /tmp/x.sh | sh`（`[^\n|;]*` 跨不过第二个管道）、`bash <(curl …)`、`curl -o /tmp/x.sh && sh /tmp/x.sh`。改法有限，建议在 DangerousCommand 注释中明确此层是「防呆」而非安全边界，真正边界是审批闸——避免后人误信黑名单已封死。

### 5. `cd ~/Library && rm -rf *` 不拦（实测放行）
白名单只保护 Desktop/Documents/Downloads，`~/Library`（含 Keychains、Mail）全裸奔。改法：把 Library 加入规则 3 的目录列表，或封 `rm -rf *`/`rm -rf .` 通配删除。

### 6. 主流工具绝对路径被硬拒，审批也无法放行（实测）
`/opt/homebrew/bin/brew`（Apple Silicon Homebrew 默认路径）、`/usr/local/bin/node` 均被 `blockedAbsolutePaths` 拒绝且注释明确「审批不能放行」。会造成大量误伤。改法：`systemExecutablePrefixes` 增加 `/opt/homebrew/bin/`、`/usr/local/bin/`（只读执行路径，风险低）。验证：补允许样例单测。

## 🟡 一般改进

- 7. 双份场景定义已分叉：`SceneRouter.builtInScenes` 与 bundled `scenes.json` 各维护一套，builtin 的 `file|folder|directory` 少了 `\b`，"profile" 也会命中。建议 builtin 收缩为最小兜底或由单一来源生成。
- 8. 行为变更未标注：旧代码在 `approval == nil` 时非流式通道会静默执行 `.high` 工具（含 shell 命令）；新代码一律拒绝。安全上是正确修复，但对依赖 `tool.invoke` 跑 shell 的既有客户端是 breaking change，需发布说明。另注：`KernelCore.swift:1089` 拒绝走 success 信封 + `ok:false`，与 unknown tool 的 failure 信封不一致，客户端需两处判错。
- 9. 已知限制（事实）：token 扫描可被 shell 字符串拼接绕过（实测 `cat /et""c/passwd` 放行）；`allowedURL` 存在 resolve→write 之间的 symlink TOCTOU。均属黑名单/路径检查的固有天花板，建议注释注明，不做阻断。

## ✅ 审查通过项

- 审批闸单点化正确：`system.filesystem` 仅 read/write/list 三 action，gate 只放行 write 之外，无漏拦；`system.application` 的 list/open/quit 与 gate 完全对齐。
- ChatService 修复了 `approval==nil` 时静默副作用的历史漏洞；`tool.invoke` 同闸拒绝，两处口径一致。
- TrustRoots/ToolApprovalGate 均为无状态纯函数，线程安全；测试断言了「所有 .high 工具必过闸」。

## 合并结论

暂缓合并。#1（存量用户拿不到修复）与 #2（authorized_keys 封堵可被一行命令绕过）都是本次提交的核心目标未达成，修复成本低（各约 10 行 + 单测）；其余项可作后续跟进。修完 #1/#2 补上对应回归测试后可合。

> 说明：本报告由 WorkBuddy 针对 commit `5246a10` 的 diff 审查写出，不是全仓审计。镇元核对后：「审批闸单点化正确」仅对本次改动的工具成立；PDF/MCP 等未改工具的审批漏网不在本报告视野内。
