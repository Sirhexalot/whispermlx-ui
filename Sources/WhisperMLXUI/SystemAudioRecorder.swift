import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Captures the Mac's system audio independently of the microphone. Keeping the
/// tracks separate until recording stops makes the capture reliable and allows
/// us to mix both sources into one Whisper-ready file afterwards.
final class SystemAudioRecorder: NSObject, SCStreamOutput {
    private let writeQueue = DispatchQueue(label: "local.whispermlx.system-audio-write")
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var acceptingBuffers = false
    private var lastLevelUpdate = Date.distantPast
    var onLevel: ((Float) -> Void)?
    var isCapturing: Bool { stream != nil }

    func start(to outputURL: URL?) async throws {
        guard RecordingPermissions.ensureSystemAudioAccess() else {
            throw SystemAudioRecorderError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let error = error as NSError
            NSLog("WhisperMLX UI: ScreenCaptureKit initialization failed: \(error.domain) (\(error.code)) \(error.localizedDescription)")
            throw SystemAudioRecorderError.initializationFailed(error.localizedDescription)
        }

        // Audio is system-wide; the display only anchors ScreenCaptureKit's
        // stream. Prefer the user's primary display over enumeration order.
        let primaryDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == primaryDisplayID }) ?? content.displays.first else {
            throw SystemAudioRecorderError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // The stream must have a video surface, although we consume audio only.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.outputURL = outputURL
        acceptingBuffers = true
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        // A display-based SCStream also emits screen frames. Register an output
        // for them even though this recorder intentionally ignores the frames;
        // otherwise ScreenCaptureKit repeatedly reports a missing output.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        do {
            try await newStream.startCapture()
            stream = newStream
        } catch {
            acceptingBuffers = false
            self.outputURL = nil
            throw error
        }
    }

    func stop() async {
        acceptingBuffers = false
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        writeQueue.sync {
            audioFile = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, acceptingBuffers,
              let buffer = sampleBuffer.asPCMBuffer() else { return }

        updateLevel(from: buffer)

        guard let outputURL,
              let copy = buffer.deepCopy() else { return }

        writeQueue.async { [weak self] in
            guard let self, self.acceptingBuffers else { return }
            do {
                if self.audioFile == nil {
                    self.audioFile = try AVAudioFile(forWriting: outputURL, settings: copy.format.settings)
                }
                try self.audioFile?.write(from: copy)
            } catch {
                NSLog("WhisperMLX UI: could not write system audio: \(error.localizedDescription)")
            }
        }
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard Date.now.timeIntervalSince(lastLevelUpdate) >= 0.08,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastLevelUpdate = .now
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[index]))
        }
        onLevel?(min(1, peak * 8))
    }
}

enum SystemAudioRecorderError: LocalizedError {
    case initializationFailed(String)
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case let .initializationFailed(message):
            return String.localizedStringWithFormat(
                String(localized: "error.systemAudioInitialization"),
                message
            )
        case .noDisplay:
            return String(localized: "error.systemAudioUnavailable")
        case .permissionDenied:
            return String(localized: "error.systemAudioPermission")
        }
    }
}

extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: streamDescription.pointee.mSampleRate,
                channels: AVAudioChannelCount(streamDescription.pointee.mChannelsPerFrame),
                interleaved: false
              ),
              let block = CMSampleBufferGetDataBuffer(self) else { return nil }

        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = result.floatChannelData else { return nil }
        result.frameLength = AVAudioFrameCount(frames)

        var length = 0
        var source: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &source)
        guard let source else { return nil }
        memcpy(destination[0], source, min(length, Int(result.frameCapacity) * MemoryLayout<Float>.size))
        return result
    }
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        guard let source = floatChannelData, let destination = copy.floatChannelData else { return nil }
        for channel in 0..<Int(format.channelCount) {
            memcpy(destination[channel], source[channel], Int(frameLength) * MemoryLayout<Float>.size)
        }
        return copy
    }
}
