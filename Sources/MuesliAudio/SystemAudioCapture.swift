import AVFAudio
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (Zoom, Meet, Teams, FaceTime,
/// browser tabs…) with a Core Audio process tap. No virtual audio driver and
/// no bot joining the call. This is "Them".
///
/// Needs the "System Audio Recording" permission (macOS 14.2+); the system
/// prompts the first time a tap is created.
public final class SystemAudioCapture: @unchecked Sendable {
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let queue = DispatchQueue(label: "muesli.system-audio", qos: .userInitiated)

    public init() {}

    public func start() throws -> AsyncStream<AudioChunk> {
        let outputUID = try Self.defaultOutputDeviceUID()

        // Mono mixdown of every process: speech recognition doesn't need stereo.
        let tap = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "muesli system audio"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(tap, &tapID)
        guard status == noErr else { throw CaptureError.tapCreation(status) }

        do {
            var asbd = try Self.tapFormat(tapID)
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.tapFormat(kAudioHardwareUnspecifiedError) }

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "muesli tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
            guard status == noErr else { throw CaptureError.aggregateDevice(status) }

            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
            self.continuation = continuation

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inInputData, inInputTime, _, _ in
                guard let chunk = Self.copy(inInputData, format: format, hostTime: inInputTime.pointee.mHostTime) else { return }
                continuation.yield(chunk)
            }
            guard status == noErr else { throw CaptureError.ioProc(status) }

            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw CaptureError.start(status) }
            return stream
        } catch {
            teardown()
            throw error
        }
    }

    public func stop() {
        teardown()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internals

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
    }

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
