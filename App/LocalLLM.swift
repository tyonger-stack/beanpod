import Foundation

/// 豆仓自带的本机分析模型：和转写一样，用 llama-server 跑一个 GGUF 模型，只监听本机。
/// 用它整理纪要时，文字稿不出这台电脑。
actor LocalLLM {
    static let shared = LocalLLM()

    nonisolated static let gemmaFileName = "gemma-4-E2B-it-BF16.gguf"
    nonisolated static let gemmaProjectorName = "mmproj-gemma-4-E2B-it-BF16.gguf"

    nonisolated static func completeGemmaFile(_ url: URL) -> Bool {
        let fm = FileManager.default
        let expected = url.lastPathComponent == gemmaFileName ? 9_311_299_520 : 986_833_696
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
        return size == Int64(expected) && ![".partial", ".aria2", ".partial.aria2"].contains { fm.fileExists(atPath: url.path + $0) }
    }

    static let fileName = "Qwen3-4B-Q4_K_M.gguf"
    static let displayName = "Qwen3‑4B（本机）"
    static let downloadBase = "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/"
    static let downloadSize = 2_497_280_256.0

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Models/qwen3-4b", isDirectory: true)
    }

    /// 这个文件夹里随便放一个 GGUF 格式的对话模型就行，不要求文件名。
    /// 有多个时优先用默认的那个，否则取最大的。
    nonisolated static func modelURL(selection: AppSettings.LocalModel = .qwen) -> URL? {
        if selection == .gemma {
            let url = folder.appendingPathComponent(gemmaFileName)
            return completeGemmaFile(url) ? url : nil
        }
        let fm = FileManager.default
        let preferred = folder.appendingPathComponent(fileName)
        if fm.fileExists(atPath: preferred.path) { return preferred }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.lowercased().hasPrefix("mmproj") && !$0.lastPathComponent.lowercased().hasPrefix("gemma-4-e2b") }
            .max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    nonisolated static func modelLabel(selection: AppSettings.LocalModel = .qwen) -> String {
        modelURL(selection: selection).map { $0.deletingPathExtension().lastPathComponent + "（本机）" } ?? (selection == .gemma ? selection.analysisName : displayName)
    }

    private var process: Process?
    private var port = 0
    private var identity: [String]?
    private var label = ""
    private var ready = false
    private var startupDeadline = ContinuousClock.now
    private var busy = false
    private var stopWhenIdle = false

    /// 起服务并返回可以直接拿去调用的配置。
    private func ensureRunning(serverPath: String, selection: AppSettings.LocalModel) async throws -> LLMConfig {
        try Task.checkCancellation()
        guard let server = QwenASR.locateServer(custom: serverPath) else { throw ASRError.noServer }
        guard let model = Self.modelURL(selection: selection) else { throw AnalyzerError.notConfigured }

        let requested = [server.path, model.path]
        if identity == requested, let process, process.isRunning {
            if ready { return config }
            return try await waitUntilReady(process, port: port, deadline: startupDeadline)
        }
        stopNow()
        identity = requested
        label = Self.modelLabel(selection: selection)
        port = Int.random(in: 39901...39990)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 外面套一层 sh 盯着豆仓：豆仓退了它也退。--reasoning-budget 0 关掉模型的「先思考再回答」，整理纪要用不上，还慢。
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-llm", String(ProcessInfo.processInfo.processIdentifier), server.path,
                       "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                       "-c", "16384", "-np", "1", "--jinja", "--reasoning-budget", "0", "--log-disable"] + (selection == .gemma ? ["--chat-template-kwargs", #"{"enable_thinking":false}"#] : [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ASRError.startFailed(error.localizedDescription) }
        process = p

        startupDeadline = .now.advanced(by: .seconds(300))
        return try await waitUntilReady(p, port: port, deadline: startupDeadline)
    }

    private func waitUntilReady(_ p: Process, port: Int, deadline: ContinuousClock.Instant) async throws -> LLMConfig {
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process === p else { throw CancellationError() }
            guard p.isRunning else { throw ASRError.startFailed(String(localized: "本机分析模型没启动起来，可能是模型文件损坏或内存不够")) }
            let response = try? await URLSession.shared.data(for: URLRequest(url: health, timeoutInterval: 2))
            try Task.checkCancellation()
            guard process === p else { throw CancellationError() }
            guard p.isRunning else { throw ASRError.startFailed(String(localized: "本机分析模型没启动起来，可能是模型文件损坏或内存不够")) }
            if (response?.1 as? HTTPURLResponse)?.statusCode == 200 {
                ready = true
                return config
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        if process === p, p.isRunning, ready { return config }
        if process === p { stopNow() }
        throw ASRError.startFailed(String(localized: "本机分析模型等了五分钟还没就绪"))
    }

    private var config: LLMConfig {
        LLMConfig(baseURL: "http://127.0.0.1:\(port)/v1", model: label, key: "", builtIn: true)
    }

    func withRunning<T: Sendable>(serverPath: String, selection: AppSettings.LocalModel, work: @Sendable (LLMConfig) async throws -> T) async throws -> T {
        while busy {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        busy = true
        defer {
            if stopWhenIdle { stopNow() }
            busy = false
        }
        let config = try await ensureRunning(serverPath: serverPath, selection: selection)
        return try await work(config)
    }

    func stop() {
        if busy { stopWhenIdle = true; return }
        stopNow()
    }

    private func stopNow() {
        stopWhenIdle = false
        ready = false
        identity = nil
        process?.terminate()
        process = nil
    }
}
