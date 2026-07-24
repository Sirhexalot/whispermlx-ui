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
              ) else { return nil }

        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = result.floatChannelData else { return nil }
        result.frameLength = AVAudioFrameCount(frames)

        let channelCount = Int(streamDescription.pointee.mChannelsPerFrame)
        let isInterleaved = (streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let bufferList = AudioBufferList.allocate(maximumBuffers: max(channelCount, 1))
        defer { bufferList.unsafeMutablePointer.deallocate() }

        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size + max(channelCount - 1, 0) * MemoryLayout<AudioBuffer>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        if isInterleaved {
            guard let sourceData = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    let sample = sourceData[(frame * channelCount) + channel]
                    destination[channel][frame] = sample.isFinite ? sample : 0
                }
            }
        } else {
            for channel in 0..<channelCount {
                guard let sourceData = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                for frame in 0..<frames {
                    let sample = sourceData[frame]
                    destination[channel][frame] = sample.isFinite ? sample : 0
                }
            }
        }

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
