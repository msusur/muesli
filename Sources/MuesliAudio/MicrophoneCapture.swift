import AVFoundation

/// Captures a microphone with `AVAudioEngine`: the system's default input
/// device, or a chosen one. This is "Me".
public final class MicrophoneCapture: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case accessDenied
        case deviceNotFound(String)
        case cantUseDevice(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Microphone access denied. Grant it to your terminal (or muesli) in System Settings → Privacy & Security → Microphone."
            case .deviceNotFound(let uid): "The microphone “\(uid)” isn't connected."
            case .cantUseDevice(let name, let status): "Couldn't record from “\(name)” (Core Audio error \(status))."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    /// `nil` records from the system's default input device.
    public let deviceUID: String?

    public init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Starts capture. The stream ends when `stop()` is called.
    public func start() async throws -> AsyncStream<AudioChunk> {
        let device = try deviceUID.map { uid in
            guard let device = InputDevices.device(uid: uid) else { throw CaptureError.deviceNotFound(uid) }
            return device
        }
        guard await Self.requestAccess() else { throw CaptureError.accessDenied }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation

        let input = engine.inputNode
        if let device { try use(device, for: input) }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            continuation.yield(AudioChunk(buffer: buffer, hostTime: time.hostTime))
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    /// Points the engine's input at `device` instead of the default. Must happen
    /// before the input's format is read.
    private func use(_ device: InputDevice, for input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw CaptureError.cantUseDevice(device.name, kAudioUnitErr_Uninitialized) }
        var id = device.objectID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw CaptureError.cantUseDevice(device.name, status) }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
