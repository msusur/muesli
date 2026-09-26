import AppKit
import CoreAudio
import Darwin
import Foundation

/// A process that has connected to the audio system (an app, one of its
/// helper processes, or a background daemon).
public struct AudioProcess: Sendable, Equatable, Identifiable {
    public var id: AudioObjectID { objectID }
    /// Core Audio's handle, which is what a process tap is built from (not the PID).
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// The app's display name, falling back to the process name.
    public let name: String
    /// True while the process is sending audio to an output device.
    public let isProducingAudio: Bool
}

public enum AudioProcesses {
    /// Every process currently known to Core Audio, except this one (muesli's own
    /// tap shows up here, and must never be captured or listed).
    public static func list() -> [AudioProcess] {
        processObjectIDs().compactMap(describe).filter { $0.pid != getpid() }
    }

    // MARK: Core Audio properties

    static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func describe(_ object: AudioObjectID) -> AudioProcess? {
        guard let pid: pid_t = value(object, kAudioProcessPropertyPID) else { return nil }
        let bundleID = string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
        let running: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput) ?? 0
        return AudioProcess(
            objectID: object, pid: pid, bundleID: bundleID,
            name: displayName(pid: pid, bundleID: bundleID), isProducingAudio: running != 0
        )
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

    // MARK: Names and process tree

    static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return bundleID ?? "pid \(pid)"
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}

/// Picks apps by what a person would type: "zoom", "Google Chrome",
/// "us.zoom.xos". Matching is generous on purpose, because one app is often
/// several processes (a browser's helper per tab, a call app's audio helper).
public struct AppSelector: Sendable, Equatable {
    public let terms: [String]

    public init(_ terms: [String]) {
        self.terms = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public init(commaSeparated text: String) {
        self.init(text.split(separator: ",").map(String.init))
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Whether one process matches by name or bundle ID. A bundle ID also matches
    /// its helpers (`com.google.Chrome` → `com.google.Chrome.helper`).
    func matches(name: String, bundleID: String?) -> Bool {
        let name = name.lowercased()
        let bundle = bundleID?.lowercased()
        return terms.contains { raw in
            let term = raw.lowercased()
            if bundle == term || bundle?.hasPrefix(term + ".") == true || name == term { return true }
            // Substring matching only for terms long enough not to match everything.
            return term.count >= 3 && name.contains(term)
        }
    }

    /// The audio processes this selector covers: those that match directly, plus
    /// any whose parent chain leads to a matching running app (helpers that
    /// don't share the app's name or bundle ID).
    public func resolve(in processes: [AudioProcess]) -> [AudioProcess] {
        guard !isEmpty else { return [] }
        var rootPIDs = Set(processes.filter { matches(name: $0.name, bundleID: $0.bundleID) }.map(\.pid))
        for app in NSWorkspace.shared.runningApplications {
            if matches(name: app.localizedName ?? "", bundleID: app.bundleIdentifier) { rootPIDs.insert(app.processIdentifier) }
        }
        return processes.filter { process in
            var pid: pid_t? = process.pid
            for _ in 0 ..< 6 {
                guard let current = pid else { return false }
                if rootPIDs.contains(current) { return true }
                pid = AudioProcesses.parentPID(of: current)
            }
            return false
        }
    }
}
