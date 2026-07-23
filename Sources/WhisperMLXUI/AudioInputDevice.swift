import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum AudioInputDeviceStore {
    private static let key = "selected-microphone-uid"

    static func load() -> String? {
        let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func save(_ id: String?) {
        let value = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

/// The device list and the capture pipeline intentionally use the same
/// AVFoundation identities. Core Audio device IDs are not interchangeable with
/// AVCaptureDevice unique IDs on all USB headsets.
enum AudioInputDeviceManager {
    static func availableDevices() -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.devices(for: .audio)
            .map { device in
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
