@preconcurrency import AVFoundation
import Foundation

/// 用 llama.cpp 在本机跑所选语音模型。录音不出这台电脑。
/// 做法：起一个只监听本机的 llama-server，把录音切成不超过 28 秒的小段逐段送进去。
actor QwenASR {
    static let shared = QwenASR()

    static let modelName = "Qwen3-ASR-0.6B-Q8_0.gguf"
    static let projectorName = "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"
    static let displayName = "Qwen3‑ASR 0.6B"

    nonisolated static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/qwen3-asr-0.6b", isDirectory: true)
    }

    nonisolated static func locateServer(custom: String) -> URL? {
        let candidates = [custom, "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/Applications/Capwise.app/Contents/Helpers/llama-server/llama-server"]
        return candidates.filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func locateModel(selection: AppSettings.LocalASRModel = .qwen) -> (model: URL, projector: URL)? {
        if selection.funASR != nil { return nil }
        if selection == .gemma {
            let m = LocalLLM.folder.appendingPathComponent(LocalLLM.gemmaFileName)
            let p = LocalLLM.folder.appendingPathComponent(LocalLLM.gemmaProjectorName)
            guard LocalLLM.completeGemmaFile(m), LocalLLM.completeGemmaFile(p) else { return nil }
            return (m, p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [modelFolder, home.appendingPathComponent("Library/Application Support/so.cap.desktop/transcription_models/qwen3-asr-0.6b")]
        for f in folders {
            let m = f.appendingPathComponent(modelName), p = f.appendingPathComponent(projectorName)
            if FileManager.default.fileExists(atPath: m.path), FileManager.default.fileExists(atPath: p.path) { return (m, p) }
        }
        return nil
    }

    nonisolated static func modelInstalled(selection: AppSettings.LocalASRModel) -> Bool {
        if let model = selection.funASR { return FunASR.modelInstalled(model) }
        return locateModel(selection: selection) != nil
    }

    nonisolated static func runtimeAvailable(selection: AppSettings.LocalASRModel, serverPath: String) -> Bool {
        if let model = selection.funASR { return FunASR.locateExecutable(model) != nil }
        return locateServer(custom: serverPath) != nil
    }

    private var process: Process?
    private var identity: [String]?
    private var ready = false
    private var port = 0
    private var startupDeadline = ContinuousClock.now
    private var busy = false
    private var stopWhenIdle = false

    // MARK: 服务

    private func ensureRunning(serverPath: String, selection: AppSettings.LocalASRModel) async throws -> Int {
        try Task.checkCancellation()
        guard let server = Self.locateServer(custom: serverPath) else { throw ASRError.noServer }
        guard let files = Self.locateModel(selection: selection) else { throw ASRError.noModel }
        let requested = [server.path, files.model.path, files.projector.path]
        if identity == requested, let process, process.isRunning {
            if ready { return port }
            return try await waitUntilReady(process, port: port, deadline: startupDeadline)
        }
        stopNow()
        identity = requested

        port = Int.random(in: 39000...39900)
        let p = Process()
        // 用一层 sh 盯着豆仓的进程：豆仓退出（哪怕是崩溃），转写服务也跟着退，不留孤儿进程
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-asr", String(ProcessInfo.processInfo.processIdentifier), server.path,
                       "-m", files.model.path, "--mmproj", files.projector.path,
                       "--host", "127.0.0.1", "--port", String(port), "-c", "4096", "-np", "1", "--log-disable"] + (selection == .gemma ? ["--jinja", "--reasoning-budget", "0", "--chat-template-kwargs", #"{"enable_thinking":false}"#] : [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ASRError.startFailed(error.localizedDescription) }
        ready = false
        process = p

        startupDeadline = .now.advanced(by: .seconds(300))
        return try await waitUntilReady(p, port: port, deadline: startupDeadline)
    }

    private func waitUntilReady(_ p: Process, port: Int, deadline: ContinuousClock.Instant) async throws -> Int {
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process === p, p.isRunning else {
                throw ASRError.startFailed(String(localized: "进程退出了，可能是模型文件损坏或内存不够"))
            }
            let request = URLRequest(url: health, timeoutInterval: 2)
            let response = try? await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard process === p, p.isRunning else { throw CancellationError() }
            if (response?.1 as? HTTPURLResponse)?.statusCode == 200 {
                ready = true
                return port
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        if process === p, p.isRunning, ready { return port }
        if process === p { stopNow() }
        throw ASRError.startFailed(String(localized: "转写模型等了五分钟还没就绪"))
    }

    func stop() {
        if busy { stopWhenIdle = true; return }
        stopNow()
    }

    func stopIfIdle() {
        guard !busy else { return }
        stopNow()
    }

    private func stopNow() {
        stopWhenIdle = false
        ready = false
        identity = nil
        process?.terminate()
        process = nil
    }

    private func acquire() async throws {
        while busy {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        busy = true
    }

    private func release() {
        if stopWhenIdle { stopNow() }
        busy = false
    }

    // MARK: 转写

    private enum Backend {
        case server(port: Int, selection: AppSettings.LocalASRModel)
        case funASR(FunASR.Invocation)
    }

    private func prepare(serverPath: String, selection: AppSettings.LocalASRModel) async throws -> Backend {
        if let model = selection.funASR {
            stopNow()
            return .funASR(try FunASR.validateInstallation(model))
        }
        return .server(port: try await ensureRunning(serverPath: serverPath, selection: selection), selection: selection)
    }

    /// 提前把模型装进内存。语音输入在按下按键时调用，松手时就不用等加载了。
    func warmUp(serverPath: String, selection: AppSettings.LocalASRModel = .qwen) async {
        do {
            try await acquire()
            defer { release() }
            _ = try await prepare(serverPath: serverPath, selection: selection)
        } catch {}
    }

    /// 转一小段已经在内存里的声音（16 kHz 单声道），用于语音输入。
    func transcribe(samples: [Float], serverPath: String, selection: AppSettings.LocalASRModel = .qwen) async throws -> String {
        try await acquire()
        defer { release() }
        let backend = try await prepare(serverPath: serverPath, selection: selection)
        var parts: [String] = []
        for c in Self.chunk(samples) {
            try Task.checkCancellation()
            let piece = Array(samples[c])
            guard Self.rms(piece) > 0.0015 else { continue }
            let text = try await recognize(Self.wav(piece), with: backend)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined()
    }

    func transcribe(_ url: URL, serverPath: String, selection: AppSettings.LocalASRModel = .qwen, progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        try await acquire()
        defer { release() }
        let backend = try await prepare(serverPath: serverPath, selection: selection)
        let samples = try Self.loadMono16k(url)
        // 按停顿切成一句一句的，每句都有自己的时间，方便点着听、标说话人
        let chunks = Self.sentenceChunks(samples)
        var out: [Segment] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(chunks.count))
            let piece = Array(samples[c])
            // 几乎没有声音的片段直接跳过，模型在静音上容易凭空编字
            guard BeanStore.hasSpeech(piece) else { continue }
            let text = try await recognize(Self.wav(piece), with: backend)
            if !text.isEmpty, !BeanStore.isFiller(text) { out.append(Segment(start: Double(c.lowerBound) / 16000, text: text)) }
        }
        progress(1)
        return out
    }

    private func recognize(_ wav: Data, with backend: Backend) async throws -> String {
        switch backend {
        case let .server(port, selection): try await recognize(wav, port: port, selection: selection)
        case let .funASR(invocation): try await FunASR.transcribe(wav, invocation: invocation)
        }
    }

    private func recognize(_ wav: Data, port: Int, selection: AppSettings.LocalASRModel) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var content: [[String: Any]] = [["type": "input_audio", "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]]
        if selection == .gemma {
            content.insert(["type": "text", "text": "Transcribe the audio verbatim in its original language. For Chinese speech, use Simplified Chinese characters. Output only the transcription, without explanations, labels, timestamps, or translations."], at: 0)
        }
        let body: [String: Any] = [
            "temperature": 0, "max_tokens": 512,
            "messages": [["role": "user", "content": content]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ASRError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        if selection == .qwen { return Self.clean(content) }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return selection == .gemma ? ChineseScript.simplified(text) : text
    }

    nonisolated static func clean(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "<asr_text>") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "</asr_text>") { s = String(s[..<r.lowerBound]) }
        return s.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
