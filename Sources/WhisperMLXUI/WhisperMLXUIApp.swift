import SwiftUI
import AppKit
import Security
import Sparkle

/// Coordinates a graceful shutdown: an in-progress recording is finalized and
/// a running transcription helper is terminated before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: TranscriptionController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = Self.controller, controller.isBusy else { return .terminateNow }
        Task { @MainActor in
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct WhisperMLXUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller: TranscriptionController
    private let updaterController: SPUStandardUpdaterController

    init() {
        let controller = TranscriptionController()
        _controller = State(initialValue: controller)
        AppDelegate.controller = controller
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Sparkle recommends forcing launch checks immediately after startup,
        // before its scheduled update cycle begins. Respect the user's opt-out.
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    var body: some Scene {
        WindowGroup("WhisperMLX UI") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 820, height: 450)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
        Settings { SettingsView(controller: controller) }
    }
}

enum TokenStore {
    static let service = "local.whispermlx.ui"
    static let account = "huggingface-token"

    /// Checks for the Keychain item without requesting its secret value. This
    /// lets the interface choose a sensible default without showing a Keychain
    /// prompt at launch.
    static func exists() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String {
        loadWithStatus().token
    }

    static func loadWithStatus() -> (token: String, status: OSStatus) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return ("", status) }
        return (String(decoding: data, as: UTF8.self), status)
    }

    static func save(_ token: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
        let value: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(token.utf8)
        ]
        return SecItemAdd(value as CFDictionary, nil)
    }
}

enum LocalDiarizationModelStore {
    private static let key = "local-pyannote-model-path"

    static func defaultPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/models/speaker-diarization-community-1", isDirectory: true).path
    }

    static func load() -> String {
        // Old user-specific download paths must not override the bundled model.
        defaultPath()
    }

    static func save(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty {
            UserDefaults.standard.set(defaultPath(), forKey: key)
        } else {
            UserDefaults.standard.set(trimmedPath, forKey: key)
        }
    }
}

enum TranscriptionLanguageStore {
    private static let key = "transcription-language"

    static func load() -> TranscriptionController.TranscriptionLanguage {
        guard
            let rawValue = UserDefaults.standard.string(forKey: key),
            let value = TranscriptionController.TranscriptionLanguage(rawValue: rawValue)
        else {
            return .german
        }
        return value
    }

    static func save(_ language: TranscriptionController.TranscriptionLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
    }
}

