import Foundation

/// Lucas first-run prefs, shaped like Japlos `japlos.onboarding.*` / `japlos.awakening.*`
/// but namespaced under `lucas.*` so we never collide with a real Japlos install.
enum OnboardingPrefs {
    static let activationKey = "lucas.onboarding.activation.v1"
    static let riskKey = "lucas.onboarding.risk.v1"
    static let explorationKey = "lucas.onboarding.exploration.v1"
    static let encounterKey = "lucas.onboarding.encounter.v1"
    static let encounterIDKey = "lucas.onboarding.encounterID.v1"
    static let macOSBranchKey = "lucas.onboarding.macos.v1"

    static let awakeningInFlightKey = "lucas.awakening.inFlight.v1"
    static let awakeningNextStageKey = "lucas.awakening.nextStage.v1"
    static let awakeningSequenceKey = "lucas.awakening.sequence"
    static let awakeningToneKey = "lucas.awakening.tone.v1"

    static let tones = ["soft", "pulse", "orbital", "neon", "guidance"]

    static var activationDone: Bool {
        get { UserDefaults.standard.bool(forKey: activationKey) }
        set { UserDefaults.standard.set(newValue, forKey: activationKey) }
    }

    static var riskAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: riskKey) }
        set { UserDefaults.standard.set(newValue, forKey: riskKey) }
    }

    static var explorationDone: Bool {
        get { UserDefaults.standard.bool(forKey: explorationKey) }
        set { UserDefaults.standard.set(newValue, forKey: explorationKey) }
    }

    static var encounterDone: Bool {
        get { UserDefaults.standard.bool(forKey: encounterKey) }
        set { UserDefaults.standard.set(newValue, forKey: encounterKey) }
    }

    static var macOSBranchDone: Bool {
        get { UserDefaults.standard.bool(forKey: macOSBranchKey) }
        set { UserDefaults.standard.set(newValue, forKey: macOSBranchKey) }
    }

    static var tone: String {
        get {
            let value = UserDefaults.standard.string(forKey: awakeningToneKey) ?? "soft"
            return tones.contains(value) ? value : "soft"
        }
        set { UserDefaults.standard.set(newValue, forKey: awakeningToneKey) }
    }

    static var nextStage: Int {
        get { UserDefaults.standard.integer(forKey: awakeningNextStageKey) }
        set { UserDefaults.standard.set(newValue, forKey: awakeningNextStageKey) }
    }

    /// Mark the full first-run pass complete (mirrors Japlos activation + risk + encounter).
    static func markCompleted(sequence: Int = 1) {
        activationDone = true
        riskAccepted = true
        explorationDone = true
        encounterDone = true
        macOSBranchDone = true
        UserDefaults.standard.set(false, forKey: awakeningInFlightKey)
        UserDefaults.standard.set(sequence, forKey: awakeningSequenceKey)
        if nextStage < 5 { nextStage = 5 }
        if UserDefaults.standard.string(forKey: encounterIDKey) == nil {
            UserDefaults.standard.set(UUID().uuidString, forKey: encounterIDKey)
        }
    }

    static func markSkipped() {
        activationDone = true
        UserDefaults.standard.set(false, forKey: awakeningInFlightKey)
        if nextStage < 1 { nextStage = 1 }
    }

    static func reset() {
        for key in [
            activationKey, riskKey, explorationKey, encounterKey, encounterIDKey,
            macOSBranchKey, awakeningInFlightKey, awakeningNextStageKey,
            awakeningSequenceKey, awakeningToneKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
