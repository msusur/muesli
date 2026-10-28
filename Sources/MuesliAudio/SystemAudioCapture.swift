import AVFAudio
import CoreAudio
import Foundation

/// Captures what the Mac is playing (Zoom, Meet, Teams, FaceTime, browser tabs…)
/// with a Core Audio process tap. No virtual audio driver and no bot joining
/// the call. This is "Them".
///
/// Needs the "System Audio Recording" permission (macOS 14.2+); the system
/// prompts the first time a tap is created.
public final class SystemAudioCapture: @unchecked Sendable {
    /// What to capture.
    public enum Scope: Sendable, Equatable {
        /// Everything the Mac plays.
        case everything
        /// Only these apps, including their helper processes. Follows them as
        /// they start and stop: a call app that begins playing audio after
        /// recording started is picked up.
        case only(AppSelector)
        /// Everything except these apps (music, notification sounds…).
        case excluding(AppSelector)
    }

    /// Progress worth telling the user about.
    public enum Update: Sendable, Equatable {
        /// Nothing matched yet; capturing starts when it does.
        case waiting(for: [String])
        /// The set of processes being captured (or excluded) changed.
        case following([String])
        /// Something went wrong after recording had started.
        case failed(String)
    }

    public enum CaptureError: Error, LocalizedError {
        case noOutputDevice(OSStatus)
        case tapCreation(OSStatus)
        case tapFormat(OSStatus)
        case aggregateDevice(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .noOutputDevice(let s): "No default output device (\(s))."
            case .tapCreation(let s):
                "Couldn't create the system-audio tap (\(s)). Grant System Audio Recording to your terminal in System Settings → Privacy & Security."
            case .tapFormat(let s): "Couldn't read the tap's audio format (\(s))."
            case .aggregateDevice(let s): "Couldn't create the private aggregate device (\(s))."
            case .ioProc(let s): "Couldn't create the IO proc (\(s))."
            case .start(let s): "Couldn't start the audio device (\(s))."
            }
        }
    }

    public let scope: Scope
    /// Called on an internal queue. Set before `start()`.
    public var onUpdate: (@Sendable (Update) -> Void)?

    // All mutable state below is confined to `control`.
    private let control = DispatchQueue(label: "muesli.system-audio.control")
    private let ioQueue = DispatchQueue(label: "muesli.system-audio", qos: .userInitiated)
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var tap: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var followed: [AudioObjectID] = []
    private var lastReported: Update?
    private var listener: AudioObjectPropertyListenerBlock?

    public init(scope: Scope = .everything) {
        self.scope = scope
    }

    public func start() throws -> AsyncStream<AudioChunk> {
        try control.sync {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
            self.continuation = continuation
            do {
                try refresh()
                if scope != .everything { installListener() }
            } catch {
                teardown()
                self.continuation = nil
                continuation.finish()
                throw error
            }
            return stream
        }
    }

    public func stop() {
        control.sync {
            removeListener()
            teardown()
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: Following the process list

    /// Brings the tap in line with the processes that exist right now. Runs on `control`.
    private func refresh() throws {
        let processes = AudioProcesses.list()
        var ids: [AudioObjectID] = []
        var names: [String] = []
        switch scope {
        case .everything:
            break
        case .only(let selector), .excluding(let selector):
            let matched = selector.resolve(in: processes)
            ids = matched.map(\.objectID)
            names = Self.summarize(matched)
            if case .only = scope, matched.isEmpty {
                // Keep any existing tap (its processes have just exited), or wait.
                if tap == nil { report(.waiting(for: selector.terms)) }
                return
            }
        }

        if tap == nil {
            try buildPipeline(processes: ids)
        } else if ids != followed {
            try update(processes: ids)
        }
        followed = ids
        if scope != .everything { report(.following(names)) }
    }

    /// One line per app, not per helper process: "Google Chrome (3 processes)".
    static func summarize(_ processes: [AudioProcess]) -> [String] {
        Dictionary(grouping: processes, by: \.name)
            .map { name, group in group.count > 1 ? "\(name) (\(group.count) processes)" : name }
            .sorted()
    }

    private func report(_ update: Update) {
        guard update != lastReported else { return }
        lastReported = update
        onUpdate?(update)
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The block runs on `control`, so it can call `refresh()` directly.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            do { try self.refresh() } catch { self.report(.failed(error.localizedDescription)) }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
    }

    private func removeListener() {
        guard let block = listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        listener = nil
    }

    // MARK: Building and updating the tap

    private func makeDescription(processes: [AudioObjectID]) -> CATapDescription {
        // Mono mixdown: speech recognition doesn't need stereo.
        let description: CATapDescription
        switch scope {
        case .only: description = CATapDescription(monoMixdownOfProcesses: processes)
        case .everything, .excluding: description = CATapDescription(monoGlobalTapButExcludeProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "muesli system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func buildPipeline(processes: [AudioObjectID]) throws {
        let outputUID = try Self.defaultOutputDeviceUID()
        let description = makeDescription(processes: processes)

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.tapCreation(status) }
        tap = description

        var asbd = try Self.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.tapFormat(kAudioHardwareUnspecifiedError) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "muesli tap",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CaptureError.aggregateDevice(status) }

        guard let continuation else { return }
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inInputData, inInputTime, _, _ in
            guard let chunk = Self.copy(inInputData, format: format, hostTime: inInputTime.pointee.mHostTime) else { return }
            continuation.yield(chunk)
        }
        guard status == noErr else { throw CaptureError.ioProc(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CaptureError.start(status) }
    }

    /// Changes which processes an existing tap covers, without interrupting the stream.
    private func update(processes: [AudioObjectID]) throws {
        guard let tap else { return }
        tap.processes = processes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object: CATapDescription = tap
        let status = withUnsafeMutablePointer(to: &object) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { throw CaptureError.tapCreation(status) }
    }

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tap = nil
        followed = []
    }

    // MARK: Buffers and device properties

    /// The IO proc's buffer is only valid for the duration of the callback, so
    /// copy it into an `AVAudioPCMBuffer` we own.
    private static func copy(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, hostTime: UInt64) -> AudioChunk? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = source.first, first.mDataByteSize > 0 else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let s = src.mData, let d = dst.mData else { continue }
            memcpy(d, s, min(Int(src.mDataByteSize), Int(dst.mDataByteSize)))
        }
        return AudioChunk(buffer: buffer, hostTime: hostTime)
    }

    private static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw CaptureError.tapFormat(status) }
        return asbd
    }

    /// Marks the tap's aggregate devices, which Muesli itself can see, so they're never offered as a microphone.
    static let aggregateUIDPrefix = "dev.muesli.tap."

    public static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw CaptureError.noOutputDevice(status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.noOutputDevice(status) }
        return uid.takeRetainedValue() as String
    }
}
