import JaplosProtocol
import AppKit
import SwiftUI

struct TurnRow: View {
    let message: AppModel.Message
    @State private var hovering = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    if isUser {
                        Text(message.text)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                    } else {
                        MarkdownText(text: message.text)
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                    }
                }

                if !isUser, !message.text.isEmpty, hovering {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(Theme.textSecondary)
                }

                if !message.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(message.steps) { step in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                Text(step.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                if !step.detail.isEmpty {
                                    Text(step.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Orb

struct OrbView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) * 0.48
                let breath = 0.5 + 0.5 * sin(time * 0.9)
                let glowRadius = maxRadius * (1.30 + 0.06 * breath)

                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - glowRadius,
                        y: center.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [Theme.accent.opacity(0.07 + 0.05 * breath), .clear]),
                        center: center,
                        startRadius: maxRadius * 0.25,
                        endRadius: glowRadius
                    )
                )

                // Particle shell: Fibonacci sphere projected with a slow spin.
                let count = 1100
                let spin = time * 0.16
                let tilt = 0.42
                var particles: [(CGPoint, Double, Double)] = []
                particles.reserveCapacity(count)
                for index in 0..<count {
                    let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
                    let ringRadius = (max(0, 1 - y * y)).squareRoot()
                    let theta = Double(index) * 2.399963229728653
                    let x0 = cos(theta) * ringRadius
                    let z0 = sin(theta) * ringRadius

                    let x1 = x0 * cos(spin) - z0 * sin(spin)
                    let z1 = x0 * sin(spin) + z0 * cos(spin)
                    let y1 = y * cos(tilt) - z1 * sin(tilt)
                    let z2 = y * sin(tilt) + z1 * cos(tilt)

                    let breathe = 1 + 0.018 * sin(time * 1.4 + Double(index) * 0.05)
                    let perspective = 1.0 / (1.0 + z2 * 0.22)
                    let radius = maxRadius * 0.92 * breathe * perspective
                    let point = CGPoint(x: center.x + x1 * radius, y: center.y + y1 * radius)
                    let depth = (z2 + 1) / 2
                    particles.append((point, depth, perspective))
                }
                particles.sort { $0.2 < $1.2 }

                for (point, depth, _) in particles {
                    let dotSize = 0.8 + 1.9 * depth
                    let alpha = 0.08 + 0.54 * depth
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - dotSize / 2,
                        y: point.y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    ))
                    context.fill(dot, with: .color(Theme.accent.opacity(alpha)))
                }

                // A few orbit rings keep the structure readable.
                for ring in 0..<3 {
                    let radius = maxRadius * (0.74 + Double(ring) * 0.13)
                    context.stroke(
                        Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius * 0.34,
                            width: radius * 2,
                            height: radius * 0.68
                        )),
                        with: .color(Theme.accent.opacity(0.10 - Double(ring) * 0.02)),
                        lineWidth: 0.7
                    )
                }

                let coreRadius = maxRadius * (0.30 + 0.012 * breath)
                let coreRect = CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                )
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Theme.accent.opacity(0.12 + 0.05 * breath),
                            Color(red: 0.10, green: 0.09, blue: 0.08),
                            Color(red: 0.045, green: 0.042, blue: 0.04),
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: coreRadius
                    )
                )
                context.stroke(
                    Path(ellipseIn: coreRect),
                    with: .color(Theme.accent.opacity(0.22)),
                    lineWidth: 0.8
                )
            }
        }
    }
}

// MARK: - Right column

struct RightColumn: View {
    @ObservedObject var model: AppModel
    @Binding var showTools: Bool

    private var latestSteps: [AppModel.ToolStep] {
        if let last = model.messages.last(where: { !$0.steps.isEmpty })?.steps, !last.isEmpty {
            return last
        }
        return []
    }

    private var projectionSteps: [AppModel.ToolStep] {
        Array(model.messages.suffix(12).flatMap(\.steps).reversed())
    }

    var body: some View {
        VStack(spacing: 14) {
            ProjectionStack(steps: projectionSteps)
            sourcesPanel
            Spacer(minLength: 0)
            taskPanel
        }
    }

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Text("资料")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("\(latestSteps.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Spacer()
            }

