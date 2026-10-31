import Foundation

/// Doubao / OpenSpeech realtime dialogue O·O2.0 精品音色（`tts.speaker`）。
/// 与官方文档一致；设置页按男女分组点选，不要求用户手填 ID。
public enum DoubaoVoicePresets {
    public static let defaultSpeaker = "zh_female_vv_jupiter_bigtts"

    public struct Preset: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let gender: Gender
        public enum Gender: String, Sendable { case female, male }

        public init(id: String, label: String, gender: Gender) {
            self.id = id
            self.label = label
            self.gender = gender
        }
    }

    public static let all: [Preset] = [
        .init(id: "zh_female_vv_jupiter_bigtts", label: "vv · 活泼灵动女声", gender: .female),
        .init(id: "zh_female_xiaohe_jupiter_bigtts", label: "小何 · 甜美活泼女声", gender: .female),
        .init(id: "zh_male_yunzhou_jupiter_bigtts", label: "云舟 · 清爽沉稳男声", gender: .male),
        .init(id: "zh_male_xiaotian_jupiter_bigtts", label: "小天 · 清爽磁性男声", gender: .male),
    ]

    public static var females: [Preset] { all.filter { $0.gender == .female } }
    public static var males: [Preset] { all.filter { $0.gender == .male } }

    public static func label(for id: String) -> String {
        if let hit = all.first(where: { $0.id == id }) {
            return hit.label
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? label(for: defaultSpeaker) : trimmed
    }

    public static func normalize(_ id: String?) -> String {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultSpeaker : trimmed
    }
}
