import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct AlarmsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var title = ""
    @State private var fireAt = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "提醒", subtitle: "本地闹钟列表（轻量端口，不含系统通知投递）", model: model)

            ScrollView {
                HStack(alignment: .top, spacing: SettingsMetrics.cardSpacing) {
                    // Left: create — compact date + time fields (popover calendar, no analog clock).
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "bell")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("新建提醒")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        HStack(spacing: 12) {
                            TextField("标题", text: $title)
                                .textFieldStyle(.plain)
                                .font(.system(size: SettingsMetrics.bodySize))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                                .frame(maxWidth: .infinity)
                            Button("添加") {
                                Task {
                                    await model.upsertAlarm(title: title, fireAt: fireAt)
                                    title = ""
                                    fireAt = Date().addingTimeInterval(3600)
                                }
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text("日期")
                                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
                                DatePicker("", selection: $fireAt, displayedComponents: [.date])
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .environment(\.locale, Locale.current)
                                Spacer(minLength: 0)
                            }
                            HStack(spacing: 10) {
                                Text("时间")
                                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
                                DatePicker("", selection: $fireAt, displayedComponents: [.hourAndMinute])
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .environment(\.locale, Locale.current)
                                Spacer(minLength: 0)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    // Right: saved list — equal width with create card.
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("已保存")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(model.alarms.count)")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if model.alarms.isEmpty {
                            Text("暂无提醒。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 0)
                        } else {
                            ForEach(model.alarms) { alarm in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(alarm.title)
                                            .font(.system(size: SettingsMetrics.labelSize))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(alarm.fireAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    Text(alarm.enabled ? "开" : "关")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.textSecondary)
                                    Button {
                                        Task { await model.deleteAlarm(id: alarm.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.pressable)
                                }
                                .padding(.vertical, 4)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task { await model.loadAlarms() }
    }
}

// MARK: - MCP settings
