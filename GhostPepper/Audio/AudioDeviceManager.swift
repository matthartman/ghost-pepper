import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

class AudioDeviceManager {

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
            guard let name = deviceName(deviceID: deviceID) else { return nil }
            return AudioInputDevice(id: deviceID, name: name)
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

    /// Persists the selected input device ID for Ghost Pepper's use.
    /// Does NOT change the system-wide default — the device is set directly
    /// on the audio unit when recording starts.
    static func setSelectedInputDevice(_ deviceID: AudioDeviceID) {
        UserDefaults.standard.set(Int(deviceID), forKey: "selectedInputDeviceID")
    }

    /// Returns the user's selected input device ID, or nil to use the system default.
    static func selectedInputDeviceID() -> AudioDeviceID? {
        let stored = UserDefaults.standard.integer(forKey: "selectedInputDeviceID")
        return stored > 0 ? AudioDeviceID(stored) : nil
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

    /// Returns the input device matching the given name, if any.
    static func inputDevice(named name: String) -> AudioInputDevice? {
        listInputDevices().first { $0.name == name }
    }

    /// Returns any audio device matching the given name, even if it currently has
    /// no input channels (e.g. a Bluetooth headset on A2DP that hasn't switched
    /// to HFP yet). Setting such a device as the default input triggers the profile switch.
    static func anyDevice(named name: String) -> AudioInputDevice? {
        listAllDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
            guard let n = deviceName(deviceID: deviceID), n == name else { return nil }
            return AudioInputDevice(id: deviceID, name: n)
        }.first
    }

    /// Returns all system audio device IDs.
    static func listAllDeviceIDs() -> [AudioDeviceID] {
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

        return deviceIDs
    }

    /// Registers a listener that fires whenever the system audio device list changes
    /// (e.g. Bluetooth headset connects/disconnects). Returns an opaque ID for removal.
    @discardableResult
    static func onDeviceListChanged(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        return block
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

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
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
