# Lucas 0.5.11 发版记录（2026-10-31）

- 授权：老板 t2865u「发」
- 版本 / build：0.5.11 / 202610311413（线上原 0.5.9 / 202610311318，版本闸门 OK）
- 源码：b87e263（含 f98635b 0.5.10 下拉精简；「去官方申请」→ https://console.volcengine.com/speech/new/）
- 发布前：swift build 通过；swift test 全量 0 失败（96 个用例）；ProductVersion=0.5.11
- 流程：./scripts/publish.sh 0.5.11 → 签名、公证 Accepted、staple 通过、EdDSA appcast、rsync 部署
- 线上：appcast.xml → 0.5.11 / 202610311413；Lucas-0.5.11.zip HTTP 200；含 0.5.9 增量 delta
- tag v0.5.11；fix/audit-20261030 与 tag 已推 lucas-private、lucas-public（main 未动）

## 改动
- TTS 晚约 5 秒根因：只在 done 后朗读；DoubaoRealtimeTTS 每次新建 WS 且缓冲整段音频才返回。修复：SpeechSegmenter 随 delta 切句，首句即合成，后句播放时预取；AppLog 记录 `speech: first audio`。
- 按住空格说话：输入框为空时按住录音，松开等最终识别（≤1s）自动发送；有文字时空格正常；失焦取消。

## 签名包实测
- 未完成：Mac mini 下载安装 0.5.11 签名包的命令被用户中断，未重试。延迟、空格、设置页截图待测。