            if latestSteps.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(height: 120)
                    .overlay {
                        Text("本轮暂无工具回执")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary.opacity(0.65))
                    }
            } else {
                VStack(spacing: 8) {
                    ForEach(latestSteps.prefix(5)) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                                    .frame(width: 4, height: 4)
                                Text(step.name)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.panelBorder, lineWidth: 0.6)
                        )
                    }
                }
            }
        }
        .panel()
    }

    private var finishedTaskCount: Int {
        model.messages.filter { !$0.steps.isEmpty }.count
    }

    private var sessionLabel: String {
        if let id = model.currentSessionID,
           let session = model.sessions.first(where: { $0.id == id }) {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "主会话" : String(title.prefix(12))
        }
        return "主会话"
    }

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("任务")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                Text(sessionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())

                Text("已结束 \(max(finishedTaskCount, model.recentTasks.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))

                Spacer()
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isSending {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("正在执行本轮对话")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        if !latestSteps.isEmpty {
                            ForEach(latestSteps.prefix(3)) { step in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(step.ok ? Theme.success : Color.orange.opacity(0.85))
                                        .frame(width: 5, height: 5)
                                    Text(step.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                            }
                        } else if !model.recentTasks.isEmpty {
                            ForEach(model.recentTasks.prefix(4)) { task in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(task.state == "completed" ? Theme.success : Color.orange.opacity(0.85))
                                        .frame(width: 5, height: 5)
                                    Text(task.title)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(task.state)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                }
                            }
                        } else if !model.isSending {
                            Text("暂无当前任务")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            Text("主会话 \(model.messages.count) 条消息")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                        }
                    }
                    .padding(12)
                }

            HStack(spacing: 14) {
                Button("工具列表") { showTools = true }
                Button("执行记录") { showTools = true }
                Button("连接") { model.settingsPresented = true }
                Spacer()
            }
            .font(.system(size: 10))
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.textSecondary)
        }
        .panel()
    }
}


// MARK: - Projections (tool-driven chrome)

struct ProjectionStack: View {
    let steps: [AppModel.ToolStep]

    private var music: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.music" || $0.name.hasSuffix(".music") })
    }
    private var application: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.application" || $0.name.contains(".application") })
    }
    private var screenshot: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.screen.capture" || $0.name.contains("screen.capture") })
    }

    private var hasAny: Bool { music != nil || application != nil || screenshot != nil }

    var body: some View {
        if hasAny {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    Text("投影")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                if let music { MusicProjectionCard(step: music) }
                if let application { AppsProjectionCard(step: application) }
                if let screenshot { ScreenshotProjectionCard(step: screenshot) }
            }
            .panel()
        }
    }
}

struct MusicProjectionCard: View {
    let step: AppModel.ToolStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("音乐")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(step.detail.isEmpty ? (step.ok ? "已执行播放控制" : "控制失败") : step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}

struct AppsProjectionCard: View {
    let step: AppModel.ToolStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("应用")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(step.detail.isEmpty ? step.name : step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}

struct ScreenshotProjectionCard: View {
    let step: AppModel.ToolStep

    private var imagePath: String? {
        let tokens = step.detail.split(whereSeparator: { $0.isWhitespace || ",{}".contains($0) }).map(String.init)
        if let hit = tokens.first(where: { $0.hasPrefix("/") && $0.contains(".png") }) {
            return hit.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if let range = step.detail.range(of: #"/[^\\s\"']+\\.png"#, options: .regularExpression) {
            return String(step.detail[range])
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let path = imagePath, let ns = NSImage(contentsOfFile: path) {
                Image(nsImage: ns)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 40)
                    .clipped()
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.5))
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 40)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("截图")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(imagePath ?? (step.detail.isEmpty ? "已截屏" : step.detail))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}


// MARK: - Tool sheet

struct ToolCatalogSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("工具列表")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(model.tools.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("关闭") { dismiss() }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.tools) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            Text(tool.risk.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(tool.risk == "high" ? Color.red : Theme.textSecondary)
                                .frame(width: 38, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Text(tool.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 480, height: 460)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
