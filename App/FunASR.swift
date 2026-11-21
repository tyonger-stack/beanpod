import Foundation
import Darwin

nonisolated enum FunASR {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let model: FunASRModel
    }

    static func modelInstalled(_ model: FunASRModel) -> Bool {
        model.files.allSatisfy { file in
            let url = model.directory.appendingPathComponent(file.name)
            guard !DownloadJob.externalDownload(url),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.size,
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
        }
    }

    static func locateExecutable(_ model: FunASRModel) -> URL? {
        let helper = model == .nano ? "llama-funasr-cli" : "llama-funasr-paraformer"
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(helper)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func validateInstallation(_ model: FunASRModel) throws -> Invocation {
        guard let executable = locateExecutable(model) else { throw Failure.missingRuntime }
        guard modelInstalled(model) else { throw ASRError.noModel }
        let weights = model.files.map { model.directory.appendingPathComponent($0.name).path }
        let args = switch model {
        case .paraformer: ["-m", weights[0]]
        case .nano: ["--enc", weights[0], "-m", weights[1], "--chunk", "15"]
        }
        return Invocation(executable: executable, arguments: args, model: model)
    }

    static func transcribe(_ wav: Data, invocation: Invocation) async throws -> String {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-funasr-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.wav")
        try wav.write(to: audio)
        let stdoutURL = folder.appendingPathComponent("stdout.txt"), stderrURL = folder.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments + ["-a", audio.path]
        if invocation.model == .nano {
            var environment = ProcessInfo.processInfo.environment
            environment["GGML_METAL_DEVICES"] = "0"
            process.environment = environment
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw Failure.startFailed(error.localizedDescription) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch {
            await terminate(process)
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw Failure.exited(process.terminationStatus, String(readOutput(stderrURL).prefix(600)))
        }
        let output = readOutput(stdoutURL)
        return cleanOutput(invocation.model == .nano ? output.replacingOccurrences(of: "/sil", with: "") : output)
    }

    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        // A cancelled Task cannot sleep; a separate task gives the process time to exit before SIGKILL.
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        }.value
    }

    private static func readOutput(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        return String(decoding: (try? file.read(upToCount: 1_048_576)) ?? Data(), as: UTF8.self)
    }

    static func cleanOutput(_ output: String) -> String {
        output.components(separatedBy: .newlines).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            guard !text.isEmpty,
                  !["[paraformer]", "ggml_", "gguf_", "llama_", "usage:", "error:", "warning:"]
                    .contains(where: { lower.hasPrefix($0) }) else { return nil }
            return text
        }.joined(separator: " ")
    }

    enum Failure: LocalizedError {
        case missingRuntime, startFailed(String), timedOut, exited(Int32, String)

        var errorDescription: String? {
            switch self {
            case .missingRuntime: String(localized: "应用中缺少 FunASR 转写程序，请重新安装完整版本。")
            case .startFailed(let reason): String(localized: "FunASR 转写程序启动失败：\(reason)")
            case .timedOut: String(localized: "FunASR 转写超过五分钟，请稍后重试。")
            case .exited(let code, let detail): String(localized: "FunASR 转写失败（\(code)）：\(detail)")
            }
        }
    }
}
