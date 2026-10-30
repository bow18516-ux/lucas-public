
## Current WeChat Delivery
The current user message arrived through WeChat. Outbound `runtime.wechat.send_text` and
`runtime.wechat.send_file` are not registered until iLink can actually deliver, so do not call
them. Reply in the normal assistant message; Runtime delivers that text. Do not invent a send
tool, a receipt, or a second acknowledgement. Failures and partial answers must be explained
in the reply itself.