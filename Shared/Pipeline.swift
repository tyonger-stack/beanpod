import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BeanKit
import Foundation

/// 录音下载之后的流水线：转写 → 判场景、出纪要。再加上知识库的检索、问答和导出。
extension BeanStore {
    // MARK: 流水线

    func refreshASRAvailability() {
        modelAvailabilityRevision += 1
    }

    /// 云端（或用户自己填的任何服务）的配置。
    var cloudConfig: LLMConfig? {
        settings.llmConfigured ? LLMConfig(baseURL: settings.llmBaseURL, model: settings.llmModel, key: settings.llmKey) : nil
    }

    /// 现在有没有能用的分析模型（云端配好了，或者本机模型下好了）。
    var analysisAvailable: Bool {
        switch settings.analysisMode {
        case .cloud: cloudConfig != nil
        case .local: localLLMReady
        case .auto: cloudConfig != nil || localLLMReady
        case .miBox: settings.miBoxLLMConfig != nil
        }
    }

    /// 按设置的先后顺序，挨个试能用的模型，直到有一个成功。
    func withLLM<T: Sendable>(_ work: @Sendable (LLMConfig) async throws -> T) async throws -> T {
        let mode = settings.analysisMode
        if mode == .miBox {
            guard let config = settings.miBoxLLMConfig else { throw MiBoxError.analysisNotConfigured }
            do { return try await work(config) }
            catch { throw MiBoxError.requestFailed(error.localizedDescription) }
        }
        let cloud = cloudConfig, localReady = localLLMReady
        let serverPath = settings.llamaServerPath, selection = settings.localAnalysisModel
        var lastError: Error = AnalyzerError.notConfigured
        if mode != .local, let cloud {
            do { return try await work(cloud) } catch {
                lastError = error
                addLog("云端分析模型失败：\(error.localizedDescription)")
            }
        }
        if mode != .cloud, localReady {
            do {
                return try await LocalLLM.shared.withRunning(serverPath: serverPath, selection: selection, work: work)
            } catch {
                lastError = error
                addLog("本机分析模型失败：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// 转写并整理一条录音。已有文字稿时只重新整理。
    func process(_ id: UInt32, retranscribe: Bool = false, cloud: Bool = false) {
        guard recordings.contains(where: { $0.id == id && $0.downloaded }), stages[id] == nil else { return }
        // 重新转写：旧文字稿先留着，新的转出来了再换；转失败了旧的还在
        if retranscribe { retranscribing.insert(id) }
        if cloud { viaCloud.insert(id) }
        stages[id] = .queued
        workQueue.append(id)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self {
                while !self.workQueue.isEmpty {
                    let next = self.workQueue.removeFirst()
                    await self.run(next)
                    self.retranscribing.remove(next)
                    self.viaCloud.remove(next)
                    self.stages[next] = nil
                    self.announceDone(next)
                    // 外语素材：整理完顺手译成目标语言
                    if self.settings.autoTranslate, let r = self.recordings.first(where: { $0.id == next }),
                       r.isMaterial, self.needsTranslation(r) {
                        self.translate(next)
                    }
                }
                await QwenASR.shared.stop()   // 干完活就把模型从内存里放掉
                await LocalLLM.shared.stop()
                // 停模型要等一会儿，这期间新排进来的录音看到 worker 还在就不会另起一个；
                // 所以停完再看一眼队列，空了才放手，免得把它晾在「排队中」
                if self.workQueue.isEmpty { self.worker = nil; return }
            }
        }
    }

    /// 豆仓现在是不是在前台。
    static var appIsActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// 一条录音整理好了。豆仓不在前台时发一条系统通知，点一下就打开那条录音。
    /// 窗口顶上滑出一句；豆仓不在最前面时（比如窗口关着、在用别的软件），同时发一条系统通知，免得错过。
    func announce(_ icon: String, _ text: String, body: String = "", seconds: Double = 5) {
        toast(icon, text, seconds: seconds)
        addLog("提示：\(text)")
        guard !Self.appIsActive else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = text
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: "bean-connect", content: content, trigger: nil))
        }
    }

