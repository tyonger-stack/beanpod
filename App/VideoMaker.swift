import AppKit
import AVFoundation
import SwiftUI

/// 建立口播视频工程，交由用户在 TeleAgent 中发送任务并确认报价。
/// 通过工程目录的 quote/progress/result 文件接回进度和成片。
@Observable
final class VideoMaker {
    /// talking-head-editor 的包装风格。
    enum Style: String, CaseIterable, Identifiable {
        case premium, restrained, variety
        var id: String { rawValue }
        var name: String {
            switch self {
            case .premium: "高级 · 网感"
            case .restrained: "高级 · 克制"
            case .variety: "综艺花字"
            }
        }
        /// 界面上显示的名字。name 会写进 job.json 和成片记录、也拿来比对，保持中文不变。
        var label: String {
            switch self {
            case .premium: String(localized: "高级 · 网感")
            case .restrained: String(localized: "高级 · 克制")
            case .variety: String(localized: "综艺花字")
            }
        }
        var fits: String {
            switch self {
            case .premium: String(localized: "节奏快、信息密：打字机字、标签卡、闪切、关键词大字。大多数口播用这个")
            case .restrained: String(localized: "同样的高级包装，收着用：适合财经、医疗、品牌这类严肃内容")
            case .variety: String(localized: "综艺感花字、表情和音效更热闹：适合吐槽、生活建议、娱乐向人设")
            }
        }
        /// 写进 brief 给剪辑 skill 的说法
        var brief: String {
            switch self {
            case .premium: "premium, web-native intensity"
            case .restrained: "premium, restrained intensity"
            case .variety: "variety"
            }
        }
    }

    struct Quote: Equatable {
        var credits: Double
        var balance: Double?
        var segments: Int
        var seconds: Int
        var items: [Item]
        var plan: String
        var notes: [String]
        struct Item: Equatable { var name: String; var detail: String }
    }

    /// 出片这一轮的几步，和 TASK.md 里约定的步骤名一致。
    static let steps = [String(localized: "生成口播"), String(localized: "检查拼接"), String(localized: "剪辑规划"),
                        String(localized: "包装配乐"), String(localized: "渲染质检"), String(localized: "下载交付")]

    /// waiting 等待用户发送任务及报价，quoted 等待用户确认，producing 表示已收到进度。
    enum Phase: Equatable { case idle, choosing, waiting, quoted, producing, finished(URL), failed(String) }

    static let renoiseMCP = "https://renoise.ai/api/public/mcp"

    /// 主播都是用户自己添加的（App/Hosts.swift），豆仓不带默认人物。
    let library = HostLibrary()
    var hosts: [Host] { library.hosts }
    /// 选中的主播；记住上次选的，下次打开还是它。
    var host: Host? { didSet { if let host { UserDefaults.standard.set(host.id, forKey: "lastHostID") } } }
    var style: Style = .premium
    var ratio = "9:16"
    var model = "wan3.0-video"
    var phase: Phase = .idle
    var quote: Quote?
    var stepIndex = 0
    var stepDetail = ""
    var started: Date?
    var teleAgentAppMissing = false
    var setupNote = ""

    var recording: UInt32 = 0
    var title = ""
    private var script = ""
    private(set) var job: URL?
    private var watching = false
    /// 旧任务还挂着时又点了「做成视频」：先记下这次要做的，旧任务放弃后接着用
    private var pending: (text: String, recording: UInt32, title: String, template: String)?

    var busy: Bool { phase == .waiting || phase == .quoted || phase == .producing }

    /// 录音页上那一行的说明
    var statusLine: String {
        switch phase {
        case .waiting: String(localized: "等待在 TeleAgent 发送任务并规划报价…")
        case .quoted: String(localized: "报价出来了，在 TeleAgent 里回复确认就开始")
        case .producing: String(localized: "正在做视频：\(stepIndex > 0 ? Self.steps[min(stepIndex, Self.steps.count) - 1] : String(localized: "准备"))…")
        default: ""
        }
    }

    // MARK: 准备

    /// 读取主播、推荐风格并检查 TeleAgent 是否安装。
    func prepare(text: String, recording: UInt32, title: String, template: String) {
        guard !busy else { pending = (text, recording, title, template); return }
        pending = nil
        self.recording = recording
        self.title = title
        script = text
        quote = nil; job = nil; stepIndex = 0; stepDetail = ""; setupNote = ""
        loadHosts()
        checkSetup()
        style = template.contains("吐槽") ? .variety : .premium
        ratio = "9:16"
        phase = .choosing
    }

