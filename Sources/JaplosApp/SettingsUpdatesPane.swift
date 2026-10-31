import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct UpdatesSettingsPane: View {
    @ObservedObject var updates: UpdateService
    @ObservedObject var model: AppModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "在线更新", subtitle: "查看当前版本、检查更新与了解新版功能", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    currentCard
                    // Only show when a newer build exists. Hiding the card when
                    // already up to date avoids a fake "最新版本 0.5.3" row.
                    if updates.updateAvailable, let latest = updates.latestVersion {
                        latestCard(latest)
                    }
                    automaticCard
#if DEBUG
                    storeHealthCard
#endif
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task {
            updates.refresh()
            await updates.refreshFeed()
#if DEBUG
            await model.loadStoreStats()
#endif
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("当前版本")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(updates.version)
                    .font(.system(size: SettingsMetrics.metricSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Rectangle()
                .fill(Theme.panelBorder)
                .frame(height: 0.8)

            HStack(spacing: 12) {
                statusLabel
                Spacer()
                Button {
                    updates.checkForUpdates()
                    Task { await updates.refreshFeed() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: SettingsMetrics.microSize))
                        Text("检查更新")
                            .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                    }
                    .foregroundStyle(updates.updateAvailable ? Color.black.opacity(0.88) : Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(updates.updateAvailable ? Theme.accent : Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!updates.isAvailable)
                .opacity(updates.isAvailable ? 1 : 0.45)
            }

            Text("上次检查：\(lastCheckText)")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !updates.isAvailable {
            Text(updates.unavailableReason)
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.textSecondary)
        } else if updates.updateAvailable, let latest = updates.latestVersion {
            Label("发现新版本 \(latest)", systemImage: "arrow.down.circle.fill")
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.accent)
        } else if updates.isCheckingFeed {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检查…")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Label("当前已是最新版本", systemImage: "checkmark.circle.fill")
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.success)
        }
    }

    private func latestCard(_ latest: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("最新版本 \(latest)")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if updates.updateAvailable {
                    Label("可更新", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.accent)
                }
            }

            Text("新版功能与改进")
                .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text(updates.releaseNotes ?? "此版本暂未提供更新说明。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var automaticCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("自动更新")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("启动后定期检查新版本")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            Toggle(isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动检查更新")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textPrimary)
                    Text("发现新版本时会提示，确认后下载并安装。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!updates.isAvailable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

#if DEBUG
    private var storeHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("内核存储 / 自愈")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(model.storeTableCounts.count) 张表")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let event = model.lastSelfHealingEvent {
                Text("最近事件：\(event.kind) · \(Self.dateFormatter.string(from: event.createdAt))")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textPrimary)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            } else {
                Text("尚无自愈事件（daemon 启动后会出现 boot）")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
            }

            if !model.storeTableCounts.isEmpty {
                let nonempty = model.storeTableCounts.filter { $0.count > 0 }
                let preview = nonempty.prefix(8)
                Text(preview.map { "\($0.name)=\($0.count)" }.joined(separator: " · "))
                    .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if nonempty.count > preview.count {
                    Text("另有 \(nonempty.count - preview.count) 张非空表…")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Button {
                Task { await model.loadStoreStats() }
            } label: {
                Label("刷新统计", systemImage: "arrow.clockwise")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

#endif

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "尚未检查" }
        return Self.dateFormatter.string(from: date)
    }
}

// MARK: - Voice settings
