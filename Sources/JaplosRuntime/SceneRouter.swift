import Foundation
import JaplosProtocol

public struct Scene: Sendable {
    public var id: String
    public var name: String
    public var pattern: String
    public var extraPrompt: String
    public var tools: [String]

    public init(id: String, name: String, pattern: String, extraPrompt: String, tools: [String]) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.extraPrompt = extraPrompt
        self.tools = tools
    }
}

public enum SceneRouter {
    public static let scenes: [Scene] = [
        Scene(
            id: "music",
            name: "播放音乐",
            pattern: "播放|音乐|歌曲|来一首|下一首|上一首|暂停|music|song",
            extraPrompt: "音乐操作优先使用 system.music：play/pause/toggle/next/previous/status。播放前先用 status 确认应用状态。",
            tools: ["system.music", "system.application"]
        ),
        Scene(
            id: "application",
            name: "打开应用",
            pattern: "打开|启动|关闭|退出|open |launch|quit",
            extraPrompt: "打开或退出应用时使用 system.application：先 open/quit，再用 list 核对结果。",
            tools: ["system.application", "system.command.shell.execute"]
        ),
        Scene(
            id: "screenshot",
            name: "截屏",
            pattern: "截图|截屏|屏幕|screenshot|capture",
            extraPrompt: "截屏使用 system.screen.capture；成功后把保存路径告诉用户。",
            tools: ["system.screen.capture"]
        ),
        Scene(
            id: "filesystem",
            name: "文件操作",
            pattern: "文件|目录|文件夹|读取|写入|保存到|file|folder|directory",
            extraPrompt: "文件操作使用 system.filesystem；写入前确认路径，不要把大段内容塞进命令参数。",
            tools: ["system.filesystem", "system.command.shell.execute"]
        ),
        Scene(
            id: "shell",
            name: "执行命令",
            pattern: "命令|终端|shell|command|运行脚本",
            extraPrompt: "命令执行使用 system.command.shell.execute；先说明将要执行的命令，危险操作需用户确认。",
            tools: ["system.command.shell.execute"]
        ),
        Scene(
            id: "time",
            name: "时间",
            pattern: "几点|时间|日期|今天|time|date",
            extraPrompt: "涉及当前时间时先调用 system.time，不要凭记忆回答。",
            tools: ["system.time"]
        ),
        Scene(
            id: "audio",
            name: "系统音量",
            pattern: "音量|声音大小|静音|volume",
            extraPrompt: "音量控制使用 system.audio；设置前先用 get 读取当前值。",
            tools: ["system.audio"]
        ),
        Scene(
            id: "download",
            name: "下载文件",
            pattern: "下载|保存.{0,4}链接|http|download",
            extraPrompt: "下载使用 system.download.fetch：确认 URL 是 http(s)，默认保存到 ~/Downloads，完成后报告路径与大小。",
            tools: ["system.download.fetch"]
        ),
        Scene(
            id: "pdf",
            name: "生成 PDF",
            pattern: "PDF|pdf|导出|生成.{0,6}文档|排版",
            extraPrompt: "生成 PDF 使用 system.document.pdf.create；正文直接传文本，路径默认 ~/Downloads。",
            tools: ["system.document.pdf.create", "system.filesystem"]
        ),
        Scene(
            id: "system-info",
            name: "系统状态",
            pattern: "窗口|进程|网络|IP|系统状态|占用|内存",
            extraPrompt: "系统状态优先用只读工具：system.window.list / system.process.list / system.network.info；先取数据再总结。",
            tools: ["system.window.list", "system.process.list", "system.network.info"]
        ),
        Scene(
            id: "notification",
            name: "系统通知",
            pattern: "通知|提醒我|完成后提醒",
            extraPrompt: "需要提醒时使用 system.notification，标题简短、正文一句话。",
            tools: ["system.notification"]
        ),
        Scene(
            id: "clipboard",
            name: "剪贴板",
            pattern: "剪贴板|复制|粘贴|clipboard",
            extraPrompt: "剪贴板操作使用 system.clipboard。",
            tools: ["system.clipboard"]
        ),
    ]

    public static func match(_ text: String) -> Scene? {
        for scene in scenes {
            guard let regex = try? NSRegularExpression(pattern: scene.pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil { return scene }
        }
        return nil
    }
}
