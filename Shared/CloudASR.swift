@preconcurrency import AVFoundation
import Foundation

/// 云端转写要连的服务。
nonisolated struct ASRConfig: Sendable, Equatable {
    var baseURL: String
    var model: String
    var key: String
    enum API: Sendable { case automatic, openAI }
    var api: API = .automatic
}

nonisolated enum CloudASRError: LocalizedError {
    case badURL, miniMaxTextOnly, http(Int, String), noText, malformedResponse

    var errorDescription: String? {
        switch self {
        case .badURL: String(localized: "云端转写的接口地址不对")
        case .miniMaxTextOnly: String(localized: "MiniMax 文本接口可以用于整理，但没有录音转写接口。请选择本机转写，或配置小米 MiMo 等支持转写的服务。")
        case .http(let code, let body):
            switch code {
            case 401, 403: String(localized: "云端转写的密钥不对，或者没有权限（\(code)）")
            case 429: String(localized: "云端转写被限流了，过一会儿再试（429）")
            case 404: String(localized: "这个地址没有转写接口（404）。检查一下接口地址，或者在设置里换一家能转写的服务。")
            default: String(localized: "云端转写返回错误 \(code)：\(String(body.prefix(160)))")
            }
        case .noText: String(localized: "云端转写没有返回文字")
        case .malformedResponse: String(localized: "密盒转写返回的数据格式不对，请检查接口地址是否为兼容 OpenAI 的转写服务。")
        }
    }
}