    private func announceDone(_ id: UInt32) {
        guard !Self.appIsActive, let r = recordings.first(where: { $0.id == id }), r.isAnalyzed else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
        let title = r.displayTitle, summary = r.summary ?? "", todos = r.todos.count
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "整理好了：\(title)")
            content.body = (todos > 0 ? String(localized: "\(todos) 件待办。") : "") + summary
            content.sound = .default
            content.userInfo = ["recording": Int(id)]
            try? await center.add(UNNotificationRequest(identifier: "done-\(id)", content: content, trigger: nil))
        }
    }

    func processAllPending() {
        recordings.filter { $0.downloaded && !$0.isAnalyzed && !$0.isDictation }.forEach { process($0.id) }
    }

    private func index(_ id: UInt32) -> Int? { recordings.firstIndex { $0.id == id } }

    private func run(_ id: UInt32) async {
        guard let rec = recordings.first(where: { $0.id == id }) else { return }

        // 1. 转写
        if (rec.transcript ?? "").isEmpty || retranscribing.contains(id) {
            stages[id] = .transcribing(0)
            do {
                let segments: [Segment], engine: String
                refreshASRAvailability()
                let useMiBox = settings.engine == .miBox && !viaCloud.contains(id)
                if useMiBox || viaCloud.contains(id) || (settings.engine == .cloud && settings.asrConfig != nil) {
                    guard let asr = useMiBox ? settings.miBoxASRConfig : settings.asrConfig else {
                        if useMiBox { throw MiBoxError.transcriptionNotConfigured }
                        throw CloudASRError.badURL
                    }
                    // 云端转写：录音会发给用户自己填的那家服务商
                    segments = try await CloudASR.transcribe(wavURL(id), config: asr, language: settings.language) { fraction in
                        Task { @MainActor [weak self] in
                            if case .transcribing = self?.stages[id] { self?.stages[id] = .transcribing(fraction) }
                        }
                    }
                    engine = "\(useMiBox ? String(localized: "密盒") : "云端") · \(asr.model)"
                } else if settings.engine == .qwen, asrAvailable || settings.localASRModel.funASR != nil {
                    let selection = settings.localASRModel
                    if selection.funASR != nil, !asrAvailable {
                        throw ASRError.startFailed(localASRReadinessHint ?? String(localized: "本机转写程序还没准备好。"))
                    }
                    segments = try await QwenASR.shared.transcribe(wavURL(id), serverPath: settings.llamaServerPath, selection: selection) { fraction in
                        Task { @MainActor [weak self] in
                            if case .transcribing = self?.stages[id] { self?.stages[id] = .transcribing(fraction) }
                        }
                    }
                    engine = selection.asrName
                } else {
                    let text = try await Transcriber.transcribe(wavURL(id), language: settings.language)
                    segments = text.isEmpty ? [] : [Segment(start: 0, text: text)]
                    engine = "系统语音识别"
                }
                guard let i = index(id) else { return }
                recordings[i].segments = segments.map { Segment(start: $0.start, text: applyVocabulary($0.text)) }
                recordings[i].transcript = recordings[i].segments.map(\.text).joined(separator: "\n")
                recordings[i].translation = nil
                recordings[i].transcribedBy = engine
                saveLibrary()
            } catch {
                let kept = !(rec.transcript ?? "").isEmpty
                problem = Problem(title: String(localized: "「\(rec.displayTitle)」没转写出来"),
                                  detail: error.localizedDescription + (kept ? String(localized: "\n原来的文字稿和纪要都留着没动，可以再试一次。") : String(localized: "\n录音本身没问题，可以再试一次。")),
                                  action: .process(id))
                return
            }
        }

        // 2. 整理
        guard let i = index(id), let spoken = recordings[i].transcript else { return }
        // 录音时标过重点的句子，单独告诉分析模型：这些是说话人自己认为要紧的
        let flagged = Self.markedSentences(recordings[i])
        let transcript = flagged.isEmpty ? spoken
            : spoken + "\n\n【录音时用户特意标记为重点的句子，整理纪要时务必保留并优先体现】\n" + flagged.map { "- " + $0 }.joined(separator: "\n")
        guard transcript.count >= 8 else {
            recordings[i].summary = String(localized: "这条录音里没有识别到说话内容。")
            recordings[i].scene = recordings[i].scene ?? .other
            recordings[i].analyzedBy = "—"
            saveLibrary()
            return
        }
        let fixed = recordings[i].sceneLocked ? recordings[i].scene : nil
        stages[id] = .analyzing
        await QwenASR.shared.stop()
        var result: Analysis
        var analysisFailure: String?
        refreshASRAvailability()
        let useMiBoxAnalysis = settings.analysisMode == .miBox
        if analysisAvailable || useMiBoxAnalysis {
            let profession = settings.profession, duration = rec.duration
            do {
                result = try await withLLM { config in
                    return try await Analyzer.analyze(transcript: transcript, duration: duration, profession: profession, fixedScene: fixed, config: config)
                }
            } catch {
                if error is MiBoxError {
                    problem = Problem(title: String(localized: "「\(rec.displayTitle)」没出完整纪要"),
                                      detail: error.localizedDescription, action: .settings)
                    return
                }
                analysisFailure = error.localizedDescription
                problem = Problem(title: String(localized: "「\(rec.displayTitle)」没出完整纪要"), detail: String(localized: "这次未能生成完整纪要，先按关键词粗略分了类。\n原因：\(error.localizedDescription)\n可以在这条录音上点「重新整理纪要」重试，或在设置里更换分析模型。"), action: .settings)
                result = Analyzer.fallback(transcript: spoken, duration: rec.duration, fixedScene: fixed)
            }
        } else {
            result = Analyzer.fallback(transcript: spoken, duration: rec.duration, fixedScene: fixed)
        }
        guard let j = index(id) else { return }
        // 粗分结果不能覆盖已有模型纪要和待办。
        if result.source == "关键词规则", recordings[j].summary != nil,
           let before = recordings[j].analyzedBy, before != "关键词规则", before != "—" {
            problem = Problem(title: String(localized: "「\(rec.displayTitle)」这次没重新整理"),
                              detail: String(localized: "这次未能生成完整纪要，原来的纪要和待办都留着没动。可以点「重新整理纪要」重试，或在设置里更换分析模型。")
                                + (analysisFailure.map { String(localized: "\n原因：\($0)") } ?? ""),
                              action: .settings)
            return
        }
        recordings[j].scene = result.scene
        if !recordings[j].titleEdited, !result.title.isEmpty { recordings[j].title = result.title }
        recordings[j].summary = result.summary
        recordings[j].sections = result.sections
        // 重新整理时保留已经勾掉的待办
        let done = Set(recordings[j].todos.filter(\.done).map(\.text))
        recordings[j].todos = result.todos.map { Todo(text: $0, done: done.contains($0)) }
        if !recordings[j].tagsEdited { recordings[j].tags = result.tags }   // 自己改过的标签不覆盖
        recordings[j].people = result.people
        recordings[j].analyzedBy = result.source
        saveLibrary()

        // 3. 润色：每句出一个去掉语气词、理顺了的版本，原文照旧留着
        let raw = recordings[j].segments
        guard !raw.isEmpty, raw.contains(where: { $0.clean == nil }) else { return }
        guard result.source != "关键词规则" else {
            // 没有分析模型时，至少用规则把语气词去掉
            for n in recordings[j].segments.indices where recordings[j].segments[n].clean == nil {
                recordings[j].segments[n].clean = stripFillers(recordings[j].segments[n].text)
            }
            recordings[j].translation = nil
            saveLibrary()
            return
        }
        if let cleaned = try? await withLLM({ config in try await Analyzer.polish(raw.map(\.text), config: config) }),
           let k = index(id), recordings[k].segments.count == cleaned.count {
            for n in cleaned.indices where !cleaned[n].isEmpty && raw[n].clean == nil && recordings[k].segments[n] == raw[n] {
                recordings[k].segments[n].clean = applyVocabulary(cleaned[n])
                recordings[k].translation = nil
            }
            saveLibrary()
        }
    }

    // MARK: 文字稿的修改

    func applyVocabulary(_ text: String) -> String {
        settings.vocabulary.reduce(text) { $0.replacingOccurrences(of: $1.wrong, with: $1.right) }
    }

    /// 用户手动改了一句。如果只是把一个词换成了另一个词，就问他要不要全部替换并记住。
    func editSegment(_ id: UInt32, start: TimeInterval, to newText: String, clean: Bool) {
        guard let i = index(id), let n = recordings[i].segments.firstIndex(where: { $0.start == start }) else { return }
        let old = clean ? (recordings[i].segments[n].clean ?? recordings[i].segments[n].text) : recordings[i].segments[n].text
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != old, !text.isEmpty else { return }
        if clean {
            recordings[i].segments[n].clean = text
        } else {
            recordings[i].segments[n].text = text
            recordings[i].segments[n].clean = nil
        }
        recordings[i].translation = nil
        recordings[i].transcript = recordings[i].segments.map(\.text).joined(separator: "\n")
        saveLibrary()
        if let (wrong, right) = Self.changedSpan(from: old, to: text) {
            pendingFix = PendingFix(recording: id, wrong: wrong, right: right)
        }
    }

    /// 找出改动的那一小段：去掉两头相同的部分，剩下的就是「错的 → 对的」。改动太大或只是删字加字就不算。
    nonisolated static func changedSpan(from old: String, to new: String) -> (String, String)? {
        let a = Array(old), b = Array(new)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var wrong = String(a[head..<(a.count - tail)]), right = String(b[head..<(b.count - tail)])
        // 只改了一个字时，把前后各一个字带上，免得替换时误伤别的地方
        if wrong.count == 1, right.count >= 1, head > 0 {
            wrong = String(a[head - 1]) + wrong; right = String(a[head - 1]) + right
        }
        guard wrong.count >= 2, wrong.count <= 12, right.count >= 1, right.count <= 16, wrong != right else { return nil }
        return (wrong, right)
    }

    /// 把一个词全部换掉。remember：记进词库，以后转写出来自动改。everywhere：所有录音都改，否则只改这一条。
    @discardableResult
    func replaceWord(_ wrong: String, with right: String, in id: UInt32?, everywhere: Bool, remember: Bool) -> Int {
        guard !wrong.isEmpty, wrong != right else { return 0 }
        var count = 0
        for i in recordings.indices where everywhere || recordings[i].id == id {
            for n in recordings[i].segments.indices {
                count += recordings[i].segments[n].text.components(separatedBy: wrong).count - 1
                recordings[i].segments[n].text = recordings[i].segments[n].text.replacingOccurrences(of: wrong, with: right)
                recordings[i].segments[n].clean = recordings[i].segments[n].clean?.replacingOccurrences(of: wrong, with: right)
            }
            if !recordings[i].segments.isEmpty {
                recordings[i].transcript = recordings[i].segments.map(\.text).joined(separator: "\n")
            } else if let t = recordings[i].transcript {
                count += t.components(separatedBy: wrong).count - 1
                recordings[i].transcript = t.replacingOccurrences(of: wrong, with: right)
            }
        }
        if remember {
            settings.vocabulary.removeAll { $0.wrong == wrong }
            settings.vocabulary.append(.init(wrong: wrong, right: right))
        }
        saveLibrary()
        return count
    }

    // MARK: 说话人

    func setSpeaker(_ id: UInt32, start: TimeInterval, to speaker: Int?) {
        guard let i = index(id), let n = recordings[i].segments.firstIndex(where: { $0.start == start }) else { return }
        recordings[i].segments[n].speaker = speaker
        saveLibrary()
    }

    /// 新增一位说话人，并把这一句标给他。
    func addSpeaker(_ id: UInt32, start: TimeInterval) {
        guard let i = index(id) else { return }
        recordings[i].speakers.append(String(localized: "说话人 \(recordings[i].speakers.count + 1)"))
        setSpeaker(id, start: start, to: recordings[i].speakers.count - 1)
    }

    func renameSpeaker(_ id: UInt32, _ speaker: Int, to name: String) {
        guard let i = index(id), recordings[i].speakers.indices.contains(speaker) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { recordings[i].speakers[speaker] = n; saveLibrary() }
    }

    // MARK: 手动修改

    func setScene(_ id: UInt32, _ scene: Scene) {
        guard let i = index(id), recordings[i].scene != scene || !recordings[i].sceneLocked else { return }
        recordings[i].scene = scene
        recordings[i].sceneLocked = true
        saveLibrary()
        // 场景换了，栏目也跟着换，重新整理一遍
        if recordings[i].transcript != nil, analysisAvailable { process(id) }
    }

    func toggleTodo(_ id: UInt32, _ todo: UUID) {
        guard let i = index(id), let t = recordings[i].todos.firstIndex(where: { $0.id == todo }) else { return }
        recordings[i].todos[t].done.toggle()
        saveLibrary()
    }

    func toggleStar(_ id: UInt32) {
        guard let i = index(id) else { return }
        recordings[i].starred.toggle()
        saveLibrary()
    }

    // MARK: 知识库

    struct KnowledgeItem: Identifiable {
        let id: String
        let text: String
        let heading: String
        let recordingID: UInt32
        let title: String
        let scene: Scene
        let date: Date?
        let tags: [String]
    }

    /// 所有整理过的录音里抽出来的要点，就是知识库的全部内容，不用手动添加。
    var knowledge: [KnowledgeItem] {
        recordings.filter(\.isAnalyzed).flatMap { r in
            r.sections.flatMap { s in
                s.items.enumerated().map { n, item in
                    KnowledgeItem(id: "\(r.id)-\(s.heading)-\(n)", text: item, heading: s.heading, recordingID: r.id,
                                  title: r.displayTitle, scene: r.scene ?? .other, date: r.date, tags: r.tags)
                }
            }
        }
    }

    /// 所有标签和各自用在几条上，多的排前面（去掉井号，同一条里重复的只算一次）。
    var allTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in recordings {
            for t in Set(r.tags.map(Self.cleanTag)) where !t.isEmpty { counts[t, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { ($0.count, $1.tag) > ($1.count, $0.tag) }
    }

    var openTodos: [(recording: Recording, todo: Todo)] {
        recordings.flatMap { r in r.todos.filter { !$0.done }.map { (recording: r, todo: $0) } }
    }

    struct SearchHit: Identifiable {
        let id: String
        let recordingID: UInt32
        let title: String
        let scene: Scene
        let snippet: String
        let time: TimeInterval?
    }

    struct SearchFilter: Equatable {
        var scene: Scene?
        var person: String?
        /// 只看最近多少天，nil 是不限。
        var days: Int?
        var isEmpty: Bool { scene == nil && person == nil && days == nil }
    }

    var allPeople: [String] {
        Dictionary(recordings.flatMap(\.people).map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }.map(\.key)
    }

    /// 在标题、摘要、要点和文字稿里找，可以再按场景、人物、时间收窄。
    /// 文字稿的命中带时间，可以直接跳过去听。关键词留空时列出符合筛选条件的录音。
    func search(_ query: String, filter: SearchFilter = SearchFilter()) -> [SearchHit] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty || !filter.isEmpty else { return [] }
        let since = filter.days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: .now))! }
        var hits: [SearchHit] = []
        for r in knowledgeRecordings {
            let scene = r.scene ?? .other
            if let s = filter.scene, s != scene { continue }
            if let p = filter.person, !(r.people.contains(p) || (r.transcript ?? "").contains(p)) { continue }
            if let since, (r.date ?? .distantPast) < since { continue }
            if words.isEmpty {
                hits.append(SearchHit(id: "\(r.id)", recordingID: r.id, title: r.displayTitle, scene: scene,
                                      snippet: r.summary ?? String((r.transcript ?? "").prefix(80)), time: nil))
                continue
            }
            // 多个词要求都在这条录音里出现，再把每处命中列出来
            let whole = [r.displayTitle, r.summary ?? "", r.sections.flatMap(\.items).joined(separator: " "), r.transcript ?? "",
                         r.people.joined(separator: " "), r.tags.joined(separator: " ")].joined(separator: " ")
            guard words.allSatisfy({ whole.range(of: $0, options: .caseInsensitive) != nil }) else { continue }
            func add(_ text: String, _ key: String, time: TimeInterval? = nil) {
                guard let range = words.lazy.compactMap({ text.range(of: $0, options: .caseInsensitive) }).first else { return }
                let from = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
                let to = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
                hits.append(SearchHit(id: "\(r.id)-\(key)", recordingID: r.id, title: r.displayTitle, scene: scene,
                                      snippet: (from > text.startIndex ? "…" : "") + text[from..<to] + (to < text.endIndex ? "…" : ""), time: time))
            }
            let before = hits.count
            add(r.displayTitle, "title")
            if let s = r.summary { add(s, "summary") }
            for sec in r.sections { for (n, item) in sec.items.enumerated() { add(item, "\(sec.heading)\(n)") } }
            for seg in r.segments { add(seg.text, "seg\(seg.start)", time: seg.start) }
            if hits.count == before, r.segments.isEmpty, let t = r.transcript { add(t, "text") }
        }
        return hits
    }

    /// 问知识库：先按问题里的字词把相关的录音挑出来，再让分析模型只根据这些材料回答。
    func ask(_ question: String) {
        guard analysisAvailable, !asking else { return }
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let grams = Self.bigrams(q)
        let ranked = knowledgeRecordings.filter { $0.isAnalyzed || $0.isDictation }.map { r -> (Recording, Int) in
            let body = [r.displayTitle, r.summary ?? "", r.sections.flatMap(\.items).joined(separator: " "),
                        r.tags.joined(separator: " "), r.transcript ?? ""].joined(separator: " ")
            return (r, grams.reduce(0) { $0 + (body.contains($1) ? 1 : 0) })
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6)
        // 「最近聊了什么」「还有哪些没做的事」这类问题不带具体的词，按字面找不到：把最近的几条也带上
        let general = ["最近", "这几天", "这周", "本周", "今天", "昨天", "哪些", "总结", "待办", "没做", "答应"].contains { q.contains($0) }
        var picked = ranked.map(\.0)
        if general || picked.isEmpty {
            for r in knowledgeRecordings.filter({ $0.isAnalyzed || $0.isDictation }).prefix(8) where !picked.contains(where: { $0.id == r.id }) && picked.count < 8 { picked.append(r) }
        }
        guard !picked.isEmpty else { answer = String(localized: "记录里没有找到和这个问题相关的内容。"); answerSources = []; return }

        asking = true; answer = nil
        let context = picked.map { r in
            (title: r.displayTitle + (r.date.map { "（" + $0.formatted(date: .abbreviated, time: .omitted) + "）" } ?? ""),
             text: [r.summary ?? "", r.sections.map { "\($0.heading)：" + $0.items.joined(separator: "；") }.joined(separator: "\n"),
                    r.todos.isEmpty ? "" : "待办：" + r.todos.map { ($0.done ? "（已完成）" : "（未完成）") + $0.text }.joined(separator: "；"),
                    String((r.transcript ?? "").prefix(1500))].joined(separator: "\n"))
        }
        answerSources = picked.map(\.id)
        Task {
            defer { asking = false }
            do { answer = try await withLLM { config in try await Analyzer.answer(question: q, context: context, config: config) } }
            catch { answer = nil; notice = error.localizedDescription }
            if worker == nil { await LocalLLM.shared.stop() }
        }
    }

    nonisolated static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }

    // MARK: 导出

    func markdown(_ r: Recording) -> String {
        var md = "---\n"
        if let d = r.date { md += "date: \(d.formatted(.iso8601.year().month().day()))\n" }
        md += "scene: \((r.scene ?? .other).name)\n"
        md += "duration: \(clock(r.duration))\n"
        if !r.tags.isEmpty { md += "tags: [\(r.tags.joined(separator: ", "))]\n" }
        if !r.people.isEmpty { md += "people: [\(r.people.joined(separator: ", "))]\n" }
        md += "---\n\n# \(r.displayTitle)\n\n"
        if let s = r.summary { md += "\(s)\n\n" }
        for sec in r.sections { md += "## \(sec.heading)\n\n" + sec.items.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !r.todos.isEmpty { md += "## " + String(localized: "待办") + "\n\n" + r.todos.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n\n" }
        if !r.segments.isEmpty {
            md += "## " + String(localized: "文字稿") + "\n\n" + r.segments.map { "**\(clock($0.start))** \($0.text)" }.joined(separator: "\n\n") + "\n"
        }
        return md
    }

    #if os(macOS)
    /// 把整理过的录音各存成一个 Markdown 文件，可以直接放进 Obsidian 之类的笔记库。
    func exportMarkdown(_ items: [Recording]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "导出到这里")
        if !settings.exportFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: settings.exportFolder) }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        settings.exportFolder = folder.path
        var written = 0
        for r in items {
            let day = r.date.map { $0.formatted(.iso8601.year().month().day()) + " " } ?? ""
            let safe = (day + r.displayTitle).map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
            let url = folder.appendingPathComponent(String(safe) + ".md")
            if (try? markdown(r).write(to: url, atomically: true, encoding: .utf8)) != nil { written += 1 }
        }
        toast("checkmark.circle.fill", String(localized: "已导出 \(written) 个文件到「\(folder.lastPathComponent)」"))
    }
    #endif

    /// 重点标记落在哪几句话上。
    nonisolated static func markedSentences(_ r: Recording) -> [String] {
        guard !r.marks.isEmpty, !r.segments.isEmpty else { return [] }
        var picked: [TimeInterval] = []
        for m in r.marks {
            let seg = r.segments.last { $0.start <= m } ?? r.segments[0]
            if !picked.contains(seg.start) { picked.append(seg.start) }
        }
        return r.segments.filter { picked.contains($0.start) }.map { $0.clean ?? $0.text }
    }

    // MARK: 实时转写

    /// 开始录音时调用：让录音豆边录边把声音传过来，攒够一句就转成字。
    /// 这只是给现场看的即时字幕；录音结束后仍会下载完整音频，再整体转写、整理一遍，以那一份为准。
    func beginLiveTranscript(reset: Bool = true) {
        guard dictationCaptureID == nil else { return }
        refreshASRAvailability()
        guard settings.liveTranscribe, asrAvailable, encryptionReady, pull == nil, live == nil else {
            liveNote = settings.liveTranscribe && !asrAvailable ? localASRReadinessHint : nil
            return
        }
        var capture = LiveCapture()
        capture.scratch = false
        // 暂停过的录音再开始，是接着同一条录，设备不会再报编号，直接向它要实时声音
        if currentDeviceFile != 0, !scratchFiles.contains(currentDeviceFile) {
            capture.fileID = currentDeviceFile
            send(Command.pullFile(currentDeviceFile, offset: 0, realtime: true))
        }
        live = capture
        if reset { liveSegments = []; liveLevels = []; liveLevelTotal = 0 }
        livePending = 0
        liveNote = nil
        liveActive = true
        let server = settings.llamaServerPath
        // 音量单独算，五分之一秒一次：转写一句要好几秒，波形不能跟着停
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var cursor: UInt32?
            while let self, self.liveActive, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self.meterStep(&cursor)
            }
        }
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            await QwenASR.shared.warmUp(serverPath: server, selection: self?.settings.localASRModel ?? .qwen)
            var cursor: UInt32?            // 下一段从哪一帧开始
            var origin: UInt32?            // 这次录音收到的第一帧，用来算时间
            while let self, self.liveActive, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                let flush = self.liveFlush
                if flush { try? await Task.sleep(for: .milliseconds(500)); self.liveFlush = false }
                await self.liveStep(cursor: &cursor, origin: &origin, final: flush)
            }
            await self?.liveStep(cursor: &cursor, origin: &origin, final: true)
        }
    }

    /// 停止录音时调用：把最后没出完的那一段补上。
    func endLiveTranscript() async {
        guard liveActive else { return }
        // 等最后一点声音传到
        try? await Task.sleep(for: .milliseconds(600))
        liveActive = false
        await liveTask?.value
        liveTask = nil
        live = nil
        livePending = 0
        if worker == nil { await QwenASR.shared.stop() }
    }

    /// 把新到的声音换算成音量，接到波形后面。
    private func meterStep(_ cursor: inout UInt32?) async {
        guard let capture = live, let first = capture.firstSequence else { return }
        var start = cursor ?? first
        // 丢了的帧等一秒还不来，就跳过去，别让波形卡死在那
        if capture.frames[start] == nil, let next = capture.frames.keys.filter({ $0 > start }).min(),
           (capture.frames.keys.max() ?? 0) > start + 50 { start = next }
        var frames = Data()
        var n: UInt32 = 0
        while n < 500, let f = capture.frames[start + n] { frames.append(contentsOf: f); n += 1 }
        n -= n % 5                                   // 五帧正好 0.1 秒，一个音量值
        guard n > 0 else { cursor = start; return }
        let chunk = frames.prefix(Int(n) * 160)
        let samples = await Task.detached { Self.decodeFrames(Data(chunk)) }.value
        cursor = start + n
        guard let samples, !samples.isEmpty, liveActive else { return }
        let levels = Self.levels(samples)
        liveLevels = Array((liveLevels + levels).suffix(240))
        liveLevelTotal += levels.count
    }

    /// 看看攒下的声音够不够切一段：说话停顿了，或者已经攒了 12 秒，就转成字。
    private func liveStep(cursor: inout UInt32?, origin: inout UInt32?, final: Bool) async {
        guard let capture = live, let first = capture.firstSequence else { return }
        if cursor == nil { cursor = first; origin = first }
        guard let start = cursor, let base = origin else { return }
        var frames = Data()
        var n: UInt32 = 0
        while let f = capture.frames[start + n] { frames.append(contentsOf: f); n += 1 }
        livePending = Double(n) * 0.02
        guard n >= 10 else { return }

        let samples = await Task.detached { Self.decodeFrames(frames) }.value
        guard let samples, !samples.isEmpty else { cursor = start + n; return }
        guard n >= (final ? 15 : 100) else { return }          // 不到 2 秒先不切（收尾时 0.3 秒也算）

        // 找一个停顿来切：在停顿处断句，字幕才是一句一句的，不会把话拦腰截断。
        // 找不到停顿就继续攒；攒满 12 秒还没有，就在最后几秒里最安静的地方切。
        let cut: Int
        if final {
            cut = Int(n)
        } else if let pause = Self.lastPause(in: samples, forced: n >= 600) {
            cut = min(pause, Int(n))
        } else {
            return
        }
        guard cut > 0 else { return }
        let piece = Array(samples.prefix(cut * 320))

        cursor = start + UInt32(cut)
        if var kept = live {                                                  // 用过的声音不留着占内存
            kept.frames = kept.frames.filter { $0.key >= start + UInt32(cut) }
            live = kept
        }
        livePending = Double(Int(n) - cut) * 0.02
        guard Self.hasSpeech(piece) else { return }                         // 这一段没人说话，不送去识别
        guard let text = try? await QwenASR.shared.transcribe(samples: piece, serverPath: settings.llamaServerPath, selection: settings.localASRModel),
              !text.isEmpty, !Self.isFiller(text) else { return }
        liveSegments.append(Segment(start: Double(start - base) * 0.02, text: applyVocabulary(text)))
        addLog("实时转写 [\(clock(Double(start - base) * 0.02))] \(cut) 帧：\(text)")
    }

    /// 在一段声音里找最后一个停顿，返回它所在的帧号（每帧 20 毫秒）；没有就返回 nil。
    /// 「停顿」的标准跟着这段声音自己的音量走：连续 0.3 秒明显比说话时安静。
    /// 房间里有底噪也能用，因为比的是相对音量，不是绝对值。
    nonisolated static func lastPause(in samples: [Float], forced: Bool) -> Int? {
        let frame = 320, span = 15                      // 20 毫秒一帧，停顿至少 15 帧
        let count = samples.count / frame
        guard count > 75 + span else { return nil }     // 至少先攒 1.5 秒
        var energy = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var e: Float = 0
            for j in (i * frame)..<((i + 1) * frame) { e += samples[j] * samples[j] }
            energy[i] = (e / Float(frame)).squareRoot()
        }
        let speech = energy.sorted()[count * 8 / 10]    // 这段里「说话时」的音量
        guard speech > 0.002 else { return forced ? count : nil }
        // 滑动窗口算每 0.3 秒的平均音量
        var window = energy[0..<span].reduce(0, +)
        var smooth = [Float](repeating: 0, count: count - span + 1)
        smooth[0] = window / Float(span)
        for i in 1..<smooth.count {
            window += energy[i + span - 1] - energy[i - 1]
            smooth[i] = window / Float(span)
        }
        let from = 75
        // 留出最后 0.2 秒不看：那里可能只是还没说完的换气
        let to = smooth.count - 10
        guard to > from else { return nil }
        if let i = (from..<to).last(where: { smooth[$0] < speech * 0.3 }) { return i + span / 2 }
        guard forced else { return nil }
        // 没有明显停顿：在后三分之一里挑最安静的地方
        let begin = max(from, count * 2 / 3)
        guard begin < to else { return count }
        let quietest = (begin..<to).min { smooth[$0] < smooth[$1] } ?? to
        return quietest + span / 2
    }

    /// 这一段里有没有人说话。安静的房间也有底噪，模型在纯底噪上会凭空编出「啊」「嗯」。
    /// 判断方法：最响的那部分要明显比最安静的那部分响，而且绝对音量够大。
    nonisolated static func hasSpeech(_ samples: [Float]) -> Bool {
        let frame = 320, count = samples.count / frame
        guard count >= 10 else { return false }
        var energy = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var e: Float = 0
            for j in (i * frame)..<((i + 1) * frame) { e += samples[j] * samples[j] }
            energy[i] = (e / Float(frame)).squareRoot()
        }
        energy.sort()
        let loud = energy[count * 9 / 10], quiet = energy[count / 5]
        // 比例放得宽一点：商场这种吵的地方，人声和底噪的差距没那么大。纯语气词的结果后面还会再滤一次
        return loud > 0.005 && loud > quiet * 1.8
    }

    /// 只有一两个语气词的结果不要。
    nonisolated static func isFiller(_ text: String) -> Bool {
        let core = text.filter { !$0.isPunctuation && !$0.isWhitespace }
        return core.count <= 2 && core.allSatisfy { "啊嗯呃哦唉哎嘿噢额".contains($0) }
    }

    // MARK: 调试

    /// 试探设备有没有「结束录音」的指令。官方客户端只用到 1（继续）和 2（暂停）。
    /// 设备上报的状态里有 0 代表「已停止」，所以先试 0，再试 3。每试一个就看设备的回应和当前文件有没有变。
    func probeStopCommand() {
        guard link == .ready else { return }
        Task {
            for op in [UInt8(0), 3] {
                addLog("试探：发送录音控制参数 \(op)")
                send(Frame.encode(type: 0x18, id: 0x82, payload: [op]))
                try? await Task.sleep(for: .seconds(2))
                send(Command.deviceInfo())
                try? await Task.sleep(for: .seconds(1))
                refreshFiles()
                try? await Task.sleep(for: .seconds(2))
                addLog("试探：参数 \(op) 之后，设备的当前文件 = \(currentDeviceFile)，录音中 = \(info?.recording == true)")
                if currentDeviceFile == 0 { addLog("试探：当前文件已清空，参数 \(op) 看起来能结束录音"); break }
            }
        }
    }

    /// 每 0.1 秒一个音量值（0…1 之间，做过压缩，小声也看得见起伏）。
    nonisolated static func levels(_ samples: [Float]) -> [Float] {
        let step = 1600
        return stride(from: 0, to: samples.count - step + 1, by: step).map { i in
            var e: Float = 0
            for j in i..<(i + step) { e += samples[j] * samples[j] }
            return min(1, (e / Float(step)).squareRoot().squareRoot() * 2.2)
        }
    }

    /// 给已经录好的录音算一条波形，用在播放条上。
    nonisolated static func waveform(of url: URL, bars: Int = 160) -> [Float] {
        guard let samples = try? QwenASR.loadMono16k(url), samples.count > bars else { return [] }
        let step = samples.count / bars
        return (0..<bars).map { b in
            var peak: Float = 0
            for j in stride(from: b * step, to: (b + 1) * step, by: 8) { peak = max(peak, abs(samples[j])) }
            return min(1, peak.squareRoot() * 1.4)
        }
    }

    // MARK: 改写

    /// 把一条录音改写成口播稿、文章等。素材优先用润色过的文字稿。
    func rewrite(_ id: UInt32, template: RewriteTemplate, extra: String) {
        guard let rec = recordings.first(where: { $0.id == id }), !rewriting.contains(id), analysisAvailable else { return }
        let body = rec.segments.isEmpty ? (rec.transcript ?? "") : rec.segments.map { $0.clean ?? $0.text }.joined(separator: "\n")
        guard !body.isEmpty else { return }
        let material = "标题：\(rec.displayTitle)\n" + (rec.summary.map { "摘要：\($0)\n" } ?? "") + "\n内容：\n" + body
        var instruction = template.prompt
        let more = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { instruction += (instruction.isEmpty ? "" : "\n另外：") + more }
        guard !instruction.isEmpty else { toast("pencil", String(localized: "先写下你想把它改成什么样")); return }
        rewriting.insert(id)
        let profession = settings.profession
        let finalInstruction = instruction
        Task {
            defer { rewriting.remove(id) }
            do {
                let text = try await withLLM { config in
                    try await Analyzer.rewrite(material: material, instruction: finalInstruction, profession: profession, config: config)
                }
                if let i = recordings.firstIndex(where: { $0.id == id }) {
                    recordings[i].rewrites.insert(Rewrite(name: template == .custom ? String(localized: "自定义") : template.name, text: text), at: 0)
                    saveLibrary()
                }
                if worker == nil { await LocalLLM.shared.stop() }
            } catch {
                problem = Problem(title: String(localized: "这次改写没成功"), detail: error.localizedDescription + String(localized: "\n检查一下设置里的分析模型。"), action: .settings)
            }
        }
    }

    func addVideo(_ id: UInt32, _ clip: VideoClip) {
        guard let i = index(id) else { return }
        recordings[i].videos.insert(clip, at: 0)
        saveLibrary()
    }

    /// 旧版交付的成片没有封面：打开时补一张。
    func setVideoCover(_ id: UInt32, _ video: UUID, cover: String) {
        guard let i = index(id), let n = recordings[i].videos.firstIndex(where: { $0.id == video }) else { return }
        recordings[i].videos[n].cover = cover
        saveLibrary()
    }

    func deleteVideo(_ id: UInt32, _ video: UUID) {
        guard let i = index(id), let n = recordings[i].videos.firstIndex(where: { $0.id == video }) else { return }
        let clip = recordings[i].videos[n]
        if !clip.file.isEmpty { try? FileManager.default.trashItem(at: folder.appendingPathComponent(clip.file), resultingItemURL: nil) }
        if let cover = clip.cover { try? FileManager.default.removeItem(at: folder.appendingPathComponent(cover)) }
        recordings[i].videos.remove(at: n)
        saveLibrary()
    }

    func deleteRewrite(_ id: UInt32, _ rewrite: UUID) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].rewrites.removeAll { $0.id == rewrite }
        saveLibrary()
    }

    nonisolated static func decodeFrames(_ raw: Data) -> [Float]? {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        guard (try? OpusDecoder.writeWAV(packets: OggOpus.frames(fromRaw: raw), to: wav)) != nil else { return nil }
        return try? QwenASR.loadMono16k(wav)
    }

    // MARK: 对外接口

    static let mcpPort = 8791
    static var mcpAddress: String { "http://127.0.0.1:\(mcpPort)/mcp" }
    #if os(macOS)
    static var cliPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/beanpod").path }
    /// App 包里带的那份（Contents/Helpers/beanpod）。
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/beanpod")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// 把 App 自带的命令行工具装到 ~/.local/bin/beanpod（AI 助手的 MCP 配置指向这里）。
    /// 没装或和自带的不一样（App 升级了）才复制。要先删再拷：原地覆盖会让新文件一启动就被系统杀掉。
    @discardableResult
    func installCLI() -> Bool {
        guard let src = Self.bundledCLI else { return FileManager.default.isExecutableFile(atPath: Self.cliPath) }
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: Self.cliPath)
        if fm.contentsEqual(atPath: src.path, andPath: dst.path) { return true }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            addLog("命令行工具已装到 \(Self.cliPath)")
            return true
        } catch {
            addLog("命令行工具没装上：\(error.localizedDescription)")
            return false
        }
    }

    /// 豆仓开着的时候，顺带把 MCP 的网址入口也开着，给只认网址的工具（比如 Grok Bot）用。只监听本机。
    func startMCPServer() {
        guard FileManager.default.isExecutableFile(atPath: Self.cliPath) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-mcp", String(ProcessInfo.processInfo.processIdentifier), Self.cliPath, "serve", "--port", String(Self.mcpPort)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { addLog("MCP 网址入口：\(Self.mcpAddress)") }
    }
    #endif

    // MARK: 导入

    #if os(macOS)
    /// 让用户挑音频或文字文件导进来。原文件不动。（手机上用系统的文件选择器，在界面那边。）
    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .plainText, .text]
        panel.prompt = String(localized: "导入")
        panel.message = String(localized: "选择录音文件（m4a、mp3、wav 等）或文字文件，密盒助手会转写并整理。")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { importFile($0, consume: false) }
    }
    #endif

    /// 有了分析模型之后，把之前只按关键词粗分过类的录音补上完整纪要。
    func upgradeRoughNotes() {
        guard analysisAvailable else { return }
        recordings.filter { $0.transcript != nil && ($0.analyzedBy == nil || $0.analyzedBy == "关键词规则") && stages[$0.id] == nil && !$0.isDictation }
            .forEach { process($0.id) }
    }

    var roughCount: Int { recordings.filter { $0.transcript != nil && $0.analyzedBy == "关键词规则" && !$0.isDictation }.count }

    // MARK: 收件箱

    /// 别的工具（命令行、MCP、微信机器人）往这个文件夹里放音频或文字，豆仓自动收进来整理。
    var inboxFolder: URL { folder.deletingLastPathComponent().appendingPathComponent("Inbox", isDirectory: true) }

    func watchInbox() {
        try? FileManager.default.createDirectory(at: inboxFolder, withIntermediateDirectories: true)
        Task { [weak self] in
            while let self {
                self.drainInbox()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func drainInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            // 还在写入的文件先不碰：两秒内改过的等下一轮
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard Date.now.timeIntervalSince(modified) > 2, !file.hasDirectoryPath else { continue }
            importFile(file)
        }
    }

    /// consume：处理完把原文件删掉。收件箱里的文件是这样；用户自己选的文件不动它。
    func importFile(_ file: URL, consume: Bool = true, processNow: Bool = true) {
        let fm = FileManager.default
        var id = UInt32(Date.now.timeIntervalSince1970)
        while recordings.contains(where: { $0.id == id }) { id += 1 }
        let ext = file.pathExtension.lowercased()
        // 文件名前面的「时间戳-」是命令行加的防重名前缀，标题里不要
        var name = file.deletingPathExtension().lastPathComponent
        if let dash = name.firstIndex(of: "-"), name[..<dash].allSatisfy(\.isNumber) { name = String(name[name.index(after: dash)...]) }

        if ["md", "txt"].contains(ext) {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { reject(file, String(localized: "读不出文字"), consume); return }
            var title: String?
            if text.hasPrefix("# "), let end = text.firstIndex(of: "\n") {
                title = String(text[text.index(text.startIndex, offsetBy: 2)..<end]).trimmingCharacters(in: .whitespaces)
                text = String(text[end...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { reject(file, String(localized: "内容是空的"), consume); return }
            var rec = Recording(id: id, size: UInt32(text.utf8.count), date: .now, duration: 0)
            rec.downloaded = true; rec.textOnly = true; rec.origin = "文字笔记"
            rec.title = title; rec.transcript = text; rec.transcribedBy = "外部文字"
            recordings.insert(rec, at: 0)
            if consume { try? fm.removeItem(at: file) }
            addLog("导入文字笔记 \(id)")
        } else {
            let source = file
            guard let samples = Self.decodeAnyAudio(source), samples.count > 1600 else { reject(file, String(localized: "不是能识别的音频"), consume); return }
            do { try QwenASR.wav(samples).write(to: wavURL(id), options: .atomic) } catch { reject(file, String(localized: "写不进磁盘"), consume); return }
            var rec = Recording(id: id, size: UInt32(samples.count * 2), date: .now, duration: Double(samples.count) / 16000)
            rec.downloaded = true; rec.origin = "导入的音频"; rec.title = name
            recordings.insert(rec, at: 0)
            if consume { try? fm.removeItem(at: file) }
            addLog("导入音频 \(file.lastPathComponent) → \(id)")
        }
        saveLibrary()
        if processNow, settings.autoProcess || recordings.first?.textOnly == true { process(id) }
    }

    /// 处理不了的文件挪到「没能导入」里，不删，也不反复重试。
    private func reject(_ file: URL, _ why: String, _ consume: Bool = true) {
        guard consume else {
            notice = String(localized: "「\(file.lastPathComponent)」没能导入：\(why)。")
            return
        }
        let dir = inboxFolder.appendingPathComponent("没能导入", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        addLog("收件箱：\(file.lastPathComponent) 没能导入（\(why)）")
        notice = String(localized: "「\(file.lastPathComponent)」没能导入：\(why)。文件已挪到收件箱的「没能导入」文件夹。")
    }

    /// 系统能直接解的格式自己解；解不了的（ogg、amr、微信的 silk 等）交给 ffmpeg，没装 ffmpeg 就放弃。
    nonisolated static func decodeAnyAudio(_ url: URL) -> [Float]? {
        if let s = try? QwenASR.loadMono16k(url) { return s }
        #if os(macOS)
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", url.path, "-ar", "16000", "-ac", "1", tmp.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? try? QwenASR.loadMono16k(tmp) : nil
        #else
        return nil      // 手机上没有 ffmpeg，系统解不了的格式就放弃
        #endif
    }

    // MARK: 模型下载

    /// 转写模型：Qwen3‑ASR 0.6B（约 1 GB），固定版本，SHA‑256 校验。
    static let asrFiles = [
        ModelFile(name: QwenASR.projectorName, repo: "ggml-org/Qwen3-ASR-0.6B-GGUF", revision: "928ab958557df9aa2ef1c93e0e83c7ad0933fae2",
                  size: 214_392_480, sha256: "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d"),
        ModelFile(name: QwenASR.modelName, repo: "ggml-org/Qwen3-ASR-0.6B-GGUF", revision: "928ab958557df9aa2ef1c93e0e83c7ad0933fae2",
                  size: 804_749_248, sha256: "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971"),
    ]
    /// 转写模型：Gemma 4 E2B BF16（约 10.3 GB），固定版本，SHA‑256 校验。
    static let gemmaFiles = [
        ModelFile(name: LocalLLM.gemmaProjectorName, repo: "ggml-org/gemma-4-E2B-it-GGUF", revision: "2a8538c2e2d4687953a86c422c7c623cfd022880",
                  size: 986_833_696, sha256: "81a9cc75a12f1cd9fa91d69896794e1791489c423a59fbf0d50cf5ad633493c0"),
        ModelFile(name: LocalLLM.gemmaFileName, repo: "ggml-org/gemma-4-E2B-it-GGUF", revision: "2a8538c2e2d4687953a86c422c7c623cfd022880",
                  size: 9_311_299_520, sha256: "64fd524bfc9d53be67c27a63ddd98df0930883a4bcb855f8bc60470f6c4ef5ee"),
    ]

    /// 本机整理模型：Qwen3‑4B Q4_K_M（约 2.5 GB）。
    static let llmFiles = [
        ModelFile(name: LocalLLM.fileName, repo: "Qwen/Qwen3-4B-GGUF", revision: "bc640142c66e1fdd12af0bd68f40445458f3869b",
                  size: 2_497_280_256, sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"),
    ]

    private enum ModelDownload: CaseIterable { case qwenASR, qwenLLM, gemma, paraformer, nano }

    private func downloadJob(_ kind: ModelDownload) -> DownloadJob? {
        switch kind {
        case .qwenASR: qwenASRJob
        case .qwenLLM: qwenLLMJob
        case .gemma: gemmaJob
        case .paraformer: paraformerJob
        case .nano: nanoASRJob
        }
    }

    private func setDownloadJob(_ job: DownloadJob?, for kind: ModelDownload) {
        switch kind {
        case .qwenASR: qwenASRJob = job
        case .qwenLLM: qwenLLMJob = job
        case .gemma: gemmaJob = job
        case .paraformer: paraformerJob = job
        case .nano: nanoASRJob = job
        }
    }

    private func makeDownloadJob(_ kind: ModelDownload) -> DownloadJob {
        let files: [ModelFile] = switch kind {
        case .qwenASR: Self.asrFiles
        case .qwenLLM: Self.llmFiles
        case .gemma: Self.gemmaFiles
        case .paraformer: FunASRModel.paraformer.files
        case .nano: FunASRModel.nano.files
        }
        let folder: URL = switch kind {
        case .qwenASR: QwenASR.modelFolder
        case .qwenLLM, .gemma: LocalLLM.folder
        case .paraformer: FunASRModel.paraformer.directory
        case .nano: FunASRModel.nano.directory
        }
        let job = DownloadJob(files: files, folder: folder)
        job.onFinish = { [weak self, weak job] ok in
            guard let self, self.downloadJob(kind) === job else { return }
            self.setDownloadJob(nil, for: kind)
            self.refreshASRAvailability()
            if ok { self.addLog("本机模型下载好了") }
        }
        return job
    }

    private func startDownload(_ kind: ModelDownload) {
        let job = downloadJob(kind) ?? makeDownloadJob(kind)
        setDownloadJob(job, for: kind)
        job.start()
    }

    func downloadASRModel() {
        let kind: ModelDownload = switch settings.localASRModel {
        case .qwen: .qwenASR
        case .gemma: .gemma
        case .paraformer: .paraformer
        case .nano: .nano
        }
        startDownload(kind)
    }

    func localASRSelectionChanged() {
        refreshASRAvailability()
        let selection = settings.localASRModel
        guard selection.funASR != nil, !QwenASR.modelInstalled(selection: selection), asrJob == nil else { return }
        downloadASRModel()
    }

    func downloadLocalLLM() {
        startDownload(settings.localAnalysisModel == .gemma ? .gemma : .qwenLLM)
    }

    func restorePausedDownloads() {
        for kind in ModelDownload.allCases where downloadJob(kind) == nil {
            let job = makeDownloadJob(kind)
            guard job.files.contains(where: { FileManager.default.fileExists(atPath: DownloadJob.part($0, in: job.folder).path) }) else { continue }
            job.state = .paused
            setDownloadJob(job, for: kind)
        }
    }

    #if os(macOS)
    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 用 Homebrew 装 llama.cpp（本机转写和本机整理模型都靠它）。用户在设置里点「安装」才会跑。
    func installLlamaServer() {
        guard serverInstall == nil, let brew = Self.brewPath else { return }
        serverInstall = String(localized: "正在安装…")
        addLog("开始用 Homebrew 安装 llama.cpp")
        Task {
            let r = await VideoMaker.shell("'\(brew)' install llama.cpp 2>&1 | tail -20")
            serverInstall = nil
            refreshASRAvailability()
            if QwenASR.locateServer(custom: settings.llamaServerPath) != nil {
                addLog("llama.cpp 装好了")
            } else {
                addLog("llama.cpp 没装上：\(VideoMaker.tail(r.output))")
                problem = Problem(title: String(localized: "llama.cpp 没装上"), detail: String(localized: "可以在终端里运行 brew install llama.cpp 看看报什么错。\n") + VideoMaker.tail(r.output), action: .settings)
            }
        }
    }
    #endif
}

/// 点系统通知时，把人带到那条录音。
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let open = Notification.Name("BeanPodOpenRecording")

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["recording"] as? Int
        await MainActor.run {
            #if os(macOS)
            NSApp.activate(ignoringOtherApps: true)
            #endif
            if let id { NotificationCenter.default.post(name: Self.open, object: UInt32(id)) }
        }
    }
}

nonisolated enum MiBoxError: LocalizedError {
    case transcriptionNotConfigured, analysisNotConfigured, requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionNotConfigured: String(localized: "请在模型设置中填写有效的密盒转写接口地址和模型。")
        case .analysisNotConfigured: String(localized: "请在模型设置中填写有效的密盒分析接口地址和模型。")
        case .requestFailed(let reason): String(localized: "密盒请求失败：\(reason)")
        }
    }
}
