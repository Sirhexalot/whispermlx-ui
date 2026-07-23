import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum AudioInputDeviceStore {
    private static let key = "selected-microphone-uid"

    static func load() -> String? {
        let trimmed = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ uid: String?) {
        let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }
}

enum AudioInputDeviceManager {
    static func availableDevices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()

        return allDeviceIDs().compactMap { deviceID in
            guard hasInputChannels(deviceID) else { return nil }
            guard let uid = deviceUID(for: deviceID), let name = deviceName(for: deviceID) else { return nil }
            return AudioInputDevice(id: uid, name: name, isDefault: deviceID == defaultID)
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func configure(_ node: AVAudioInputNode, preferredUID: String?) throws -> AudioInputDevice? {
        let devices = availableDevices()
        guard let preferredUID, !preferredUID.isEmpty else {
            return devices.first(where: \.isDefault)
        }

        guard let preferredDevice = devices.first(where: { $0.id == preferredUID }) else {
            return devices.first(where: \.isDefault)
        }

        guard let audioUnit = node.audioUnit else {
            throw RecorderError.microphoneUnavailable
        }

        guard let deviceID = deviceID(forUID: preferredUID) else {
            throw RecorderError.microphoneUnavailable
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RecorderError.microphoneSelectionFailed(preferredDevice.name)
        }

        return preferredDevice
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidPointer = UnsafeMutablePointer<CFString>.allocate(capacity: 1)
        uidPointer.initialize(to: uid as CFString)
        defer {
            uidPointer.deinitialize(count: 1)
            uidPointer.deallocate()
        }

        var deviceID = AudioDeviceID()
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            uidPointer,
            &byteCount,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(
            selector: kAudioDevicePropertyDeviceUID,
            deviceID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        stringProperty(
            selector: kAudioObjectPropertyName,
            deviceID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func stringProperty(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let stringPointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        stringPointer.initialize(to: nil)
        defer {
            stringPointer.deinitialize(count: 1)
            stringPointer.deallocate()
        }

        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, stringPointer)
        guard status == noErr, let propertyString = stringPointer.pointee else { return nil }
        return propertyString as String
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, bufferList) == noErr else {
            return false
        }

        let audioBufferList = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.contains(where: { $0.mNumberChannels > 0 })
    }
}
