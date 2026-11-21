import Foundation

// Compile with the production CloudASR.swift and Settings.swift. All persistence,
// keys, audio input, and network responses below are isolated test doubles.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
}
enum Keychain {
    static func migrate(_ key: String) -> String { "" }
    static func set(_ value: String, for key: String) {}
}
nonisolated enum Profession: String { case general }
nonisolated enum TranslateStyle: String { case general }
nonisolated enum FunASRModel { case paraformer, nano }
nonisolated struct LLMConfig {
    enum Source { case miBox }
    var baseURL: String
    var model: String
    var key: String
    var source: Source
}
nonisolated struct Segment: Sendable {
    var start: Double
    var text: String
}
nonisolated enum QwenASR {
    static func loadMono16k(_ url: URL) throws -> [Float] {
        [Float](repeating: 0, count: 301 * 16000)
    }
    static func chunk(_ samples: [Float]) -> [Range<Int>] {
        [0..<(300 * 16000), (300 * 16000)..<samples.count]
    }
    static func wav(_ samples: [Float]) -> Data { Data(repeating: 0, count: 44 + samples.count * 2) }
}

nonisolated final class MockASRProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [(url: String, body: String, authorization: String)] = []
    nonisolated(unsafe) static var rejectFirst = false

    static func reset(rejectFirst: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        requests = []
        self.rejectFirst = rejectFirst
    }

    static func captured() -> [(url: String, body: String, authorization: String)] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        let code = Self.rejectFirst && Self.requests.isEmpty ? 400 : 200
        Self.requests.append((request.url!.absoluteString, String(decoding: data, as: UTF8.self), request.value(forHTTPHeaderField: "Authorization") ?? ""))
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((code == 400 ? "unsupported rich format" : "{\"text\":\"中文转写。\"}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct CloudASRLanguageChecks {
    @MainActor static func main() async throws {
        let englishModel = "XingChenAGI/Xing-Audio4.0-ASR-Preview"
        let chineseModel = "XingChenAGI/XingChenASR-V3.2-Ultra"
        let endpoint = "https://api.siliconflow.cn/v1"
        let settings = AppSettings()
        settings.asrBaseURL = endpoint
        settings.asrModel = englishModel
        settings.asrKey = "synthetic-test-key"

        for language in ["zh-CN", "zh-TW", "zh", "zh-Hant-TW", "ZH_cn", "yue", "yue-CN"] {
            settings.language = language
            precondition(settings.asrConfig?.model == chineseModel, "Chinese language must resolve: \(language)")
            precondition(settings.asrModel == englishModel, "Entered model must remain intact")
            precondition(UserDefaults.standard.string(forKey: "asrModel") == englishModel)
            precondition(settings.asrConfig?.baseURL == endpoint && settings.asrConfig?.key == "synthetic-test-key")
            print("PASS effective Chinese model: \(language)")
        }
        for language in ["en", "en-US", "ja-JP", "", "zho", "yuex"] {
            settings.language = language
            precondition(settings.asrConfig?.model == englishModel)
            print("PASS untouched language: \(language)")
        }
        settings.language = "zh-CN"
        for model in [chineseModel, "FunAudioLLM/SenseVoiceSmall", "whisper-1", "XingChenAGI/XingChenASR-V3.2", englishModel.lowercased()] {
            settings.asrModel = model
            precondition(settings.asrConfig?.model == model)
            print("PASS untouched model: \(model)")
        }
        settings.asrModel = englishModel
        for host in ["api.openai.com", "api.siliconflow.com", "api.siliconflow.cn.example.com", "localhost"] {
            settings.asrBaseURL = "https://\(host)/v1"
            precondition(settings.asrConfig?.model == englishModel)
            print("PASS untouched host: \(host)")
        }
        settings.asrBaseURL = endpoint
        settings.miBoxASRBaseURL = endpoint
        settings.miBoxASRModel = englishModel
        precondition(settings.miBoxASRConfig?.model == englishModel)
        print("PASS MiBox remains separate")
        settings.asrModel = ""
        precondition(settings.asrConfig == nil)
        settings.asrModel = englishModel

        precondition(URLProtocol.registerClass(MockASRProtocol.self))
        defer { URLProtocol.unregisterClass(MockASRProtocol.self) }
        let config = settings.asrConfig!
        MockASRProtocol.reset(rejectFirst: true)
        let segments = try await CloudASR.transcribe(URL(fileURLWithPath: "/synthetic.wav"), config: config, language: settings.language) { _ in }
        let requests = MockASRProtocol.captured()
        precondition(requests.count == 3, "Expected rich attempt, plain retry, second batch")
        precondition(segments.count == 2 && segments.last?.start == 300)
        for request in requests {
            precondition(request.url == endpoint + "/audio/transcriptions")
            precondition(request.authorization == "Bearer synthetic-test-key")
            precondition(request.body.contains("\r\n\r\n" + chineseModel + "\r\n"))
            precondition(!request.body.contains(englishModel))
        }
        print("PASS mocked batch/retry: 3 requests, effective model, original endpoint/key, 2 segments")

        for language in ["zh-CN", "en-US"] {
            settings.language = language
            let effective = settings.asrConfig!
            MockASRProtocol.reset()
            try await CloudASR.test(effective)
            let requests = MockASRProtocol.captured()
            precondition(requests.count == 1)
            precondition(requests[0].body.contains("\r\n\r\n" + effective.model + "\r\n"))
            precondition(!requests[0].body.contains("name=\"language\""))
            precondition(!requests[0].body.contains("name=\"prompt\""))
            print("PASS test button request: \(language) uses \(effective.model)")
        }
        print("PASS all cloud language checks; no real credentials or network used")
    }
}
