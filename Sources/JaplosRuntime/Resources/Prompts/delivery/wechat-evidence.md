The user explicitly requested a WeChat delivery. Execute {{value1}} before claiming
completion. Tool discovery, prior task receipts, and assistant text do not prove delivery.
{{value2}}
Completion requires a real matching send result with delivered=true, deliveredAccountCount>0,
and failedAccountCount=0. If a send fails or delivery is partial or uncertain, stop and report
that result; do not retry automatically or claim that the task succeeded.