/// 把录音发给云端转成文字。手机上跑不动本机模型，所以转写走这里；Mac 上也可以用。
///
/// 接的是 OpenAI 那套「/audio/transcriptions」接口，很多服务商都兼容。
/// 长录音切成不超过五分钟的段，逐段上传；每段先压成小文件再传，省流量。
/// 服务商给不给时间戳不一定：给了就用它的分句，没给就按标点自己分句、按字数估时间。
nonisolated enum CloudASR {
    static let presets: [(name: String, url: String, model: String)] = [
        (String(localized: "小米 MiMo"), "https://api.xiaomimimo.com/v1", "mimo-v2.5-asr"),
        (String(localized: "硅基流动"), "https://api.siliconflow.cn/v1", "FunAudioLLM/SenseVoiceSmall"),
        ("OpenAI", "https://api.openai.com/v1", "whisper-1"),
        ("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3-turbo"),
    ]

    static let batchSeconds = 300

    static func isSiliconFlowEnglishModel(baseURL: String, model: String) -> Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "api.siliconflow.cn"
            && model == "XingChenAGI/Xing-Audio4.0-ASR-Preview"
    }

    static func effectiveModel(baseURL: String, model: String, language: String) -> String {
        let primaryLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        guard isSiliconFlowEnglishModel(baseURL: baseURL, model: model),
              primaryLanguage == "zh" || primaryLanguage == "yue" else { return model }
        return "XingChenAGI/XingChenASR-V3.2-Ultra"
    }

    static func transcribe(_ url: URL, config: ASRConfig, language: String,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> [Segment] {
        try validateProvider(config)
        let samples = try QwenASR.loadMono16k(url)
        // 先沿着安静的地方切成小段，再把相邻的小段并成不超过五分钟的一批，这样不会把一句话切在两批中间
        var batches: [Range<Int>] = []
        for piece in QwenASR.chunk(samples) {
            if let last = batches.last, piece.upperBound - last.lowerBound <= batchSeconds * 16000 {
                batches[batches.count - 1] = last.lowerBound..<piece.upperBound
            } else {
                batches.append(piece)
            }
        }
        var out: [Segment] = []
        var plain = false   // 这家不认压缩格式或带时间戳的返回时，退回最朴素的请求
        for (n, range) in batches.enumerated() {
            let piece = Array(samples[range])
            let offset = Double(range.lowerBound) / 16000
            var segments: [Segment]
            do {
                segments = try await request(piece, config: config, language: language, rich: !plain)
            } catch CloudASRError.http(let code, _) where !plain && (400..<500).contains(code) && ![401, 403, 429].contains(code) {
                plain = true
                segments = try await request(piece, config: config, language: language, rich: false)
            }
            out += segments.map { Segment(start: $0.start + offset, text: $0.text) }
            progress(Double(n + 1) / Double(batches.count))
        }
        return out.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 试一下这家能不能用：发两秒很轻的噪声过去，只看它肯不肯收。
    static func test(_ config: ASRConfig) async throws {
        try validateProvider(config)
        var noise = [Float](repeating: 0, count: 32000)
        for i in noise.indices { noise[i] = Float.random(in: -0.002...0.002) }
        do { _ = try await request(noise, config: config, language: "zh", rich: false) }
        catch CloudASRError.noText { /* 噪声里本来就没有话，能走到这一步说明接口是通的 */ }
    }

    private static func validateProvider(_ config: ASRConfig) throws {
        let address = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: address)?.host?.lowercased() else { return }
        if ["api.minimaxi.com", "api.minimax.cn", "api.minimax.io"].contains(host) {
            throw CloudASRError.miniMaxTextOnly
        }
    }

    // MARK: 一次请求

    /// 小米 MiMo 没有「/audio/transcriptions」（会回 404），转写走对话接口：把音频放进 user 消息，模型用 mimo-v2.5-asr。
    static func isMiMo(_ baseURL: String) -> Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.hasSuffix("xiaomimimo.com") == true
    }

    /// MiMo 填成了对话模型（比如 mimo-v2.6-pro）时，转写还是用它的转写模型。
    static func mimoModel(_ model: String) -> String {
        model.lowercased().contains("asr") ? model : "mimo-v2.5-asr"
    }

    private static func requestMiMo(_ samples: [Float], config: ASRConfig) async throws -> [Segment] {
        guard let endpoint = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions") else {
            throw CloudASRError.badURL
        }
        let seconds = Double(samples.count) / 16000
        // 只收 wav 和 mp3；user 消息里只能放音频，不能带文字
        let audio: [String: Any] = ["type": "input_audio", "input_audio": ["data": QwenASR.wav(samples).base64EncodedString(), "format": "wav"]]
        let payload: [String: Any] = ["model": mimoModel(config.model), "messages": [["role": "user", "content": [audio]]]]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudASRError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw CloudASRError.noText
        }
        // 没有时间戳：按标点分句、按字数估时间
        return sentences(clean(text), seconds: seconds)
    }

    private static func request(_ samples: [Float], config: ASRConfig, language: String, rich: Bool) async throws -> [Segment] {
        if config.api == .automatic, isMiMo(config.baseURL) { return try await requestMiMo(samples, config: config) }
        guard let endpoint = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/audio/transcriptions") else {
            throw CloudASRError.badURL
        }
        let seconds = Double(samples.count) / 16000
        var audio = QwenASR.wav(samples), name = "audio.wav", mime = "audio/wav"
        if rich, let small = m4a(samples) { audio = small; name = "audio.m4a"; mime = "audio/m4a" }

        let boundary = "beanpod-" + UUID().uuidString
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", config.model)
        field("response_format", rich ? "verbose_json" : "json")
        let lang = String(language.prefix(2)).lowercased()
        if rich, ["zh", "en", "ja", "ko"].contains(lang) { field("language", lang) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CloudASRError.http(code, String(decoding: data, as: UTF8.self)) }
        return try parse(data, seconds: seconds, requireJSON: config.api == .openAI)
    }

    /// 读返回：有分句和时间就用；只有一整段文字就自己分句。
    static func parse(_ data: Data, seconds: Double, requireJSON: Bool = false) throws -> [Segment] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if requireJSON { throw CloudASRError.malformedResponse }
            // 有的服务直接回纯文字
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CloudASRError.noText }
            return sentences(text, seconds: seconds)
        }
        let list = object["segments"] as? [[String: Any]]
        if requireJSON {
            guard object["error"] == nil else { throw CloudASRError.malformedResponse }
            if !(object["text"] is String) {
                guard let list, list.allSatisfy({ $0["text"] is String }) else { throw CloudASRError.malformedResponse }
            }
        }
        if let list, !list.isEmpty {
            let segments = list.compactMap { item -> Segment? in
                guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let start = (item["start"] as? Double) ?? (item["start"] as? NSNumber)?.doubleValue ?? 0
                return Segment(start: start, text: clean(text))
            }
            if !segments.isEmpty { return segments }
        }
        guard let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw CloudASRError.noText
        }
        return sentences(clean(text), seconds: seconds)
    }

    /// 有的模型会在文字里夹「<|zh|><|NEUTRAL|>」这类标记，去掉。
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 没有时间戳时：按句末标点分句，每句的开始时间按它前面有多少字来估。
    static func sentences(_ text: String, seconds: Double) -> [Segment] {
        var parts: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?\n".contains(ch) || (current.count >= 60 && "，,；; ".contains(ch)) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append(rest) }
        let total = max(1, parts.reduce(0) { $0 + $1.count })
        var seen = 0
        return parts.map { part in
            defer { seen += part.count }
            return Segment(start: seconds * Double(seen) / Double(total), text: part)
        }
    }

    /// 压成小文件再传：五分钟的声音从九兆多压到一兆出头。压不了就返回 nil，改传原样的 WAV。
    private static func m4a(_ samples: [Float]) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-asr-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            // 文件要等写入器释放才算写完，所以放在一个单独的作用域里
            try {
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }()
        } catch { return nil }
        guard let data = try? Data(contentsOf: url), data.count > 1000 else { return nil }
        return data
    }
}
