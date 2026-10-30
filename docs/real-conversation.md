# 真实模型对话验收记录

日期：2026-10-29
目标：验证复刻版不只是对 mock 服务可用，而是能与真实模型 provider 完成「对话 + 工具调用」闭环。

## 环境

| 项 | 值 |
|---|---|
| Provider | `https://text.pollinations.ai/openai`（公开 OpenAI 兼容端点） |
| 模型 | `openai`（服务端实际返回 `gpt-oss-20b`） |
| 凭据 | 免 Key（`anonymous`），无需真实密钥 |
| 路径 | SwiftUI/CLI → Unix Socket → lucasd → HTTPS → provider |

## 1. 纯对话

请求（经内核）：

```json
{"operation":"chat.send","arguments":{"text":"你好，请用一句话介绍你自己"}}
```

返回：

```json
{
  "finishReason": "stop",
  "text": "我是 Japlos，一个在 Mac 上运行的桌面 Agent，能够读取本机状态、操作应用、执行命令、读写文件，并完成用户指令。"
}
```

真实模型读取到了复刻版的分层系统提示词并保持了身份设定。

## 2. 真实工具调用

请求：

```json
{"text":"现在几点了？请调用 system.time 工具查询本机时间，再回答我"}
```

数据库中的轮次（`run/real/k.db`）：

```json
[
  {"role": "user", "text": "现在几点了？请调用 system.time 工具查询本机时间，再回答我"},
  {"role": "assistant", "text": "", "tool_calls": [
    {"name": "system.time", "arguments": {"action": ""}}
  ]},
  {"role": "tool", "tool_name": "system.time",
   "text": "{\"ok\":true,\"output\":{\"local\":\"2026-10-29 16:19:24\",\"timeZone\":\"Asia/Shanghai\"}}"}
]
```

模型确实发起了工具调用，内核执行 `system.time` 并落库。后续总结请求被 provider 的免费额度限流（1 次/30 秒），补一次请求后得到：

```json
{"text": "现在是 2026-10-29 16:19:24（Asia/Shanghai）。"}
```

## 3. 期间修掉的真实兼容性问题

1. **tool 消息的 `name` 字段**：我们原先把工具名写进 `"name": "system.time"`，上游以 `Invalid message name for role 'tool'` 拒绝（点号不符合 `^[a-zA-Z0-9_-]{1,64}$`）。OpenAI 规范里 `name` 可选，已改为不发送，工具与回执靠 `tool_call_id` 关联。
2. **限流错误透传**：provider 的 402 `FREE_LIMIT` 会作为 `model_error` 原样显示在界面上，不会假装成功。

## 结论

- 端到端真实对话：通过
- 真实模型工具调用 + ReAct 回执：通过
- 失败路径（限流 / 参数不合法）可观测：通过

因此目标中的「可真实对话」有实证支撑。
