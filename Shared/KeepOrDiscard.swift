import Foundation

/// 刚录完的那一条：等用户说「留着」还是「不要」。
nonisolated struct JustRecorded: Equatable {
    var id: UInt32
    var seconds: TimeInterval
    /// 从哪录的：录音豆的名字，或者「这台 Mac」。
    var from: String
    var onMac: Bool
    /// 到这个时间还没选，就当留着。
    var deadline: Date
    /// 点了「不要这条」之后真正删除的时间；在这之前可以撤销。
    var discardAt: Date?

    static let patience: TimeInterval = 10
    static let regret: TimeInterval = 5
}

/// 录完先问一句「留着还是不要」。
///
/// 不是每条录音都值得留：按错了、试音、说到一半不想要了。以前只能录完等它下载、转写、整理完，
/// 再去列表里找到它删掉，录音豆里还得再删一遍。现在录完当场问一句，不要的话哪里都不留。
///
/// 不打断人：是一张浮着的小卡片，十秒不理它就默认留着；点了「不要」之后还有五秒可以反悔，
/// 因为录音豆里的删除找不回来。问的这几秒里先不下载、不整理。
extension BeanStore {
    func offerKeep(id: UInt32, seconds: TimeInterval, from: String, onMac: Bool) {
        if justRecorded != nil { keepJustRecorded() }
        justRecorded = JustRecorded(id: id, seconds: seconds, from: from, onMac: onMac, deadline: .now + JustRecorded.patience)
        Task { [weak self] in
            // 盯着这一条：到点没选就留着；选了不要、过了反悔期就真删
            while let self, let j = self.justRecorded, j.id == id {
                if let at = j.discardAt {
                    if Date.now >= at { self.reallyDiscard(j); break }
                } else if Date.now >= j.deadline {
                    self.keepJustRecorded(); break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func keepJustRecorded() {
        guard let j = justRecorded else { return }
        justRecorded = nil
        addLog("留着这条录音：\(j.id)")
        if j.onMac {
            if settings.autoProcess { process(j.id) }
        } else if settings.autoDownload, link == .ready {
            // 和以前录完之后一样：重新列一遍，把没下载的拉下来
            pullWhenListed = true
            refreshFiles()
        }
    }

    /// 点了「不要这条」：先不真删，给五秒反悔。
    func discardJustRecorded() {
        guard justRecorded != nil else { return }
        justRecorded?.discardAt = .now + JustRecorded.regret
    }

    func undoDiscard() {
        guard justRecorded?.discardAt != nil else { return }
        justRecorded?.discardAt = nil
        justRecorded?.deadline = .now + JustRecorded.patience
    }

    private func reallyDiscard(_ j: JustRecorded) {
        justRecorded = nil
        addLog("不要这条录音，删除：\(j.id)（\(j.onMac ? "Mac 上录的" : "密盒里的")）")
        if playingID == j.id { stop() }
        if j.onMac {
            removeLocal(j.id)
            toast("trash", String(localized: "这条没有留下"))
            return
        }
        // 这几秒里它可能已经被别的同步带着下载了（比如把录音豆放回了充电盒）：一起清掉
        dropFromDownloads(j.id)
        pendingMarks.removeAll { $0.file == j.id }
        if recordings.first(where: { $0.id == j.id })?.downloaded == true { removeLocal(j.id) }
        guard link == .ready else {
            problem = Problem(title: String(localized: "密盒没连着，这条还在密盒里"), detail: String(localized: "连上之后它会出现在列表里，到时候可以从密盒删除。"))
            return
        }
        deleteFromDevice(j.id)
        recordings.removeAll { $0.id == j.id }
        toast("trash", String(localized: "这条没有留下"))
    }
}

// MARK: - 让 AI 重新起标题

extension BeanStore {
    /// 只换标题，纪要、待办都不动（重新整理一遍会把打过勾的待办冲掉）。
    func retitle(_ id: UInt32) {
        guard let rec = recordings.first(where: { $0.id == id }), !retitling.contains(id), analysisAvailable else { return }
        let material = [rec.summary, rec.transcript.map { String($0.prefix(3000)) }].compactMap { $0 }.joined(separator: "\n\n")
        guard !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = Problem(title: String(localized: "这条录音还没有文字"), detail: String(localized: "先转写出文字，才能让 AI 起标题。"))
            return
        }
        let old = rec.title ?? ""
        let titleRevision = titleEditRevisions[id]
        retitling.insert(id)
        Task {
            defer { retitling.remove(id) }
            do {
                let reply = try await withLLM { config in
                    try await Analyzer.chat(config,
                        system: """
                        你给一段录音起标题。要求：一句话，不超过 22 个字，让人不用点开就知道这段录音讲了什么事、得出了什么结论；
                        用录音里的具体人名、事、数字，不要「关于……的讨论」「一段录音」这种空话；不加引号、书名号和句号。
                        只输出标题本身，不要解释。\(old.isEmpty ? "" : "现在的标题是「\(old)」，请换一个角度，不要重复。")
                        """,
                        user: material, json: false)
                }
                let title = Analyzer.stripThinking(reply).components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " 「」\"“”《》。#*")) ?? ""
                guard !title.isEmpty, title.count <= 40, let i = recordings.firstIndex(where: { $0.id == id }) else { return }
                guard titleEditRevisions[id] == titleRevision else { return }
                recordings[i].title = title
                recordings[i].titleEdited = false
                saveLibrary()
            } catch {
                problem = Problem(title: String(localized: "没能起出新标题"), detail: error.localizedDescription)
            }
        }
    }
}
