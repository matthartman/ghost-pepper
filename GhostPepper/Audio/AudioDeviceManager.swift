import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

class AudioDeviceManager {
    private static let selectedInputDeviceIDKey = "selectedInputDeviceID"
    private static let selectedInputDeviceUIDKey = "selectedInputDeviceUID"

    /// Returns all available audio input devices.
    static func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            // Check if device has input channels
            guard hasInputChannels(deviceID: deviceID) else { return nil }
            guard let uid = deviceUID(deviceID: deviceID), !uid.isEmpty else { return nil }
            guard let name = deviceName(deviceID: deviceID) else { return nil }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// Returns the current default input device ID.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    /// Persists the selected input device UID for Ghost Pepper's use.
    /// Does NOT change the system-wide default — the device is set directly
    /// on the audio unit when recording starts.
    static func setSelectedInputDevice(
        _ deviceID: AudioDeviceID,
        defaults: UserDefaults = .standard,
        uidForDeviceID: (AudioDeviceID) -> String? = AudioDeviceManager.deviceUID
    ) {
        guard let uid = uidForDeviceID(deviceID), !uid.isEmpty else {
            return
        }

        defaults.set(uid, forKey: selectedInputDeviceUIDKey)
    }

    /// Returns the user's selected input device ID, or nil to use the system default.
    static func selectedInputDeviceID(
        defaults: UserDefaults = .standard,
        inputDevices: () -> [AudioInputDevice] = AudioDeviceManager.listInputDevices
    ) -> AudioDeviceID? {
        let devices = inputDevices()

        if let uid = selectedInputDeviceUID(defaults: defaults) {
            return devices.first(where: { $0.uid == uid })?.id
        }

        guard let legacyStoredID = defaults.object(forKey: selectedInputDeviceIDKey) as? Int,
              legacyStoredID > 0,
              let device = devices.first(where: { $0.id == AudioDeviceID(legacyStoredID) }) else {
            return nil
        }

        defaults.set(device.uid, forKey: selectedInputDeviceUIDKey)
        return device.id
    }

    /// Sets the system default input device.
    /// Deprecated: prefer setSelectedInputDevice() + targeting the audio unit directly.
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        return status == noErr
    }

    // MARK: - Private

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func selectedInputDeviceUID(defaults: UserDefaults = .standard) -> String? {
        if let uid = defaults.string(forKey: selectedInputDeviceUIDKey), !uid.isEmpty {
            return uid
        }

        return nil
    }

    static func deviceUID(deviceID: AudioDeviceID) -> String? {
        deviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        deviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func deviceStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }

        return name?.takeRetainedValue() as String?
    }
}