    func checkSetup() {
        teleAgentAppMissing = Self.teleAgentApp == nil
    }

    func loadHosts() {
        library.load()
        if host == nil || !hosts.contains(where: { $0.id == host?.id }) {
            let last = UserDefaults.standard.string(forKey: "lastHostID")
            host = hosts.first { $0.id == last } ?? hosts.first { $0.usable } ?? hosts.first
        }
        if hosts.contains(where: { !$0.usable || $0.face == nil }) { Task { await library.refreshFaces() } }
    }

    // MARK: 交给 TeleAgent

    /// 建工程文件夹、写好任务说明，然后打开 TeleAgent。不花积分：报价出来后要用户在 TeleAgent 里点头才生成。
    func start(store: BeanStore) {
        guard let host, host.usable, !busy else { return }
        checkSetup()
        guard !teleAgentAppMissing else { return }
        let stamp = Int(Date.now.timeIntervalSince1970)
        let folder = Self.jobsRoot(store).appendingPathComponent("\(recording)-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        job = folder
        try? script.write(to: folder.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let brief: [String: Any] = [
            "deliverable": "finished MP4 with full packaging", "edit_style": style.brief, "aspect_ratio": ratio,
            "model": model, "host": ["name": host.name, "reference": "material:\(host.material)", "native_ratio": host.ratio],
            "language": "zh", "market": "China", "platform": ratio == "9:16" ? "抖音 / 视频号 / 小红书" : "B 站",
            "title": title, "music": "pick a royalty-free track that fits; no audition round",
            "sandbox_project": "~/projects/\(day)-beanpod-\(recording)",
        ]
        Self.write(brief, to: folder.appendingPathComponent("brief.json"))
        Self.write(["recording": Int(recording), "title": title, "style": style.name, "host": host.name, "ratio": ratio, "model": model, "started": stamp],
                   to: folder.appendingPathComponent("job.json"))
        let header = "Job folder (absolute): \(folder.path)\nEvery ./ path below means a file in this job folder. If your working directory is somewhere else, cd here first or use the absolute path.\n\n"
        try? (header + Self.task).write(to: folder.appendingPathComponent("TASK.md"), atomically: true, encoding: .utf8)
        store.addLog("做视频：工程已准备，等待用户在 TeleAgent 发送（\(style.name) · \(ratio) · \(host.name) · \(model)），工程在 \(folder.path)")
        phase = .waiting
        started = .now
        openSession()
        Task { await watch(store) }
    }

    func openSession() {
        showTeleAgent()
    }

    func copyTask() {
        guard let job else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.prompt(job), forType: .string)
        setupNote = String(localized: "任务指令已复制。在 TeleAgent 新建会话，选择工程目录，粘贴后发送。")
    }

    func showTeleAgent() {
        guard let app = Self.teleAgentApp else {
            setupNote = String(localized: "未找到 TeleAgent，请先安装并登录。")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in
                    self.setupNote = String(localized: "TeleAgent 打开失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 不再跟这一条：TeleAgent 里那个会话要在 TeleAgent 里自己停。
    func abandon(store: BeanStore) {
        if let job { FileManager.default.createFile(atPath: job.appendingPathComponent(".closed").path, contents: nil) }
        store.addLog("做视频：密盒助手不再跟进 \(job?.lastPathComponent ?? "")")
        job = nil
        quote = nil; stepIndex = 0; stepDetail = ""; started = nil
        phase = .idle
        if let p = pending {
            // 放弃旧的那条后，接着准备这次点的那篇稿子（主播、风格都重新读）
            prepare(text: p.text, recording: p.recording, title: p.title, template: p.template)
        } else if !script.isEmpty {
            prepare(text: script, recording: recording, title: title, template: "")
        } else {
            loadHosts()
            phase = .choosing
        }
    }

    /// 交出去很久还没动静：多半是 TeleAgent 里没按发送，或者那边停了
    var stalledMinutes: Int? {
        guard let started else { return nil }
        let minutes = Int(Date.now.timeIntervalSince(started) / 60)
        switch phase {
        case .waiting: return minutes >= 10 ? minutes : nil
        case .producing:
            guard let job, let m = (try? FileManager.default.attributesOfItem(atPath: job.appendingPathComponent("progress.json").path))?[.modificationDate] as? Date else { return nil }
            let idle = Int(Date.now.timeIntervalSince(m) / 60)
            return idle >= 25 ? idle : nil
        default: return nil
        }
    }

    func showProject() {
        if let job { NSWorkspace.shared.activateFileViewerSelecting([job]) }
    }

    func copyRenoiseMCP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.renoiseMCP, forType: .string)
        setupNote = String(localized: "Renoise MCP 地址已复制。请在 TeleAgent 的 MCP 设置中添加并登录授权。")
    }

    // MARK: 跟进度

    /// 一直看着工程文件夹：报价、进度、成片。App 重开后也接着跟最近没做完的那条，成片出来就挂到录音下面。
    func watch(_ store: BeanStore) async {
        guard !watching else { return }
        watching = true
        defer { watching = false }
        if job == nil, let latest = activeJobs(store).last { adopt(latest) }
        while true {
            scan(store)
            if activeJobs(store).isEmpty && !busy { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 还没交付、豆仓也没放弃的工程（三天内开的）
    private func activeJobs(_ store: BeanStore) -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: Self.jobsRoot(store), includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date.now.timeIntervalSince1970 - 3 * 86_400
        return all.filter { folder in
            guard fm.fileExists(atPath: folder.appendingPathComponent("TASK.md").path),
                  !fm.fileExists(atPath: folder.appendingPathComponent(".done").path),
                  !fm.fileExists(atPath: folder.appendingPathComponent(".closed").path),
                  let stamp = Double(folder.lastPathComponent.split(separator: "-").last ?? ""), stamp > cutoff else { return false }
            return true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// App 重开时把最近那条接回界面
    private func adopt(_ folder: URL) {
        guard let info = Self.readJSON(folder.appendingPathComponent("job.json")) else { return }
        job = folder
        recording = UInt32(Self.number(info["recording"]) ?? 0)
        title = info["title"] as? String ?? ""
        ratio = info["ratio"] as? String ?? ratio
        style = Style.allCases.first { $0.name == info["style"] as? String } ?? style
        started = Self.number(info["started"]).map { Date(timeIntervalSince1970: $0) }
        phase = .waiting
    }

    private func scan(_ store: BeanStore) {
        for folder in activeJobs(store) {
            let current = folder == job
            if let r = Self.readJSON(folder.appendingPathComponent("result.json")) {
                deliver(folder, r, store: store, current: current)
                continue
            }
            guard current, busy else { continue }
            if let p = Self.readJSON(folder.appendingPathComponent("progress.json")) {
                if phase != .producing { phase = .producing; started = .now }
                stepIndex = Int(Self.number(p["index"]) ?? Double(stepIndex))
                stepDetail = p["detail"] as? String ?? p["step"] as? String ?? stepDetail
            } else if phase == .waiting, let q = Self.readJSON(folder.appendingPathComponent("quote.json")) {
                if let error = q["error"] as? String { phase = .failed(error); continue }
                quote = Self.parseQuote(q)
                phase = .quoted
                store.addLog("做视频：报价 \(Int(quote?.credits ?? 0)) 积分，\(quote?.segments ?? 0) 段 \(quote?.seconds ?? 0) 秒，等用户在 TeleAgent 里确认")
            }
        }
    }

    /// 成片出来了：视频、封面、成片口播稿、包装说明、质检结果、素材编号一起拷进录音库，挂到那条录音下面。
    /// 没做成也在那条录音下面留一条，写明原因和已经花了多少积分。之后不再看这个文件夹。
    private func deliver(_ folder: URL, _ r: [String: Any], store: BeanStore, current: Bool) {
        let info = Self.readJSON(folder.appendingPathComponent("job.json")) ?? [:]
        let fm = FileManager.default
        let rec = UInt32(Self.number(info["recording"]) ?? Double(recording))
        let quote = Self.readJSON(folder.appendingPathComponent("quote.json")).map(Self.parseQuote)
        func clip(file: String) -> VideoClip {
            var c = VideoClip(file: file, host: info["host"] as? String ?? String(localized: "数字人"),
                              seconds: Int(Self.number(r["seconds"]) ?? Double(quote?.seconds ?? 0)),
                              credits: Int(Self.number(r["credits_spent"]) ?? (file.isEmpty ? 0 : quote?.credits ?? 0)))
            c.style = info["style"] as? String
            c.ratio = info["ratio"] as? String
            c.script = Self.finalScript(folder, r)
            c.summary = (r["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            c.checks = (r["checks"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            c.material = (r["material"] as? String) ?? Self.number(r["material"]).map { String(Int($0)) }
            return c
        }
        func close(_ failure: String?) {
            fm.createFile(atPath: folder.appendingPathComponent(".done").path, contents: nil)
            if let failure {
                store.addLog("做视频：\(folder.lastPathComponent) 没做成：\(failure)")
                var failed = clip(file: "")
                failed.error = failure
                store.addVideo(rec, failed)
                if current { phase = .failed(failure) }
            }
        }
        if let error = r["error"] as? String { close(error); return }
        let local = (r["video"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : folder.appendingPathComponent($0) }
        guard let local, fm.fileExists(atPath: local.path) else {
            // 文件可能还在写，先不收尾；result.json 写了但成片迟迟不在就等下一轮
            if let mtime = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent("result.json").path))?[.modificationDate] as? Date,
               mtime.timeIntervalSinceNow < -120 {
                close(String(localized: "result.json 里写的成片在本机找不到。"))
            }
            return
        }
        let stamp = Int(Date.now.timeIntervalSince1970)
        let name = "\(rec)-video-\(stamp).mp4"
        let out = store.folder.appendingPathComponent(name)
        do { try fm.copyItem(at: local, to: out) } catch { close(String(localized: "成片拷不进录音库：\(error.localizedDescription)")); return }
        var c = clip(file: name)
        // 封面：TeleAgent 给了就用它的，没给就从成片里取一帧
        let coverName = "\(rec)-video-\(stamp).jpg"
        let coverOut = store.folder.appendingPathComponent(coverName)
        if let given = (r["cover"] as? String).map({ $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : folder.appendingPathComponent($0) }),
           fm.fileExists(atPath: given.path), (try? fm.copyItem(at: given, to: coverOut)) != nil {
            c.cover = coverName
        } else if Self.writeFrame(of: out, to: coverOut) {
            c.cover = coverName
        }
        store.addVideo(rec, c)
        store.addLog("做视频：交付 \(name)，花了 \(c.credits) 积分。\(c.summary ?? "")")
        store.toast("checkmark.circle.fill", String(localized: "视频做好了：\(info["title"] as? String ?? "")"))
        close(nil)
        if current { phase = .finished(out) }
    }

    /// 成片里实际念的口播全文：result.json 的 script，没有就拼 script.json 里每段的 t。
    nonisolated static func finalScript(_ folder: URL, _ r: [String: Any]) -> String? {
        if let s = r["script"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("script.json")),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let takes = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["takes"] as? [[String: Any]]) ?? []
        let lines = takes.compactMap { ($0["t"] ?? $0["text"] ?? $0["line"]) as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 从视频里取一帧存成 JPEG（第 1 秒，太短就取开头）。
    nonisolated static func writeFrame(of video: URL, to url: URL) -> Bool {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        guard let cg = (try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil))
                ?? (try? gen.copyCGImage(at: .zero, actualTime: nil)) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return false }
        return (try? jpg.write(to: url, options: .atomic)) != nil
    }

    nonisolated static func parseQuote(_ q: [String: Any]) -> Quote {
        let items = (q["items"] as? [[String: Any]] ?? []).map { item -> Quote.Item in
            let credits = number(item["credits"]).map { String(localized: "\(Int($0.rounded())) 积分") } ?? ""
            let count = number(item["count"]).map { " × \(Int($0))" } ?? ""
            return Quote.Item(name: (item["name"] as? String ?? "") + count, detail: credits)
        }
        return Quote(credits: number(q["credits"]) ?? 0, balance: number(q["balance"]),
                     segments: Int(number(q["segments"]) ?? 0), seconds: Int(number(q["seconds"]) ?? 0),
                     items: items, plan: q["plan"] as? String ?? "", notes: q["notes"] as? [String] ?? [])
    }

    // MARK: 环境

    static func jobsRoot(_ store: BeanStore) -> URL {
        store.folder.deletingLastPathComponent().appendingPathComponent("Videos", isDirectory: true)
    }

    static var teleAgentApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.teleai.superagent")
            ?? (FileManager.default.fileExists(atPath: "/Applications/TeleAgent.app") ? URL(fileURLWithPath: "/Applications/TeleAgent.app") : nil)
    }

    private static func prompt(_ job: URL) -> String {
        "这是密盒助手发来的视频任务。工程文件夹：\(job.path)\n先 cd 到这个文件夹，照里面的 TASK.md，用 Renoise MCP 的 ai-avatar 和 talking-head-editor 两个 skill，把 source.md 这篇口播稿做成带完整包装的数字人口播视频。先规划报价，我确认了再花积分。"
    }

    private static let task = """
    # Mi Box Assistant video job

    This job was started from the Mi Box Assistant (密盒助手). The user is in this conversation: talk to them in Simplified Chinese, briefly.

    Goal: turn the Chinese talking-head script in ./source.md into a finished, fully packaged AI-avatar talking-head video, using the Renoise MCP tools and the Renoise hosted skills:
    ai-avatar (script and performance, takes, generate, check, join the A-roll) → talking-head-editor (rough cut, sentence-by-sentence edit plan, captions and keyword big text, info cards, picture-in-picture, B-roll, sound effects, music, render, QA, in the Renoise cloud sandbox).
    ./brief.json holds what the user already chose in Mi Box Assistant: edit style, aspect ratio, model, host reference material, platform, sandbox project folder. Those are the answers to the skills' clarifying questions; do not ask them again.
    Mi Box Assistant watches this folder for ./quote.json, ./progress.json and ./result.json, so always write them exactly as below.

    ## 0. Renoise MCP
    Use the Renoise MCP tools available in TeleAgent. If they are not available or the server needs sign-in:
    - First check the Renoise CLI: run `renoise account status` (it may be at ~/.local/bin/renoise). If it shows a balance, the CLI is already signed in: do not wait for the MCP. Read `renoise contract` and `renoise model` to learn the commands and prices, and do the same job with the CLI (`renoise task create`, `renoise task wait`/`get`, `renoise upload`); do the edit locally in this folder instead of the cloud sandbox. The quote-before-spending rule below still applies, and so do the files Mi Box Assistant watches.
    - Only if the CLI is missing or not signed in, tell the user in one line: 请在 TeleAgent 的 MCP 设置中连接 Renoise 并登录授权，好了回我一句。 Then wait.
    Never ask for, print or store API keys or tokens yourself.

    ## 1. Plan and quote (no credits)
    get_account. load_skill ai-avatar, then the files it tells you to read for planning, and load_skill talking-head-editor so the plan covers the edit.
    Following ai-avatar steps 0–2: write the script and performance as script.json (keep the content of source.md; you may tighten it for speech and add a hook, but do not invent facts), cut it into takes, and price every take with estimate_cost using the chosen model and host reference. Plan and price any Renoise-generated B-roll the edit would want. Say whether the edit itself (the sandbox engineer) is free on this account's plan.
    Keep script.json in the sandbox project folder from brief.json (create it with the sandbox tool in command mode) and save a copy here.
    Write ./quote.json (UTF-8, Chinese text):
    {"segments": takes, "seconds": total seconds, "credits": total credits, "balance": balance,
     "items": [{"name": "数字人出镜（模型名）", "count": takes, "credits": n}, {"name": "B-roll …", "count": n, "credits": n}],
     "plan": "两三句中文：开场怎么抓人、怎么剪、用哪些包装",
     "notes": ["给用户的提醒，比如稿子里要核实的说法"]}
    Then show the user the quote in chat and ask for a yes. Do not call create_tasks, start a sandbox task, or spend anything before they say yes.
    If something blocks the plan, write ./quote.json {"error": "一句中文原因"} and tell the user.

    ## 2. Produce (only after the user's yes)
    Budget: the quoted credits + 10%. Never exceed it; if you would, stop, tell the user, and write ./result.json {"error": "中文原因，已花多少积分"}.
    - ai-avatar steps 3–5: generate the takes with create_tasks, wait, check speech and frames, reshoot only a broken take (within budget), join the A-roll in the sandbox project.
    - ai-avatar step 6 → talking-head-editor: the full edit in the style from brief.json: rough cut, edit plan, captions and keyword big text, info cards, picture-in-picture, B-roll (generate the planned shots only within budget), sound effects, music (choose a fitting royalty-free track; no audition round), render, final QA. Deliver the finished cut, not a draft.
    - Deliver: upload_files the finished video (deliver: true), then download it into ./out/final.mp4 here.
    Each time you start a stage, overwrite ./progress.json with {"index": n, "total": 6, "step": "<name>", "detail": "<one short Chinese sentence>"}.
    Stages in order: 1 生成口播, 2 检查拼接, 3 剪辑规划, 4 包装配乐, 5 渲染质检, 6 下载交付.
    While the sandbox engineer works, check its PROGRESS.md at least every 5 minutes (the sandbox pauses after 15 idle minutes) and keep progress.json current.
    When done, write ./result.json: {"video": "out/final.mp4", "cover": "out/cover.jpg (a frame or the designed cover; optional)", "seconds": n, "material": "Renoise material id of the final cut", "credits_spent": n, "script": "成片里实际念的口播全文，一段一行", "summary": "一两句中文：用了哪些包装", "checks": "一句中文：质检结果"}, and tell the user it is in Mi Box Assistant.
    On any blocker, write ./result.json {"error": "一句中文原因", "credits_spent": n}; never stop silently.
    """

    // MARK: 小工具

    /// 在登录 shell 里跑一行命令（Renoise 设置页也用它）。
    nonisolated static func shell(_ command: String) async -> (ok: Bool, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (false, String(localized: "命令没能运行")) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    nonisolated static func tail(_ output: String) -> String {
        String((output.split(separator: "\n").last.map(String.init) ?? String(localized: "没有给出原因")).prefix(140))
    }

    nonisolated static func object(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    nonisolated static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func write(_ object: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: url)
        }
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// 「做成视频」：选风格和主播 → 交给 TeleAgent（报价、确认都在那边）→ 这里跟进度，成片自动回来。
struct VideoSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(VideoMaker.self) private var maker
    @Environment(\.dismiss) private var dismiss
    @State private var addingHost = false
    @State private var renaming: Host?
    @State private var renameText = ""
    @State private var removing: Host?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DevicePhotoView().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("做成数字人口播").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("交给 TeleAgent，用 Renoise 的数字人和口播剪辑 skill 一条龙做：写稿、生成出镜、在 Renoise 云端剪辑包装（字幕花字、信息卡、B-roll、音乐），成片自动回到这里。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            switch maker.phase {
            case .idle, .choosing: choosing
            case .waiting: waiting
            case .quoted: quoted
            case .producing: producing
            case .finished(let url): finished(url)
            case .failed(let why): failed(why)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    // 选风格、主播（设计稿 design/ui/ui_hosts_empty.png、ui_hosts_pick.png）
    @ViewBuilder private var choosing: some View {
        @Bindable var maker = maker
        VStack(alignment: .leading, spacing: 8) {
            Text("包装风格").font(.headline)
            HStack(spacing: 10) {
                ForEach(VideoMaker.Style.allCases) { s in styleCard(s) }
            }
            Text(maker.style.fits).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Text("比例").font(.headline)
            Spacer()
            Picker("比例", selection: $maker.ratio) { Text("9:16 竖屏").tag("9:16"); Text("16:9 横屏").tag("16:9") }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            Text("主播").font(.headline)
            if maker.hosts.isEmpty {
                NoHostCard { addingHost = true }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(maker.hosts) { h in
                            HostCard(host: h, picked: maker.host?.id == h.id,
                                     onPick: { maker.host = h },
                                     onRename: { renameText = h.name; renaming = h },
                                     onRemove: { removing = h })
                        }
                        AddHostCard { addingHost = true }
                    }
                    .padding(2)
                }
                if let h = maker.host, let t = h.faceText {
                    Text("「\(h.name)」\(t)。Renoise 审核通过后才能用它生成；审核没通过就换一张照片。")
                        .font(.caption).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !maker.hosts.isEmpty {
            HStack {
                Text("出镜模型").font(.headline)
                Spacer()
                Picker("出镜模型", selection: $maker.model) {
                    Text("Wan 3.0（推荐，长镜头更稳）").tag("wan3.0-video")
                    Text("Grok Video 1.5（自拍随手感）").tag("grok-video-1.5")
                }
                .labelsHidden().frame(width: 300)
            }
        }
        if maker.teleAgentAppMissing {
            Label("这台 Mac 上没装 TeleAgent，做视频要靠它。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        } else {
            HStack {
                Label("请确认 TeleAgent 已连接 Renoise MCP。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                Spacer()
                RemoteButton("复制 MCP 地址") { maker.copyRenoiseMCP() }
            }
        }
        if !maker.setupNote.isEmpty { Text(maker.setupNote).font(.callout).foregroundStyle(.secondary) }
        Divider()
        HStack {
            Text(maker.recording == 0 ? "这是预览，不能提交。要做视频，从录音的「改写」页打开" : maker.hosts.isEmpty ? "先添加一个主播" : "请在 TeleAgent 新建会话并粘贴任务，报价确认后才花积分")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            RemoteButton("先不做") { dismiss() }
            if maker.library.busy { ProgressView().controlSize(.small) }
            RemoteButton("交给 TeleAgent 做") { Task { await handOff() } }
                .buttonStyle(.glassProminent).disabled(maker.recording == 0 || maker.host?.usable != true || maker.teleAgentAppMissing || maker.library.busy)
        }
        .controlSize(.large)
        .sheet(isPresented: $addingHost) {
            AddHostSheet { h in maker.host = h }.environment(maker.library)
        }
        .alert("给主播改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("好") {
                if let h = renaming { maker.library.rename(h, to: renameText.trimmingCharacters(in: .whitespaces)); maker.loadHosts() }
                renaming = nil
            }
        }
        .confirmationDialog("从密盒助手移除「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                if let h = removing { maker.library.remove(h); if maker.host?.id == h.id { maker.host = nil }; maker.loadHosts() }
                removing = nil
            }
        } message: {
            Text("只从密盒助手里去掉。这张照片在你 Renoise 账号里的素材不会被删除。")
        }
    }

    /// 示例主播第一次用时先传到用户自己的 Renoise 账号，再交给 TeleAgent。
    private func handOff() async {
        guard var h = maker.host else { return }
        if h.material.isEmpty {
            maker.setupNote = String(localized: "正在把示例主播的照片传到你的 Renoise 账号（不花积分）…")
            guard let up = await maker.library.ensureUploaded(h) else {
                maker.setupNote = maker.library.error ?? String(localized: "示例主播没传上去。")
                return
            }
            h = up
            maker.host = up
            maker.setupNote = ""
            guard up.usable else {
                maker.setupNote = String(localized: "示例主播已经传上去了，Renoise 正在审核人像，过一会儿再点「交给 TeleAgent 做」。")
                return
            }
        }
        maker.start(store: store)
    }

    private func styleCard(_ s: VideoMaker.Style) -> some View {
        let picked = maker.style == s
        return RemoteButton { maker.style = s } label: {
            VStack(spacing: 8) {
                StylePreview(style: s).frame(maxWidth: .infinity).frame(height: 112).clipShape(.rect(cornerRadius: Theme.Radius.card))
                Text(s.label).font(.callout.weight(.semibold))
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(picked ? 1 : 0.6), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.22), lineWidth: picked ? 2 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(s.fits)
        .accessibilityLabel("\(s.label)\(picked ? String(localized: "，已选中") : "")")
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("工程已准备好，等待 TeleAgent 报价").font(.headline)
                Spacer()
                if let start = maker.started { Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, String(localized: "点击「复制任务指令」，在 TeleAgent 新建会话并选择工程目录。"))
                step(2, String(localized: "粘贴任务指令后发送；首次使用请在 TeleAgent 的 MCP 设置中连接 Renoise 并登录。"))
                step(3, String(localized: "它写稿、逐项核价，报价会同时显示在这里，不花积分。"))
            }
            .padding(12).panel(radius: Theme.Radius.card)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let m = maker.stalledMinutes {
                Label("交出去 \(m) 分钟了还没有报价。请在 TeleAgent 新建会话、粘贴任务指令并发送。", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !maker.setupNote.isEmpty { Text(maker.setupNote).font(.callout).foregroundStyle(.secondary) }
            footer(stop: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent)
            Text(text).font(.callout)
        }
    }

    @ViewBuilder private var quoted: some View {
        if let q = maker.quote {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("这条要花").foregroundStyle(.secondary)
                    Text("\(Int(q.credits.rounded()))").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("积分").foregroundStyle(.secondary)
                    if let b = q.balance { Text("· 账户里还有 \(Int(b))").font(.callout).foregroundStyle(.tertiary) }
                    Spacer()
                    Text("\(maker.style.label) · \(maker.ratio) · \(q.segments) 段 · 约 \(q.seconds) 秒").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(q.items.enumerated()), id: \.offset) { _, item in
                        HStack { Text(item.name); Spacer(); Text(item.detail).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                    }
                    if !q.plan.isEmpty {
                        Divider()
                        Text(q.plan).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).panel(radius: Theme.Radius.card)
                ForEach(q.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
                Label("要做就在 TeleAgent 对话里回复确认，它按这个报价加 10% 余量封顶。密盒助手会自动跟进度。", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("视频由 AI 生成，出镜的是数字人。发出去之前请自己看一遍，并按平台要求标明「内容由 AI 生成」。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                footer(stop: true)
            }
        }
    }

    private var producing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Array(VideoMaker.steps.enumerated()), id: \.offset) { n, name in
                    stepView(n, name)
                }
            }
            Text(maker.stepDetail.isEmpty ? String(localized: "准备中…") : maker.stepDetail).font(.callout.weight(.medium))
            HStack {
                if let start = maker.started {
                    Label { Text(start, style: .timer).monospacedDigit() } icon: { Image(systemName: "clock") }.font(.caption).foregroundStyle(.secondary)
                }
                Text("一般要二三十分钟，可以关掉这个窗口，做好了会提醒。").font(.caption).foregroundStyle(.tertiary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let m = maker.stalledMinutes {
                Label("已经 \(m) 分钟没有新进度了，回 TeleAgent 看看是不是停下来在等你。", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
            footer(stop: false)
        }
    }

    private func footer(stop: Bool) -> some View {
        HStack {
            RemoteButton("工程目录") { maker.showProject() }.buttonStyle(.borderless)
            if stop {
                RemoteButton("不跟这条了") { maker.abandon(store: store) }.buttonStyle(.borderless)
                    .help("密盒助手不再跟进这条。TeleAgent 里那个会话要在 TeleAgent 里停")
            }
            Spacer()
            if maker.phase == .waiting { RemoteButton("复制任务指令") { maker.copyTask() } }
            RemoteButton("回到 TeleAgent") { maker.showTeleAgent() }
            RemoteButton("关闭") { dismiss() }.buttonStyle(.glassProminent)
        }
        .controlSize(.large)
    }

    private func stepView(_ n: Int, _ name: String) -> some View {
        let state = n + 1 < maker.stepIndex ? 2 : (n + 1 == maker.stepIndex ? 1 : 0)
        return VStack(spacing: 5) {
            ZStack {
                Circle().fill(state == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Theme.accent)).frame(width: 20, height: 20)
                if state == 2 { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                else if state == 1 { ProgressView().controlSize(.mini).tint(.white) }
                else { Text("\(n + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text(name).font(.caption.weight(state == 1 ? .semibold : .regular)).foregroundStyle(state == 0 ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func finished(_ url: URL) -> some View {
        HStack {
            Label("做好了，带包装，已经放到这条录音的「改写」下面。", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            Spacer()
            RemoteButton("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            RemoteButton("打开") { NSWorkspace.shared.open(url); dismiss() }.buttonStyle(.glassProminent)
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(why, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
            HStack {
                RemoteButton("工程目录") { maker.showProject() }.buttonStyle(.borderless)
                Spacer()
                RemoteButton("重新选") { maker.phase = .choosing }
                RemoteButton("关闭") { dismiss() }
            }
        }
    }
}

/// 包装风格的小预览图。
private struct StylePreview: View {
    let style: VideoMaker.Style
    var body: some View {
        if let url = Bundle.main.url(forResource: "style_\(style.rawValue)", withExtension: "jpg"), let img = NSImage(contentsOf: url) {
            // 内置的预览图（design/samples/gen.sh，虚构人物）
            Color.clear.overlay(Image(nsImage: img).resizable().scaledToFill()).clipped().accessibilityHidden(true)
        } else {
            drawn
        }
    }

    /// 没有预览图时的兜底：只画版式。
    private var drawn: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.9), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.35)).frame(width: 120).offset(x: 60, y: 40)
            switch style {
            case .premium:
                VStack(alignment: .leading, spacing: 6) {
                    Text("3 个关键数字").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(white: 0.12))
                    Rectangle().fill(Theme.accent).frame(width: 46, height: 3)
                    Text("要点 01").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(white: 0.12), in: .capsule).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
            case .restrained:
                VStack(alignment: .leading, spacing: 6) {
                    Text("标题").font(.system(size: 18, weight: .regular, design: .serif)).foregroundStyle(Color(white: 0.2))
                    Rectangle().fill(Color(white: 0.4)).frame(width: 30, height: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
            case .variety:
                Text("太好用了！").font(.system(size: 17, weight: .black)).foregroundStyle(Theme.accent)
                    .shadow(color: .white, radius: 0, x: 1.5, y: 1.5).shadow(color: .white, radius: 0, x: -1.5, y: -1.5)
                    .rotationEffect(.degrees(-8))
            }
            VStack {
                Spacer()
                Capsule().fill(.black.opacity(0.18)).frame(height: 3).overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 34, height: 3)
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .accessibilityHidden(true)
    }
}
