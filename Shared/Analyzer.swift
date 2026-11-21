import Foundation

nonisolated struct Analysis: Sendable {
    var scene: Scene
    var title: String
    var summary: String
    var sections: [NoteSection]
    var todos: [String]
    var tags: [String]
    var people: [String]
    var source: String
}

nonisolated enum AnalyzerError: LocalizedError {
    case notConfigured, http(Int, String), badReply(String), unreachable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "还没有设置分析模型。")
        case .http(let code, let body): String(localized: "分析模型返回错误 \(code)：\(String(body.prefix(200)))")
        case .badReply(let why): String(localized: "分析模型的回答看不懂：\(why)")
        case .unreachable(let why): String(localized: "连不上分析模型：\(why)")
        }
    }
}

nonisolated struct LLMConfig: Sendable {
    var baseURL: String
    var model: String
    var key: String
    /// 豆仓自己起的本机模型。
    var builtIn = false
    enum Source: Sendable { case standard, miBox }
    var source: Source = .standard
}

/// 把文字稿整理成：场景、标题、摘要、分栏要点、待办、标签、人物。
nonisolated enum Analyzer {
    // MARK: 调模型

    static func chat(_ config: LLMConfig, system: String, user: String, json: Bool) async throws -> String {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/chat/completions") else {
            throw AnalyzerError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if config.builtIn { body["chat_template_kwargs"] = ["enable_thinking": false]; body["model"] = "local" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw AnalyzerError.unreachable(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AnalyzerError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AnalyzerError.badReply(String(localized: "没有 choices"))
        }
        return stripThinking(content)
    }

    /// 有些模型会把思考过程包在 <think> 里一起吐出来，去掉。
    static func stripThinking(_ text: String) -> String {
        var s = text
        while let a = s.range(of: "<think>"), let b = s.range(of: "</think>", range: a.upperBound..<s.endIndex) {
            s.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func listModels(baseURL: String, key: String) async -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/models") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 6)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: 整理

    static func analyze(transcript: String, duration: TimeInterval, profession: Profession, fixedScene: Scene?,
                        config: LLMConfig) async throws -> Analysis {
        // 长录音先分块压成要点，再整体整理，避免超出模型的上下文
        var material = transcript
        if transcript.count > 9000 {
            var notes: [String] = []
            for (i, chunk) in split(transcript, size: 6000).enumerated() {
                let note = try await chat(config,
                    system: "你在帮人整理一段长录音的文字稿。这是其中第 \(i + 1) 段。用\(NotesLanguage.promptName)列出这一段里的事实、观点、数字、人名、约定和待办，每条一行，不要评论，不要编造。",
                    user: chunk, json: false)
                notes.append("【第 \(i + 1) 段】\n" + note)
            }
            material = notes.joined(separator: "\n\n")
        }

        let sceneGuide = Scene.allCases.map { "- \($0.rawValue)（\($0.promptName)）：\($0.definition)。栏目：\($0.headings.joined(separator: "、"))" }
            .joined(separator: "\n")
        let sceneRule = fixedScene.map { "场景已经确定是 \($0.rawValue)，不要改。" }
            ?? "先判断场景，从下面的英文代号里选一个。"
        let system = """
        你是录音整理助手。使用者的职业是「\(profession.promptName)」，\(profession.promptFocus)

        \(sceneRule)
        \(sceneGuide)

        然后只输出一个 JSON 对象，不要任何别的文字：
        {
          "scene": "场景的英文代号",
          "title": "\(NotesLanguage.isEnglish ? "一句话英文标题，不超过 10 个单词" : "一句话标题，不超过 18 个字")，说清这段录音是什么事",
          "summary": "两到四句话的摘要，先说结论",
          "sections": [{"heading": "所选场景的栏目名", "items": ["这一栏下的要点，每条一句完整的话"]}],
          "todos": ["后续要做的事，写清谁、做什么、什么时候；没有就给空数组"],
          "tags": ["2 到 5 个主题标签，名词，不带 #"],
          "people": ["出现的人名或称呼；没有就给空数组"]
        }

        要求：
        - sections 必须使用所选场景的栏目名，某一栏没有内容就不要输出这一栏。
        - 只写录音里真有的内容。数字、金额、日期、人名照原样写，听不清的不要猜。
        - \(NotesLanguage.rule)
        """
        let user = "录音时长：\(promptDuration(duration))\n\n文字稿：\n\(material)"
        let reply = try await chat(config, system: system, user: user, json: true)
        return try parse(reply, fixedScene: fixedScene, source: config.source == .miBox ? String(localized: "密盒") + " · " + config.model : config.model)
    }

    static func parse(_ reply: String, fixedScene: Scene?, source: String) throws -> Analysis {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else {
            throw AnalyzerError.badReply(String(localized: "不是 JSON"))
        }
        func strings(_ any: Any?) -> [String] {
            (any as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let sceneText = (obj["scene"] as? String ?? "").lowercased()
        let scene = fixedScene ?? Scene(rawValue: sceneText) ?? Scene.allCases.first { $0.promptName == sceneText || $0.name == sceneText } ?? .other
        let summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AnalyzerError.badReply(String(localized: "没有摘要")) }
        let sections = (obj["sections"] as? [[String: Any]] ?? []).compactMap { s -> NoteSection? in
            let items = strings(s["items"])
            guard let heading = s["heading"] as? String, !items.isEmpty else { return nil }
            return NoteSection(heading: heading, items: items)
        }
        return Analysis(scene: scene,
                        title: String((obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)),
                        summary: summary, sections: sections, todos: strings(obj["todos"]),
                        tags: Array(strings(obj["tags"]).map { $0.replacingOccurrences(of: "#", with: "") }.prefix(6)),
                        people: Array(strings(obj["people"]).prefix(12)), source: source)
    }

    // MARK: 没有模型时的粗整理

    /// 只靠关键词猜场景、截取开头当摘要。结果很粗，界面上会标明。
    static func fallback(transcript: String, duration: TimeInterval, fixedScene: Scene?) -> Analysis {
        let scored = Scene.allCases.map { s in (s, s.keywords.reduce(0) { $0 + transcript.components(separatedBy: $1).count - 1 }) }
        var scene = scored.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? .other
        if scene == .other, duration < 90 { scene = .memo }
        let sentences = transcript.split(whereSeparator: { "。！？!?\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }
        return Analysis(scene: fixedScene ?? scene,
                        title: String((sentences.first ?? "").prefix(16)),
                        summary: sentences.prefix(2).joined(separator: "。") + (sentences.isEmpty ? "" : "。"),
                        sections: [], todos: [], tags: [], people: [], source: "关键词规则")
    }

    static func split(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let cut = rest.index(rest.startIndex, offsetBy: size)
            // 尽量在句号处断开
            let window = rest[rest.index(cut, offsetBy: -min(400, size / 4))..<cut]
            let at = window.lastIndex(where: { "。！？\n".contains($0) }).map { rest.index(after: $0) } ?? cut
            out.append(String(rest[..<at]))
            rest = rest[at...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    // MARK: 润色

    /// 把一句句口语理顺：去语气词和重复、补标点，意思和信息不动。句数和顺序保持不变，这样每句还能对上时间。
    static func polish(_ lines: [String], config: LLMConfig) async throws -> [String] {
        var out: [String] = []
        for batch in stride(from: 0, to: lines.count, by: 30).map({ Array(lines[$0..<min($0 + 30, lines.count)]) }) {
            let numbered = batch.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let reply = try await chat(config,
                system: """
                下面是一段录音的逐句文字稿，每行一句，前面有编号。请逐句整理成通顺的书面文字：
                - 去掉语气词和口头禅：呃、嗯、啊、哎、然后呢、就是、就是说、这个、那个、对应的、的话、怎么说呢、对吧。它们只是说话时的垫词时一律删掉；「这个」「那个」确实在指代东西时保留\n                - 去掉结巴和重复（「我我我」「去去去」「减减少」），一句话里说了两遍的意思只留一遍\n                - 说到一半改口的，只留改口之后的说法
                - 补好标点，改掉明显的同音错字
                - 不要增加原话里没有的内容，不要删掉任何信息，不要合并或拆分句子
                - 一句话被上下两行截断时，各行保持各自的内容，不要挪到别的行
                只输出一个 JSON 对象：{"lines": ["第 1 句整理后", "第 2 句整理后", …]}，数组长度必须和输入的行数相同。
                """,
                user: numbered, json: true)
            guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(reply[a...b].utf8)) as? [String: Any],
                  let cleaned = obj["lines"] as? [String], cleaned.count == batch.count else {
                throw AnalyzerError.badReply(String(localized: "润色结果的句数对不上"))
            }
            out += cleaned.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return out
    }

    // MARK: 改写

    static func rewrite(material: String, instruction: String, profession: Profession, config: LLMConfig) async throws -> String {
        try await chat(config,
            system: """
            你是一位文字编辑。使用者的职业是「\(profession.promptName)」。下面是他一段录音的内容，请按要求改写。
            要求：\(instruction)
            只用录音里有的事实、观点和例子，不要编造数据或经历。录音里的口语垫词不要带进成品。
            直接输出成品，不要解释你做了什么。
            """,
            user: material, json: false)
    }

    // MARK: 问知识库

    static func answer(question: String, context: [(title: String, text: String)], config: LLMConfig) async throws -> String {
        let material = context.enumerated().map { "[\($0.offset + 1)]《\($0.element.title)》\n\($0.element.text)" }.joined(separator: "\n\n")
        return try await chat(config,
            system: "你根据用户自己的录音记录回答问题。只用下面给出的材料，材料里没有就直说没有记录到，不要编。回答简洁，用提问所用的语言回答，在相关句子后面用 [编号] 标出依据。",
            user: "材料：\n\(material)\n\n问题：\(question)", json: false)
    }
}


/// 纪要用什么语言写（设置 → 通用 → 语言里的「纪要语言」）：默认跟着界面语言，也可以固定中文或英文。
/// 只管模型写的纪要、标题、摘要、待办、标签和长录音的分段要点；英语学习模式的讲解仍用中文（给中文母语者学英语用）。
nonisolated enum NotesLanguage {
    /// UserDefaults "notesLanguage"：auto（默认）/ zh-Hans / en
    static var isEnglish: Bool {
        switch UserDefaults.standard.string(forKey: "notesLanguage") ?? "auto" {
        case "en": return true
        case "zh-Hans": return false
        default: return (Bundle.main.preferredLocalizations.first ?? "zh-Hans").hasPrefix("en")
        }
    }

    static var promptName: String { isEnglish ? "英文（English）" : "简体中文" }

    /// 写进整理提示词的那一条要求
    static var rule: String {
        isEnglish
            ? "全部用英文（English）写：title、summary、sections 的 heading 和 items、todos、tags 都用英文；heading 把所选场景的栏目名译成英文。人名、专有名词照原样。"
            : "全部用简体中文。"
    }
}
