import Foundation

/// 一份译文：一句对一句，和文字稿的分句一一对应。
nonisolated struct Translation: Codable, Equatable {
    var language: String
    var style: String
    /// 和 segments 一样长；只有整段文字、没有分句的录音，这里只有一条。
    var lines: [String]
    var model: String
    var date = Date()
}

/// 翻译风格。参考沉浸式翻译里分场景的做法：同一句话，科技文章、小说、论坛帖子该怎么译不一样。
nonisolated enum TranslateStyle: String, CaseIterable, Identifiable, Codable {
    case general, tech, fiction, academic, news, forum, spoken, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: String(localized: "通用")
        case .tech: String(localized: "科技")
        case .fiction: String(localized: "小说")
        case .academic: String(localized: "学术文献")
        case .news: String(localized: "新闻")
        case .forum: String(localized: "社交论坛")
        case .spoken: String(localized: "口播字幕")
        case .custom: String(localized: "自定义")
        }
    }

    var hint: String {
        switch self {
        case .general: String(localized: "准确、通顺，读起来像中文母语者写的。")
        case .tech: String(localized: "术语、产品名、代码和 API 名保留原文，第一次出现时括注中文。")
        case .fiction: String(localized: "保留人物口吻、语气和节奏，文学性优先。")
        case .academic: String(localized: "术语规范、句式严谨，长句可拆分，不加主观发挥。")
        case .news: String(localized: "简洁客观，人名地名用通行译法。")
        case .forum: String(localized: "像 Reddit、推特这样的帖子：口语化，梗和语气要对上，缩写意译。")
        case .spoken: String(localized: "短句、适合朗读，便于做字幕或配音。")
        case .custom: String(localized: "用你在设置里写的提示词。")
        }
    }

    /// 给模型的风格要求。
    var instruction: String {
        switch self {
        case .general:
            "译文准确、通顺、自然，符合目标语言的表达习惯，不要翻译腔。"
        case .tech:
            "这是科技类内容。专业术语、产品名、公司名、代码、命令、API 名保留英文原样，必要时在第一次出现处用括号给出译名；数字和单位照原样；语气专业但不生硬。"
        case .fiction:
            "这是叙事或文学内容。保留人物的口吻、情绪和节奏，对话要像真人说话；修辞和意象尽量保留，可以为了自然而调整语序，但不能增删情节。"
        case .academic:
            "这是学术或研究类内容。术语使用学界通行译法，必要时括注原文；句子严谨、逻辑关系清楚，长句可以拆开，但不得改变论证；不加任何主观评论。"
        case .news:
            "这是新闻资讯。简洁、客观、信息密度高；人名、地名、机构名用通行译法；时间和数字准确。"
        case .forum:
            "这是社交媒体或论坛内容（比如 Reddit、推特、YouTube 评论区）。用目标语言里自然的网络口语，保留语气、调侃和情绪；梗和俚语换成目标语言里意思相近的说法，不要直译；TL;DR、IMO、AFAIK 这类缩写意译。"
        case .spoken:
            "这是口播或视频字幕。译成短句，适合朗读和上屏；口语化，去掉不影响意思的语气词和重复。"
        case .custom:
            ""
        }
    }
}

/// 常用的目标语言。
nonisolated let translateLanguages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"]

