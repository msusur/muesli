import CoreAudio
import Foundation

/// A microphone or other device that can record ("Me").
public struct InputDevice: Sendable, Hashable, Identifiable {
    public var id: String { uid }
    /// Stable across reboots and reconnections, so it's what gets saved.
    public let uid: String
    public let name: String
    let objectID: AudioObjectID
}

public enum InputDevices {
    /// Every visible device with at least one input channel, in Core Audio's order.
    public static func list() -> [InputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), (value(id, kAudioDevicePropertyIsHidden) as UInt32?) != 1,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  // Muesli's own system-audio aggregate devices aren't microphones.
                  !uid.hasPrefix(SystemAudioCapture.aggregateUIDPrefix)
            else { return nil }
            return InputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, objectID: id)
        }
    }

    /// What macOS records from when no device is chosen (Sound settings → Input).
    public static func systemDefault() -> InputDevice? {
        guard let id: AudioObjectID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) else {
            return nil
        }
        return list().first { $0.objectID == id }
    }

    static func device(uid: String) -> InputDevice? { list().first { $0.uid == uid } }

    // MARK: Core Audio properties

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return nil }
        return storage.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
}
