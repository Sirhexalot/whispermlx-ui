import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    private static let microphoneLevelColor = Color(
        red: 121 / 255,
        green: 191 / 255,
        blue: 67 / 255
    )

    @Bindable var controller: TranscriptionController
    @ObservedObject private var recorder: AudioRecorder
    @State private var isImporting = false
    @State private var showsDetails = false
    @State private var showsSettings = false
    @State private var microphoneDevices: [AudioInputDevice] = []
    @State private var preferredMicrophoneUID: String = ""

    init(controller: TranscriptionController) {
        self.controller = controller
        _recorder = ObservedObject(wrappedValue: controller.recorder)
    }

    var body: some View {
        Group {
            if recorder.isRecording || recorder.isFinalizingRecording {
                compactRecordingView
                    .frame(width: 480, height: 260)
            } else {
                fullView
                    .frame(minWidth: 720, minHeight: 420, alignment: .topLeading)
            }
        }
        .background(WindowSizeConfigurator(isCompact: recorder.isRecording))
        .sheet(isPresented: $showsSettings) {
            SettingsView(controller: controller)
        }
        .task {
            refreshMicrophones()
            await recorder.preparePreviewMonitoring()
        }
    }

    private var fullView: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            recordingControls
            fileSelection
            controls
        }
        .padding(28)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                controller.selectFile(url)
            }
        }
    }

    private var compactRecordingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if recorder.isFinalizingRecording {
                    Label("recording.finalizing", systemImage: "waveform.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Label("recording.compact.title", systemImage: "record.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                if !recorder.isFinalizingRecording {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "recording.running"),
                            Self.formattedDuration(recorder.elapsed)
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                audioLevel(label: "recording.level.microphone", value: recorder.level, tint: Self.microphoneLevelColor)
                audioLevel(label: "recording.level.systemAudio", value: recorder.systemLevel, tint: .blue)
            }

            Spacer()
            HStack {
                Text(recorder.isFinalizingRecording ? "recording.finalizing.hint" : "recording.compact.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !recorder.isFinalizingRecording {
                    Button("recording.stop") { controller.stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(24)
    }

    private var recordingControls: some View {
        GroupBox("recording.section") {
            VStack(alignment: .leading, spacing: 14) {
                if recorder.isRecording {
                    HStack {
                        Label(
                            String.localizedStringWithFormat(
                                String(localized: "recording.running"),
                                Self.formattedDuration(recorder.elapsed)
                            ),
                            systemImage: "record.circle.fill"
                        )
                            .foregroundStyle(.red)
                        Spacer()
                        Button("recording.stop") { controller.stopRecording() }
                            .buttonStyle(.borderedProminent)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        audioLevel(label: "recording.level.microphone", value: recorder.level, tint: Self.microphoneLevelColor)
                        audioLevel(label: "recording.level.systemAudio", value: recorder.systemLevel, tint: .blue)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        audioLevel(label: "recording.level.microphone", value: recorder.level, tint: Self.microphoneLevelColor)
                        audioLevel(label: "recording.level.systemAudio", value: recorder.systemLevel, tint: .blue)
                    }

                    HStack(alignment: .center, spacing: 14) {
                        Picker("settings.microphone.title", selection: $preferredMicrophoneUID) {
                            Text("settings.microphone.systemDefault").tag("")
                            ForEach(microphoneDevices) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 260, alignment: .leading)
                        .labelsHidden()
                        .help("settings.microphone.title")
                        .onChange(of: preferredMicrophoneUID) { _, newValue in
                            applyPreferredMicrophone(newValue)
                        }

                        Spacer()

                        Button("recording.start") { controller.startRecording() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isRunning || recorder.isFinalizingRecording)
                    }
                }
            }
            .padding(8)
        }
    }

    private func audioLevel(label: LocalizedStringKey, value: Float, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            ProgressView(value: Double(value), total: 1)
                .tint(tint)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Label("WhisperMLX UI", systemImage: "waveform.badge.mic")
                    .font(.system(size: 28, weight: .bold))
                Text("app.subtitle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .help("settings.open")
        }
    }

    private var fileSelection: some View {
        GroupBox("file.section") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.inputURL?.lastPathComponent ?? String(localized: "file.noneSelected"))
                            .fontWeight(controller.inputURL == nil ? .regular : .semibold)
                        if let outputURL = controller.outputURL {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "file.output"),
                                    outputURL.lastPathComponent
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("file.choose") { isImporting = true }
                        .disabled(controller.isRunning || recorder.isFinalizingRecording)
                }

                if case .ready = controller.status {
                    HStack {
                        Spacer()
                        Button("action.transcribe") { controller.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!controller.canStart || recorder.isFinalizingRecording)
                    }
                }
            }
            .padding(8)
        }
    }

    private var controls: some View {
        HStack {
            switch controller.status {
            case .running:
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = controller.progress {
                        HStack(spacing: 8) {
                            ProgressView(value: progress, total: 100)
                                .frame(width: 220)
                            Text(verbatim: "\(Int(progress.rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 34, alignment: .trailing)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("transcription.running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("details.section") { showsDetails = true }
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                        detailsPopover
                    }
                Button("action.cancel", role: .destructive) { controller.cancel() }
            case let .succeeded(outputURL):
                Label(
                    String.localizedStringWithFormat(
                        String(localized: "transcription.finished"),
                        outputURL.lastPathComponent
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                    .foregroundStyle(.green)
                Spacer()
                Button("action.openFolder") {
                    NSWorkspace.shared.open(outputURL)
                }
                Button("action.transcribeAgain") { controller.start() }
                    .disabled(!controller.canStart)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("settings.open") { showsSettings = true }
                Button("action.retry") { controller.start() }
                    .disabled(!controller.canStart)
            case .cancelled:
                Text("transcription.cancelled")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("action.retry") { controller.start() }
                    .disabled(!controller.canStart)
            case .ready:
                EmptyView()
            }
        }
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("details.section", systemImage: "text.alignleft")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("action.close") { showsDetails = false }
            }
            ScrollView {
                Text(controller.log.isEmpty ? String(localized: "details.emptyLog") : controller.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(width: 620, height: 360)
    }

    private func refreshMicrophones() {
        microphoneDevices = AudioInputDeviceManager.availableDevices()
        preferredMicrophoneUID = controller.preferredMicrophoneUID ?? ""
        if !preferredMicrophoneUID.isEmpty && !microphoneDevices.contains(where: { $0.id == preferredMicrophoneUID }) {
            preferredMicrophoneUID = ""
            applyPreferredMicrophone("")
        }
    }

    private func applyPreferredMicrophone(_ uid: String) {
        let resolvedUID = uid.isEmpty ? nil : uid
        controller.preferredMicrophoneUID = resolvedUID
        controller.recorder.preferredMicrophoneUID = resolvedUID
        AudioInputDeviceStore.save(resolvedUID)
        Task {
            await controller.recorder.refreshPreviewMonitoring()
        }
    }

    private static func formattedDuration(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

/// Adjusts the native window when the recording-only interface is shown and
/// restores the previous window size afterwards.
private struct WindowSizeConfigurator: NSViewRepresentable {
    let isCompact: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.apply(isCompact: isCompact, to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply(isCompact: isCompact, to: view.window) }
    }

    final class Coordinator {
        private var regularSize: NSSize?
        private var isCurrentlyCompact = false
        private var hasConfiguredInitialSize = false

        func apply(isCompact: Bool, to window: NSWindow?) {
            guard let window else { return }

            if !hasConfiguredInitialSize, !isCompact {
                window.minSize = NSSize(width: 720, height: 420)
                let currentSize = window.contentLayoutRect.size
                if currentSize.width > 900 || currentSize.height > 540 {
                    window.setContentSize(NSSize(width: 820, height: 450))
                }
                hasConfiguredInitialSize = true
                return
            }

            guard isCompact != isCurrentlyCompact else { return }

            if isCompact {
                regularSize = window.contentLayoutRect.size
                window.minSize = NSSize(width: 480, height: 260)
                window.setContentSize(NSSize(width: 480, height: 260))
            } else {
                window.minSize = NSSize(width: 720, height: 420)
                if let regularSize {
                    window.setContentSize(regularSize)
                }
            }
            isCurrentlyCompact = isCompact
        }
    }
}

#Preview {
    ContentView(controller: TranscriptionController())
        .frame(width: 780, height: 620)
}