extension BeanStore {
    /// 文字稿看起来是不是已经是目标语言：按字符粗算，中文目标看汉字占比，其他看拉丁字母和假名。
    nonisolated static func looksLike(_ text: String, language: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count > 20 else { return true }
        let han = letters.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }.count
        let hangul = letters.filter { (0xAC00...0xD7AF).contains($0.value) }.count
        let latin = letters.filter { $0.isASCII }.count
        let n = Double(letters.count)
        switch language {
        case "简体中文", "繁體中文": return Double(han) / n > 0.5
        case "日本語": return Double(kana + han) / n > 0.5 && kana > 0
        case "한국어": return Double(hangul) / n > 0.5
        default: return Double(latin) / n > 0.6
        }
    }

    /// 这条需不需要翻译：有文字稿、还没译成目标语言、原文不是目标语言。
    func needsTranslation(_ r: Recording) -> Bool {
        guard let text = r.transcript, !text.isEmpty else { return false }
        if let t = r.translation, t.language == settings.translateTo { return false }
        return !Self.looksLike(text, language: settings.translateTo)
    }

    /// 把一条录音的文字稿逐句译成目标语言。用的是整理纪要的那个模型（云端优先，按设置来）。
    func translate(_ rid: UInt32, to language: String? = nil, style: TranslateStyle? = nil) {
        guard let rec = recordings.first(where: { $0.id == rid }), translating[rid] == nil, analysisAvailable else { return }
        let language = language ?? settings.translateTo
        let style = style ?? settings.translateStyle
        let lines: [String] = rec.segments.isEmpty ? [rec.transcript ?? ""] : rec.segments.map { $0.clean ?? $0.text }
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        let requirement = style == .custom && !settings.translatePrompt.trimmingCharacters(in: .whitespaces).isEmpty
            ? settings.translatePrompt : style.instruction
        let context = [rec.displayTitle, rec.origin].compactMap { $0 }.joined(separator: "，")
        translating[rid] = 0
        addLog("开始翻译 \(rid)：\(lines.count) 句 → \(language)（\(style.name)）")
        Task {
            defer { translating[rid] = nil }
            do {
                var out: [String] = []
                var model = ""
                // 一批四十句左右、两千五百字以内，分批送：一次塞太多，模型容易漏行或串行
                for batch in Self.batches(lines) {
                    let numbered = batch.enumerated().map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
                    let (reply, used) = try await withLLM { config in
                        (try await Analyzer.chat(config,
                            system: """
                            你是专业译者。把用户给的每一行译成\(language)。\(requirement)
                            这些句子来自同一段音视频的文字稿（\(context)），前后连贯，按上下文理解指代和省略。
                            输出格式必须严格是：和输入同样多的行，每行以「序号. 」开头，后面只写这一行的译文。不要合并、拆分或跳过任何一行，不要加解释。
                            原文已经是\(language)的行，照抄原文。
                            """,
                            user: numbered, json: false), config.model)
                    }
                    model = used
                    let parsed = Self.parseNumbered(Analyzer.stripThinking(reply), count: batch.count)
                    out += zip(batch, parsed).map { $1.isEmpty ? $0 : $1 }   // 某一行没译出来就留原文，不让整份失败
                    translating[rid] = Double(out.count) / Double(lines.count)
                }
                guard let i = recordings.firstIndex(where: { $0.id == rid }) else { return }
                let current = recordings[i]
                let currentLines = current.segments.isEmpty ? [current.transcript ?? ""] : current.segments.map { $0.clean ?? $0.text }
                guard currentLines == lines, current.segments.map(\.start) == rec.segments.map(\.start) else { return }
                recordings[i].translation = Translation(language: language, style: style.name, lines: out, model: model)
                saveLibrary()
                addLog("翻译完成 \(rid)：\(out.count) 句，模型 \(model)")
                toast("character.bubble", String(localized: "翻译好了：\(String(rec.displayTitle.prefix(16)))"))
            } catch {
                problem = Problem(title: String(localized: "没能翻译"), detail: error.localizedDescription)
            }
        }
    }

    func clearTranslation(_ rid: UInt32) {
        guard let i = recordings.firstIndex(where: { $0.id == rid }) else { return }
        recordings[i].translation = nil
        saveLibrary()
    }

    nonisolated static func batches(_ lines: [String]) -> [[String]] {
        var out: [[String]] = [], cur: [String] = [], size = 0
        for l in lines {
            if !cur.isEmpty, cur.count >= 40 || size + l.count > 2500 { out.append(cur); cur = []; size = 0 }
            cur.append(l); size += l.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 读「1. 译文」这样的回复，按序号放回原位；缺的行是空字符串。
    nonisolated static func parseNumbered(_ reply: String, count: Int) -> [String] {
        var out = [String](repeating: "", count: count)
        var last: Int?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let m = line.firstMatch(of: /^(\d{1,4})\s*[.、:：)]\s*(.*)$/), let n = Int(m.1), n >= 1, n <= count {
                out[n - 1] = String(m.2).trimmingCharacters(in: .whitespaces)
                last = n - 1
            } else if let k = last {
                out[k] += (out[k].isEmpty ? "" : " ") + line      // 模型把一行折成了两行：接上
            }
        }
        return out
    }
}
