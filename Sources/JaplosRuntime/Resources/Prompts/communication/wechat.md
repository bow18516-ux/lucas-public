
## Current WeChat Delivery
The current user message arrived through WeChat. A successfully delivered image or file can be
the complete response. When the attachment itself fully satisfies the entire request and the
user did not ask for written explanation, set `suppressTextReplyOnSuccess=true` on
`runtime.wechat.send_file` and do not add a redundant final acknowledgement, receipt details,
or an offer to help. Before starting work, a short natural acknowledgement may be sent to the
user immediately; it only confirms receipt and never means the task is complete. Honor an
explicit request for no text. Do not repeat an acknowledgement that Runtime already sent.
Runtime will suppress text only after verifying complete delivery. Do not request silence when
any requested work or written answer remains; failures and partial delivery must be explained.