import AVFAudio

/// Converts audio buffers from one format to another (sample rate, channel
/// count, sample type). Keeps the converter's state between buffers, so a
/// stream converted buffer by buffer has no clicks at the seams.
public struct PCMConverter {
    public enum ConversionError: Error, LocalizedError {
        case unsupported(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let what): "Can't convert audio \(what)."
            case .failed(let why): "Audio conversion failed: \(why)"
            }
        }
    }

    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        inputFormat = input
        outputFormat = output
        if input == output {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                throw ConversionError.unsupported("\(input) → \(output)")
            }
            self.converter = converter
        }
    }

    /// Returns nil when the buffer produced no output yet (a converter may hold
    /// back a few samples).
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw ConversionError.failed(error?.localizedDescription ?? "unknown") }
        return output.frameLength > 0 ? output : nil
    }

    /// Emits whatever the converter is still holding back. Call once, at the end of a stream.
    public func flush() throws -> AVAudioPCMBuffer? {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { throw ConversionError.failed(error?.localizedDescription ?? "unknown") }
        return output.frameLength > 0 ? output : nil
    }
}
