import AVFAudio

/// One buffer of captured audio plus the host-clock time of its first sample.
///
/// `AVAudioPCMBuffer` isn't `Sendable`, but a chunk is never mutated after it
/// leaves the capture callback, so passing it across tasks is safe.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// `mach_absolute_time` units. 0 when the source has no real-time clock
    /// (for example audio read from a file).
    public let hostTime: UInt64

    public init(buffer: AVAudioPCMBuffer, hostTime: UInt64 = 0) {
        self.buffer = buffer
        self.hostTime = hostTime
    }
}

public enum HostClock {
    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: end) - AVAudioTime.seconds(forHostTime: start)
    }
}