struct SettingsView: View {
    @Bindable var controller: TranscriptionController
    @Environment(\.dismiss) private var dismiss
    @State private var section: SettingsSection = .transcription
    @State private var model: TranscriptionController.Model = .largeV3
    @State private var vadMethod: TranscriptionController.VADMethod = .pyannote
    @State private var transcriptionLanguage: TranscriptionController.TranscriptionLanguage = .german
    @State private var diarizationEnabled = true
    @State private var speakerCount: Int?
    @State private var localDiarizationModelPath = ""
    @State private var modelManager = ModelManager()
    @State private var diarizationModelManager = DiarizationModelManager()
    @State private var modelToRemove: TranscriptionController.Model?
    @State private var microphoneDevices: [AudioInputDevice] = []
    @State private var preferredMicrophoneUID: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("settings.title")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("action.cancel") { dismiss() }
                Button("action.apply") { apply() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                List(SettingsSection.allCases, selection: $section) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .listStyle(.sidebar)
                .frame(width: 175)
                Divider()
                Group {
                    switch section {
                    case .transcription: transcriptionSettings
                    case .models: modelSettings
                    case .diarization: diarizationSettings
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 760, height: 500)
        .onAppear { resetDraft() }
    }

    private var transcriptionSettings: some View {
        Form {
            Section("transcription.section") {
                if installedModels.isEmpty {
                    Text("settings.models.noneInstalled")
                        .foregroundStyle(.secondary)
                    Text("settings.models.noneInstalled.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("model.label", selection: $model) {
                        ForEach(installedModels) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Text("settings.transcription.description")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Picker("settings.vad.title", selection: $vadMethod) {
                    ForEach(TranscriptionController.VADMethod.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Text("settings.vad.description")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("transcription.language.label", selection: $transcriptionLanguage) {
                    ForEach(TranscriptionController.TranscriptionLanguage.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Text("transcription.language.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var diarizationSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("diarization.label")
                    .font(.title3.weight(.semibold))
                Text("settings.diarization.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("diarization.usePyannote", isOn: $diarizationEnabled)
                        if diarizationEnabled {
                            Picker("speakerCount.label", selection: $speakerCount) {
                                Text("speakerCount.automatic").tag(Int?.none)
                                ForEach(2...6, id: \.self) { count in
                                    Text(String.localizedStringWithFormat(String(localized: "speakerCount.people"), count))
                                        .tag(Int?.some(count))
                                }
                            }
                        }

                        Divider()
                        Text("settings.diarization.offline.title")
                            .font(.headline)
                        Text("settings.diarization.offline.description")
                            .font(.caption).foregroundStyle(.secondary)
                        if diarizationModelManager.status != .ready {
                            Label("error.diarizationModelPathInvalid", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if let errorMessage = diarizationModelManager.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Link("settings.diarization.modelLicense", destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!)
                    }
                }
            }
            .padding(24)
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("settings.models.tab").font(.title3.weight(.semibold))
            Text("settings.models.description").font(.caption).foregroundStyle(.secondary)
            ForEach(TranscriptionController.Model.allCases) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).fontWeight(.medium)
                        Text(item.repository).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if modelManager.downloading == item {
                        ProgressView().controlSize(.small)
                    } else if modelManager.isInstalled(item) {
                        HStack(spacing: 12) {
                            Label("settings.model.installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("settings.model.remove", role: .destructive) {
                                modelToRemove = item
                            }
                        }
                    } else {
                        Button("settings.model.download") { modelManager.download(item) }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let errorMessage = modelManager.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .confirmationDialog(
            "settings.model.remove.confirmation.title",
            isPresented: Binding(
                get: { modelToRemove != nil },
                set: { if !$0 { modelToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("settings.model.remove", role: .destructive) {
                if let modelToRemove { modelManager.remove(modelToRemove) }
                modelToRemove = nil
            }
            Button("action.cancel", role: .cancel) { modelToRemove = nil }
        } message: {
            Text("settings.model.remove.confirmation.message")
        }
    }

    private func resetDraft() {
        model = installedModels.contains(controller.model) ? controller.model : (installedModels.first ?? controller.model)
        vadMethod = controller.vadMethod
        transcriptionLanguage = controller.transcriptionLanguage
        diarizationEnabled = controller.diarizationEnabled
        speakerCount = controller.speakerCount
        microphoneDevices = AudioInputDeviceManager.availableDevices()
        preferredMicrophoneUID = controller.preferredMicrophoneUID ?? ""
        if !preferredMicrophoneUID.isEmpty && !microphoneDevices.contains(where: { $0.id == preferredMicrophoneUID }) {
            preferredMicrophoneUID = ""
        }
        localDiarizationModelPath = controller.diarizationModelPath.isEmpty ? LocalDiarizationModelStore.load() : controller.diarizationModelPath
        diarizationModelManager.refresh(configuredPath: localDiarizationModelPath)
    }

    private var installedModels: [TranscriptionController.Model] {
        _ = modelManager.cacheRevision
        return TranscriptionController.Model.allCases.filter { modelManager.isInstalled($0) }
    }

    private func apply() {
        let newLocalPath = localDiarizationModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        diarizationModelManager.refresh(configuredPath: newLocalPath)
        let hasOfflineModel = diarizationModelManager.status == .ready
        controller.model = model
        controller.vadMethod = vadMethod
        controller.transcriptionLanguage = transcriptionLanguage
        controller.diarizationEnabled = diarizationEnabled && hasOfflineModel
        controller.diarizationModelPath = newLocalPath
        controller.speakerCount = speakerCount
        controller.preferredMicrophoneUID = preferredMicrophoneUID.isEmpty ? nil : preferredMicrophoneUID
        controller.recorder.preferredMicrophoneUID = controller.preferredMicrophoneUID
        LocalDiarizationModelStore.save(newLocalPath)
        TranscriptionLanguageStore.save(transcriptionLanguage)
        AudioInputDeviceStore.save(controller.preferredMicrophoneUID)
        dismiss()
    }

}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case transcription, models, diarization
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .transcription: "transcription.section"
        case .models: "settings.models.tab"
        case .diarization: "diarization.label"
        }
    }
    var icon: String {
        switch self {
        case .transcription: "waveform"
        case .models: "cpu"
        case .diarization: "person.2"
        }
    }
}
