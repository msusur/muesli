import Foundation
import MuesliAudio
import MuesliCore

public struct WhisperConfiguration: Sendable, Equatable {
    public static let defaultModel = "mlx-community/whisper-large-v3-mlx"

    /// A Hugging Face repo of MLX-converted Whisper weights, or a local folder.
    public var model: String
    /// ISO 639-1 code such as "en" or "ar". `nil` detects the language once per stream.
    public var language: String?
    /// A Python interpreter that has `mlx-whisper` installed. `nil` searches for one.
    public var python: String?

    public init(model: String = WhisperConfiguration.defaultModel, language: String? = nil, python: String? = nil) {
        self.model = model
        self.language = language
        self.python = python
    }
}

public struct WhisperResult: Sendable {
    public var segments: [TranscriptSegment]
    /// The language Whisper used or detected.
    public var language: String?
    /// How many stretches of speech were transcribed.
    public var regionCount: Int
    public var speechSeconds: TimeInterval
}

/// Runs Whisper (through `mlx-whisper`) over a recorded stream.
///
/// This is the second speech engine next to Apple's: slower, and not live, but
/// it covers 99 languages (Apple's recognizer covers 25) and holds up on noisy or
/// narrowband audio. In muesli's tests, Whisper's default long-audio mode
/// hallucinated on silence and looped on phone-quality audio, so this always:
///
/// 1. gates the audio to just the stretches that contain speech (`SpeechGate`),
/// 2. turns off `condition_on_previous_text`, and
/// 3. drops segments Whisper itself flags as non-speech (`WhisperFilter`).
public struct WhisperTranscriber: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case pythonNotFound(tried: [String])
        case failed(status: Int32, detail: String)
        case badOutput(String)

        public var errorDescription: String? {
            switch self {
            case .pythonNotFound(let tried):
                "Couldn't find a Python with mlx-whisper installed. Install it with `python3 -m pip install mlx-whisper`, or point MUESLI_PYTHON at the interpreter that has it."
                    + (tried.isEmpty ? "" : " Looked in: " + tried.joined(separator: ", ") + ".")
            case .failed(let status, let detail):
                "Whisper failed (exit \(status))." + (detail.isEmpty ? "" : " " + detail)
            case .badOutput(let why):
                "Whisper returned something muesli couldn't read: \(why)"
            }
        }
    }

    public let configuration: WhisperConfiguration

    public init(configuration: WhisperConfiguration = WhisperConfiguration()) {
        self.configuration = configuration
    }

    // MARK: Finding Python and the model

    /// Where to look for a Python, best guess first. The system `/usr/bin/python3`
    /// is only tried when developer tools are installed, because otherwise running
    /// it pops up an "install developer tools" dialog.
    static func candidateInterpreters(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        var candidates: [String] = []
        if let explicit = environment["MUESLI_PYTHON"], !explicit.isEmpty { candidates.append(explicit) }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory != "/usr/bin" {
            candidates.append("\(directory)/python3")
        }
        if fileExists("/Library/Developer/CommandLineTools/usr/bin/python3")
            || fileExists("/Applications/Xcode.app/Contents/Developer/usr/bin/python3") {
            candidates.append("/usr/bin/python3")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && fileExists($0) }
    }

    static func locate(candidates: [String], hasMLXWhisper: (String) -> Bool) -> String? {
        candidates.first(where: hasMLXWhisper)
    }

    static func probe(python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('mlx_whisper') else 1)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The Python that will be used. Throws with instructions if there isn't one.
    public func resolvePython() throws -> String {
        if let explicit = configuration.python { return explicit }
        let candidates = Self.candidateInterpreters()
        guard let python = Self.locate(candidates: candidates, hasMLXWhisper: Self.probe) else {
            throw Failure.pythonNotFound(tried: candidates)
        }
        return python
    }

    /// Whether the model is already downloaded (so the first run won't fetch gigabytes).
    public static func isModelCached(
        _ model: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if model.hasPrefix("/") || model.hasPrefix(".") || model.hasPrefix("~") {
            return FileManager.default.fileExists(atPath: (model as NSString).expandingTildeInPath)
        }
        let hub: String
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty {
            hub = cache
        } else if let home = environment["HF_HOME"], !home.isEmpty {
            hub = home + "/hub"
        } else {
            hub = NSHomeDirectory() + "/.cache/huggingface/hub"
        }
        let snapshots = "\(hub)/models--\(model.replacingOccurrences(of: "/", with: "--"))/snapshots"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? []
        return !entries.isEmpty
    }

    // MARK: Transcribing

    /// - Parameters:
    ///   - wav: A 16 kHz mono WAV, as written by `StreamRecorder`.
    ///   - startOffset: Seconds between the session start and this stream's first sample.
    ///   - progress: Called as each stretch of speech finishes: (done, total).
    public func transcribe(
        wav: URL, speaker: Speaker, startOffset: TimeInterval,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> WhisperResult {
        let python = try resolvePython()

        let measurement = try await Task.detached { try FrameEnergy.measure(wav) }.value
        let regions = SpeechGate.regions(frameDecibels: measurement.decibels, frameSeconds: measurement.frameSeconds)
        guard !regions.isEmpty else {
            return WhisperResult(segments: [], language: configuration.language, regionCount: 0, speechSeconds: 0)
        }

        var request: [JSONValue.Member] = [
            .init("wav", .string(wav.path)),
            .init("model", .string(configuration.model)),
            .init("regions", .array(regions.map { .array([.int(Int(($0.start * 1000).rounded())), .int(Int(($0.end * 1000).rounded()))]) })),
        ]
        if let language = configuration.language { request.append(.init("language", .string(language))) }

        let output = try await Self.runHelper(python: python, request: JSONValue.object(request).data(), progress: progress)
        let decoded = try Self.decode(output)

        let segments = Self.segments(from: decoded, regions: regions, speaker: speaker, startOffset: startOffset)
        return WhisperResult(
            segments: segments, language: decoded.language,
            regionCount: regions.count, speechSeconds: regions.reduce(0) { $0 + $1.duration }
        )
    }

    // MARK: Output

    struct HelperOutput: Decodable, Equatable {
        struct Region: Decodable, Equatable {
            struct Segment: Decodable, Equatable {
                let start: Double
                let end: Double
                let text: String
                let noSpeechProb: Double?
                let avgLogprob: Double?
                let compressionRatio: Double?
            }
            let index: Int
            let segments: [Segment]
        }
        let language: String?
        let regions: [Region]
    }

    static let resultMarker = "@@MUESLI@@"

    /// Finds the helper's result line among any other output and decodes it.
    static func decode(_ data: Data) throws -> HelperOutput {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(resultMarker) }) else {
            throw Failure.badOutput("no result line (output began: \(text.prefix(120)))")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(HelperOutput.self, from: Data(line.dropFirst(resultMarker.count).utf8))
        } catch {
            throw Failure.badOutput(error.localizedDescription)
        }
    }

    /// Times inside a region are relative to that region; put them on the session clock.
    static func segments(
        from output: HelperOutput, regions: [SpeechRegion], speaker: Speaker, startOffset: TimeInterval
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for region in output.regions where regions.indices.contains(region.index) {
            let base = startOffset + regions[region.index].start
            for segment in region.segments {
                let quality = WhisperQuality(
                    noSpeechProbability: segment.noSpeechProb, averageLogProbability: segment.avgLogprob,
                    compressionRatio: segment.compressionRatio)
                guard WhisperFilter.keeps(text: segment.text, quality: quality) else { continue }
                result.append(TranscriptSegment(
                    speaker: speaker, start: base + segment.start, end: base + max(segment.end, segment.start),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: segment.avgLogprob.map { min(1, exp($0)) }))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: The Python helper

    /// Loads the model once and transcribes each speech region. Arguments arrive as
    /// JSON on stdin, never interpolated into this source, so nothing in a
    /// filename or model name can be executed.
    static let helperSource = #"""
    import sys, json, wave
    real_stdout = sys.stdout
    sys.stdout = sys.stderr  # library chatter must never corrupt the result line
    import numpy as np
    import mlx_whisper

    req = json.load(sys.stdin)
    wav_path, model, language, regions = req["wav"], req["model"], req.get("language"), req["regions"]

    def clip(w, a_ms, b_ms):
        rate = w.getframerate()
        w.setpos(min(int(a_ms * rate / 1000), w.getnframes()))
        frames = w.readframes(max(0, int((b_ms - a_ms) * rate / 1000)))
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    def run(audio, lang):
        kw = {"language": lang} if lang else {}
        return mlx_whisper.transcribe(audio, path_or_hf_repo=model, verbose=None,
                                      condition_on_previous_text=False, **kw)

    out, cache = [], {}
    with wave.open(wav_path) as w:
        if not language and regions:
            # Detect the language once, from the longest stretch of speech: short
            # clips detect badly, and one wrong guess would garble a whole region.
            longest = max(range(len(regions)), key=lambda i: regions[i][1] - regions[i][0])
            a, b = regions[longest]
            probe = run(clip(w, a, min(b, a + 30000)), None)
            language = probe.get("language")
            if b - a <= 30000:
                cache[longest] = probe
        for i, (a, b) in enumerate(regions):
            result = cache.get(i) or run(clip(w, a, b), language)
            out.append({"index": i, "segments": [
                {"start": s["start"], "end": s["end"], "text": s["text"],
                 "no_speech_prob": s.get("no_speech_prob"), "avg_logprob": s.get("avg_logprob"),
                 "compression_ratio": s.get("compression_ratio")} for s in result["segments"]]})
            print("PROGRESS %d %d" % (i + 1, len(regions)), file=sys.stderr, flush=True)

    real_stdout.write("@@MUESLI@@" + json.dumps({"language": language, "regions": out}) + "\n")
    real_stdout.flush()
    """#

    // MARK: Running it

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        func set(_ p: Process) { lock.withLock { process = p } }
        func terminate() { lock.withLock { if process?.isRunning == true { process?.terminate() } } }
    }

    private final class StderrWatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = ""
        private var tail = ""
        private let progress: @Sendable (Int, Int) -> Void
        init(progress: @escaping @Sendable (Int, Int) -> Void) { self.progress = progress }

        func feed(_ data: Data) {
            let lines: [String] = lock.withLock {
                partial += String(decoding: data, as: UTF8.self)
                var complete = partial.components(separatedBy: "\n")
                partial = complete.removeLast()
                return complete
            }
            for line in lines {
                let parts = line.split(separator: " ")
                if parts.count == 3, parts[0] == "PROGRESS", let done = Int(parts[1]), let total = Int(parts[2]) {
                    progress(done, total)
                } else if !line.isEmpty {
                    lock.withLock { tail = String((tail + "\n" + line).suffix(1500)) }
                }
            }
        }

        var lastOutput: String { lock.withLock { tail.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    private static func runHelper(
        python: String, request: Data, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Data {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(python: python, request: request, progress: progress, box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func runBlocking(
        python: String, request: Data, progress: @escaping @Sendable (Int, Int) -> Void, box: ProcessBox
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", helperSource]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONWARNINGS"] = "ignore"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let watcher = StderrWatcher(progress: progress)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { watcher.feed(data) }
        }

        try process.run()
        box.set(process)
        try? stdin.fileHandleForWriting.write(contentsOf: request)
        try? stdin.fileHandleForWriting.close()

        // Read to EOF before waiting, or a full pipe would deadlock the child.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.failed(status: process.terminationStatus, detail: watcher.lastOutput)
        }
        return output
    }
}
