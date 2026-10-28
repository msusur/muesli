import AVFoundation
import Foundation
import MuesliAudio
import MuesliCore
import MuesliSummarize
import MuesliTranscribe
import Speech

/// One line of `muesli doctor`, or one row of the app's Check Setup window.
public struct SetupCheck: Sendable, Identifiable, Equatable {
    public enum Status: Sendable, Equatable {
        case ok
        /// Fine for now, e.g. a permission that will be asked for on first use.
        case info
        case problem
    }

    public enum Section: String, Sendable, CaseIterable {
        case speech = "Speech"
        case permissions = "Permissions"
        case whisper = "Whisper (optional engine for more languages)"
        case summarizers = "Summarizers"
        case audio = "Audio"
    }

    public var id: String { "\(section.rawValue)/\(title)" }
    public var section: Section
    public var title: String
    public var detail: String
    public var status: Status
    /// The System Settings pane that fixes it, if any.
    public var settingsURL: URL?
}

public enum SetupChecks {
    /// Privacy & Security panes, for "Open System Settings" buttons.
    public enum Pane: String {
        case microphone = "Privacy_Microphone"
        case systemAudio = "Privacy_AudioCapture"

        public var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
    }

    /// - Parameters:
    ///   - grantee: Who permissions are granted to, for instructions: "your terminal" or "Muesli".
    ///   - environment: Where API keys are looked up.
    public static func run(
        grantee: String, environment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current, whisper: WhisperConfiguration = WhisperConfiguration()
    ) async -> [SetupCheck] {
        var checks: [SetupCheck] = []
        func add(_ section: SetupCheck.Section, _ title: String, _ detail: String, _ status: SetupCheck.Status, _ pane: Pane? = nil) {
            checks.append(SetupCheck(section: section, title: title, detail: detail, status: status, settingsURL: pane?.url))
        }

        // Speech
        let available = SpeechTranscriber.isAvailable
        add(.speech, "On-device transcription", available ? "available" : "not available on this Mac", available ? .ok : .problem)
        if available {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                let status = await AssetInventory.status(forModules: [module])
                // Not installed isn't a failure: the model downloads on first use.
                add(.speech, "Speech model for \(supported.identifier)",
                    status == .installed ? "installed" : "\(status) (downloads automatically on first use)",
                    status == .installed ? .ok : .info)
            } else {
                add(.speech, "Language", "\(locale.identifier) isn't supported by Apple's recognizer; choose another, or use Whisper", .problem)
            }
        }

        // Microphone
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        switch mic {
        case .authorized: add(.permissions, "Microphone", "granted", .ok)
        case .notDetermined: add(.permissions, "Microphone", "not asked yet (you'll be asked before your first recording)", .info)
        case .denied: add(.permissions, "Microphone", "denied. Allow \(grantee) in System Settings → Privacy & Security → Microphone", .problem, .microphone)
        case .restricted: add(.permissions, "Microphone", "restricted by policy", .problem)
        @unknown default: add(.permissions, "Microphone", "unknown", .info)
        }

        // System audio: there's no API to read this permission, only to see its effect.
        add(.permissions, "System Audio Recording",
            "can't be checked ahead of time. If “Them” stays silent while a call is playing, allow \(grantee) in System Settings → Privacy & Security → Screen & System Audio Recording",
            .info, .systemAudio)

        // Whisper
        if let python = try? WhisperTranscriber(configuration: whisper).resolvePython() {
            add(.whisper, "mlx-whisper", "found (\(python))", .ok)
            let cached = WhisperTranscriber.isModelCached(whisper.model)
            add(.whisper, whisper.model, cached ? "downloaded" : "not downloaded yet (about 3 GB on first use)", cached ? .ok : .info)
        } else {
            add(.whisper, "mlx-whisper", "not found. To enable: python3 -m pip install mlx-whisper", .info)
        }

        // Summarizers
        for kind in [AppleGenerator.Kind.onDevice, .privateCloud] {
            let name = kind == .onDevice ? "Apple (on-device)" : "Apple (Private Cloud Compute)"
            if let reason = AppleGenerator.unavailableReason(kind) {
                add(.summarizers, name, reason, .problem)
            } else {
                let context = await AppleGenerator(kind: kind).contextTokens().map { "\($0) token context" } ?? "available"
                add(.summarizers, name, context, .ok)
            }
        }
        let hasKey = !(environment[AnthropicGenerator.apiKeyEnvironmentVariable] ?? "").isEmpty
        add(.summarizers, "Claude", hasKey ? "API key set; default model \(AnthropicGenerator.defaultModel)" : "no API key set", hasKey ? .ok : .info)

        // System audio device
        do {
            let uid = try SystemAudioCapture.defaultOutputDeviceUID()
            add(.audio, "Default output device", uid, .ok)
            let probe = SystemAudioCapture()
            _ = try probe.start()
            probe.stop()
            add(.audio, "System-audio tap", "can be created", .ok)
        } catch {
            add(.audio, "System-audio tap", error.localizedDescription, .problem, .systemAudio)
        }
        return checks
    }
}
