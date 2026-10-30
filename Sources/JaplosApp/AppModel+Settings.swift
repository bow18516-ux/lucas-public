import Combine
import Foundation
import JaplosProtocol
import JaplosClient
import PDFKit
import AppKit

@MainActor
extension AppModel {
    // MARK: - Settings

    func presentOnboardingIfNeeded() {
        let forced = ProcessInfo.processInfo.environment["LUCAS_SHOW_ONBOARDING"] == "1"
        let completed = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        let skipped = UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
        if forced || (!completed && !skipped && !hasStoredConnection) {
            onboardingPresented = true
        }
    }

    func skipOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
        OnboardingPrefs.markSkipped()
        onboardingPresented = false
    }

    func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingCompletedKey)
        OnboardingPrefs.reset()
        settingsPresented = false
        onboardingPresented = true
    }

    func loadSettings() async {
        do {
            let result = try await client.callAsync(.configurationList, arguments: .object([:]))
            let entries = result.arrayValue ?? []
            guard
                let entry = entries.first(where: { $0["path"]?.stringValue == "agents.default.model.connection" }),
                let value = entry["value"]
            else { return }
            let data = try ProtocolCoding.encode(value)
            var decoded = try ProtocolCoding.decode(ModelConnection.self, from: data)
            let keyConfigured = value["apiKeyConfigured"]?.boolValue ?? !(value["apiKey"]?.stringValue ?? "").isEmpty
            storedAPIKey = keyConfigured ? "__stored__" : ""
            decoded.apiKey = ""
            settings = decoded
            hasStoredConnection = !decoded.model.isEmpty && !decoded.baseURL.isEmpty && keyConfigured
        } catch {
            errorText = String(describing: error)
        }
    }

    func saveSettings() async -> Bool {
        let key = settings.apiKey
        guard
            !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
            !settings.model.trimmingCharacters(in: .whitespaces).isEmpty,
            !key.isEmpty || !storedAPIKey.isEmpty
        else {
            errorText = "请填写 Base URL、模型和 API Key 后再保存"
            return false
        }
        do {
            let value = JSONValue.object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "apiKey": .string(key),
                "temperature": .number(settings.temperature),
                "displayName": .string(settings.displayName),
            ])
            _ = try await client.callAsync(.configurationSet, arguments: .object([
                "path": .string("agents.default.model.connection"),
                "value": value,
            ]))
            // Mirror into custom_model_routes so Settings can list provider history like Japlos.
            let routeID = Self.routeID(for: settings)
            let routeRecord = JSONValue.object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "temperature": .number(settings.temperature),
                "displayName": .string(settings.displayName.isEmpty ? providerHint(for: settings.baseURL) : settings.displayName),
                "protocol": .string("chat.completions"),
            ])
            _ = try? await client.callAsync(.modelRoutesSet, arguments: .object([
                "routeID": .string(routeID),
                "record": routeRecord,
            ]))
            storedAPIKey = "__stored__"
            settings.apiKey = ""
            hasStoredConnection = true
            return true
        } catch {
            errorText = String(describing: error)
            return false
        }
    }

    /// Persist TTS prefs into `speech_profiles` (kernel store). Volcengine
    /// credentials ride in the record and are redacted into SecretStore by the kernel.
    func syncSpeechProfile(from voice: SpeechOutput) async {
        let providerID = voice.provider.rawValue
        var record: [String: JSONValue] = [
            "provider": .string(providerID),
            "voiceIdentifier": .string(voice.voiceIdentifier),
            "languageCode": .string(voice.languageCode),
            "rate": .number(voice.rate),
            "pitch": .number(voice.pitch),
            "inputDeviceUID": .string(voice.inputDeviceUID),
            "tone": .string(OnboardingPrefs.tone),
            "volcengineVoiceType": .string(voice.volcengineVoiceType),
            "volcengineCluster": .string(voice.volcengineCluster),
        ]
        if !voice.volcengineAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record["volcengineAppID"] = .string(voice.volcengineAppID)
        }
        if !voice.volcengineToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record["volcengineToken"] = .string(voice.volcengineToken)
        }
        _ = try? await client.callAsync(.speechProfilesSet, arguments: .object([
            "profileID": .string("default"),
            "providerID": .string(providerID),
            "isDefault": .bool(true),
            "record": .object(record),
        ]))
        if !voice.volcengineToken.isEmpty {
            voice.volcengineToken = ""
            voice.markVolcengineConfigured(true)
        }
        await loadSpeechProfile()
    }

    func loadSpeechProfile() async {
        do {
            let result = try await client.callAsync(.speechProfilesList, arguments: .object([:]))
            guard let profile = (result.arrayValue ?? []).first(where: { $0["isDefault"]?.boolValue == true })
                    ?? result.arrayValue?.first else { return }
            let record = profile["record"] ?? .object([:])
            if let providerRaw = profile["providerID"]?.stringValue ?? record["provider"]?.stringValue,
               let provider = SpeechOutput.Provider(rawValue: providerRaw) {
                voice.provider = provider
            }
            if let voiceID = record["voiceIdentifier"]?.stringValue {
                voice.voiceIdentifier = voiceID
            }
            if let language = record["languageCode"]?.stringValue, !language.isEmpty {
                voice.languageCode = language
            }
            if let rate = record["rate"]?.doubleValue { voice.rate = rate }
            if let pitch = record["pitch"]?.doubleValue { voice.pitch = pitch }
            if let input = record["inputDeviceUID"]?.stringValue {
                voice.inputDeviceUID = input
            }
            if let vt = record["volcengineVoiceType"]?.stringValue, !vt.isEmpty {
                voice.volcengineVoiceType = vt
            }
            if let cluster = record["volcengineCluster"]?.stringValue, !cluster.isEmpty {
                voice.volcengineCluster = cluster
            }
            let configured = record["volcengineTokenConfigured"]?.boolValue == true
                && record["volcengineAppIDConfigured"]?.boolValue == true
            voice.markVolcengineConfigured(configured)
        } catch {
            // Offline: keep local UserDefaults prefs.
        }
    }

    func wireSpeechCloud() {
        voice.cloudSynthesize = { [weak self] text in
            guard let self else { return nil }
            do {
                let result = try await self.client.callAsync(
                    .speechSynthesize,
                    arguments: .object([
                        "text": .string(text),
                        "providerID": .string(self.voice.provider.rawValue),
                        "voiceType": .string(self.voice.volcengineVoiceType),
                        "cluster": .string(self.voice.volcengineCluster),
                    ]),
                    timeout: 45
                )
                if result["fallback"]?.boolValue == true {
                    let reason = result["reason"]?.stringValue ?? "fallback"
                    await MainActor.run { self.voice.noteCloudError(reason) }
                    AppLog.write("speech.synthesize fallback: \(reason)")
                    return nil
                }
                guard
                    let b64 = result["data"]?.stringValue,
                    let data = Data(base64Encoded: b64),
                    !data.isEmpty
                else {
                    await MainActor.run { self.voice.noteCloudError("empty_audio") }
                    return nil
                }
                let encoding = result["encoding"]?.stringValue ?? "mp3"
                return (data, encoding)
            } catch {
                await MainActor.run {
                    self.voice.noteCloudError((error as? ClientError)?.description ?? String(describing: error))
                }
                AppLog.write("speech.synthesize error: \(error)")
                return nil
            }
        }
    }

    func loadAlarms(limit: Int = 40) async {
        do {
            let result = try await client.callAsync(.alarmList, arguments: .object([
                "limit": .number(Double(limit)),
            ]))
            alarms = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let title = item["title"]?.stringValue ?? ""
                let fireAt = item["fireAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                let enabled = item["enabled"]?.boolValue ?? true
                return AlarmItem(id: id, title: title, fireAt: fireAt, enabled: enabled)
            }
        } catch {
            // Keep empty list when kernel offline.
        }
    }

    func upsertAlarm(title: String, fireAt: Date, enabled: Bool = true, id: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var args: [String: JSONValue] = [
                "title": .string(trimmed),
                "fireAt": .string(ISO8601.string(from: fireAt)),
                "enabled": .bool(enabled),
            ]
            if let id, !id.isEmpty { args["id"] = .string(id) }
            _ = try await client.callAsync(.alarmUpsert, arguments: .object(args))
            await loadAlarms()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func deleteAlarm(id: String) async {
        do {
            _ = try await client.callAsync(.alarmDelete, arguments: .object(["id": .string(id)]))
            await loadAlarms()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func listModelRoutes() async -> [JSONValue] {
        do {
            let result = try await client.callAsync(.modelRoutesList, arguments: .object([:]))
            return result.arrayValue ?? []
        } catch {
            return []
        }
    }

    private static func routeID(for settings: ModelConnection) -> String {
        let host = URL(string: settings.baseURL)?.host ?? "custom"
        let model = settings.model.replacingOccurrences(of: "/", with: "-")
        let raw = "\(host)/\(model)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
    }

    func providerHint(for baseURL: String) -> String {
        let url = baseURL.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.contains("xiaomimimo") { return "MiMo" }
        if url.contains("pollinations") { return "Pollinations" }
        if url.contains("openai.com") { return "OpenAI" }
        return "Custom"
    }

    func switchModel(_ id: String) async {
        guard id != settings.model else { return }
        settings.model = id
        guard hasStoredConnection else { return }
        _ = await saveSettings()
    }

    func testModel() async {
        isTestingModel = true
        testResult = nil
        defer { isTestingModel = false }
        do {
            let result = try await client.callAsync(.modelTest, arguments: .object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "apiKey": .string(settings.apiKey),
            ]), timeout: 60)
            if result["ok"]?.boolValue == true {
                let latency = Int(result["latencyMilliseconds"]?.doubleValue ?? 0)
                testResult = "连接成功 · \(latency) ms"
            } else {
                testResult = "失败：\(result["message"]?.stringValue ?? "未知错误")"
            }
        } catch {
            testResult = "失败：\((error as? ClientError)?.description ?? String(describing: error))"
        }
    }
}
