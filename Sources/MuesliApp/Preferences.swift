import Foundation
import MuesliSession
import MuesliSummarize
import Observation
import Security

/// The app's settings, saved in UserDefaults as they change. API keys live in
/// the Keychain instead (see `Keychain`).
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    // Recording
    var engine: Engine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    /// `nil` follows the system language.
    var localeIdentifier: String? { didSet { defaults.set(localeIdentifier, forKey: "locale") } }
    var useMicrophone: Bool { didSet { defaults.set(useMicrophone, forKey: "useMicrophone") } }
    /// Apps never captured when recording all system audio, comma-separated (e.g. "Music, Spotify").
    var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    var outputFolder: String { didSet { defaults.set(outputFolder, forKey: "outputFolder") } }
    var summarizeOnStop: Bool { didSet { defaults.set(summarizeOnStop, forKey: "summarizeOnStop") } }
    /// A soft sound when recording starts and stops.
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Offer "Record “<meeting>”" from Calendar, and use it as the title.
    var suggestFromCalendar: Bool { didSet { defaults.set(suggestFromCalendar, forKey: "suggestFromCalendar") } }

    // Summaries
    var backend: Backend { didSet { defaults.set(backend.rawValue, forKey: "backend") } }
    var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "anthropicModel") } }
    var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    var openAIContextTokens: Int { didSet { defaults.set(openAIContextTokens, forKey: "openAIContextTokens") } }

    // Whisper
    var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "whisperModel") } }
    /// Empty finds Python automatically.
    var pythonPath: String { didSet { defaults.set(pythonPath, forKey: "pythonPath") } }

    // Actions
    var remindersList: String { didSet { defaults.set(remindersList, forKey: "remindersList") } }
    var calendarName: String { didSet { defaults.set(calendarName, forKey: "calendarName") } }

    // Keys, mirrored from the Keychain so views can observe whether one is set.
    var anthropicKey: String { didSet { Keychain.set(anthropicKey, for: .anthropic) } }
    var openAIKey: String { didSet { Keychain.set(openAIKey, for: .openAI) } }

    init() {
        let d = UserDefaults.standard
        engine = d.string(forKey: "engine").flatMap(Engine.init(rawValue:)) ?? .apple
        localeIdentifier = d.string(forKey: "locale")
        useMicrophone = d.object(forKey: "useMicrophone") as? Bool ?? true
        excludedApps = d.string(forKey: "excludedApps") ?? ""
        outputFolder = d.string(forKey: "outputFolder") ?? SessionFolder.defaultRoot.path
        summarizeOnStop = d.object(forKey: "summarizeOnStop") as? Bool ?? true
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        suggestFromCalendar = d.bool(forKey: "suggestFromCalendar")
        backend = d.string(forKey: "backend").flatMap(Backend.init(rawValue:)) ?? Backend.automatic() ?? .apple
        anthropicModel = d.string(forKey: "anthropicModel") ?? AnthropicGenerator.defaultModel
        openAIBaseURL = d.string(forKey: "openAIBaseURL") ?? "http://localhost:11434/v1"
        openAIModel = d.string(forKey: "openAIModel") ?? ""
        openAIContextTokens = d.object(forKey: "openAIContextTokens") as? Int ?? 8192
        whisperModel = d.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-mlx"
        pythonPath = d.string(forKey: "pythonPath") ?? ""
        remindersList = d.string(forKey: "remindersList") ?? ""
        calendarName = d.string(forKey: "calendarName") ?? ""
        anthropicKey = Keychain.get(.anthropic) ?? ""
        openAIKey = Keychain.get(.openAI) ?? ""
    }

    var outputRoot: URL { URL(fileURLWithPath: (outputFolder as NSString).expandingTildeInPath, isDirectory: true) }

    var locale: Locale { localeIdentifier.map(Locale.init(identifier:)) ?? .current }

    /// A GUI app doesn't see the shell's environment, so keys come from the Keychain.
    static let openAIKeyVariable = "MUESLI_OPENAI_API_KEY"

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if !anthropicKey.isEmpty { env[AnthropicGenerator.apiKeyEnvironmentVariable] = anthropicKey }
        if !openAIKey.isEmpty { env[Self.openAIKeyVariable] = openAIKey }
        return env
    }

    var backendConfiguration: BackendConfiguration {
        switch backend {
        case .apple, .appleCloud:
            return BackendConfiguration(backend: backend)
        case .anthropic:
            return BackendConfiguration(backend: .anthropic, model: anthropicModel.isEmpty ? nil : anthropicModel)
        case .openai:
            return BackendConfiguration(
                backend: .openai, model: openAIModel.isEmpty ? nil : openAIModel, baseURL: URL(string: openAIBaseURL),
                apiKeyEnvironmentVariable: openAIKey.isEmpty ? nil : Self.openAIKeyVariable, contextTokens: openAIContextTokens)
        }
    }

    /// Why the chosen summarizer can't be used as configured, or `nil` if it looks ready.
    var backendProblem: String? {
        switch backend {
        case .apple: AppleGenerator.unavailableReason(.onDevice)
        case .appleCloud: AppleGenerator.unavailableReason(.privateCloud)
        case .anthropic: anthropicKey.isEmpty ? "Claude needs an API key" : nil
        case .openai:
            URL(string: openAIBaseURL)?.host() == nil ? "needs a server URL" : openAIModel.isEmpty ? "needs a model name" : nil
        }
    }
}

extension Backend {
    var menuName: String {
        switch self {
        case .apple: "Apple (on-device)"
        case .appleCloud: "Apple (Private Cloud Compute)"
        case .anthropic: "Claude"
        case .openai: "OpenAI-compatible server"
        }
    }
}

/// Generic-password items for API keys.
enum Keychain {
    enum Item: String {
        case anthropic = "anthropic-api-key"
        case openAI = "openai-api-key"
    }

    private static let service = "dev.muesli.app"

    static func get(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
