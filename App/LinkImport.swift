import AppKit
import BeanKit
import Network
import SwiftUI
import WebKit

/// 从链接导入：贴一条别人的视频链接，豆仓把声音下下来，转成文字、整理，和自己的录音放在一起。
///
/// 下载交给 yt-dlp（这台 Mac 上要装着它和 ffmpeg），豆仓不自己去解各个平台的接口——那些接口三天两头变。
/// 只下声音，不存视频：要的是文字稿，不是原片。平台自带人工字幕的（多见于 YouTube）直接用字幕，不再转写一遍。
/// 要登录才能看的：弹一个登录窗口，用户自己在里面登录（扫码或输入，豆仓不经手密码），
/// 登录状态只存在这台 Mac 上，以后下载这个平台时带上。不读浏览器里的登录状态。
extension BeanStore {
    /// keepVideo：导入窗口里单独勾过「保留画面」的链接（没勾过的按设置）。
    func importLinks(_ text: String, keepVideo: [String: Bool] = [:]) {
        var skipped: [Recording] = []
        for url in LinkTools.urls(in: text) where !linkJobs.contains(where: { $0.url == url }) {
            // 导入过的同一条作品不再下一份（库里已经有好几份一样的，就是这么来的）
            if let old = importedRecording(for: url) { skipped.append(old); continue }
            var job = LinkJob(url: url, platform: LinkTools.platform(of: url))
            job.keepVideo = keepVideo[url]
            linkJobs.append(job)
        }
        if let first = skipped.first {
            addLog("跳过导入过的 \(skipped.count) 条：\(skipped.map(\.id))")
            toast("checkmark.circle", skipped.count == 1
                  ? String(localized: "导入过了，在素材里：\(String((first.title ?? first.origin ?? String(localized: "这条")).prefix(18)))")
                  : String(localized: "\(skipped.count) 条之前导入过，在素材里，没再下"))
        }
        guard linkWorker == nil else { return }
        linkWorker = Task { [weak self] in
            // 一条一条来：同时下好几条容易被平台限流
            while let self, let next = self.linkJobs.first {
                await self.runLink(next.id)
                self.linkJobs.removeAll { $0.id == next.id }
            }
            self?.linkWorker = nil
        }
    }

    private func runLink(_ id: UUID) async {
        guard let i = linkJobs.firstIndex(where: { $0.id == id }) else { return }
        linkJobs[i].working = true
        let url = linkJobs[i].url, platform = linkJobs[i].platform
        addLog("从链接导入：\(platform) \(url)")

        // 小红书、抖音、快手、TikTok：先用用户自己的下载工具 social-dl 的解析器（SocialDL.swift）
        if SocialDL.platforms.contains(platform) {
            if await importWithSocialDL(id, url, platform: platform) { return }
        }

        // 抖音：yt-dlp 的抖音下载要请求签名，常年报「Fresh cookies are needed」，登没登录都一样。
        // 改成在后台开一个看不见的网页窗口（和登录窗口共用登录状态）打开视频页，读页面自己拿到的视频信息。
        if platform == "抖音" {
            if await importDouyin(id, url) { return }
            addLog("抖音页面方式没拿到，改用 yt-dlp 再试")
        }
        // 视频号：yt-dlp 不认，走自己的一条路（ChannelsImport.swift）
        if platform == "视频号" {
            await importChannels(id, url)
            return
        }

        guard let tool = await Self.findTool("yt-dlp") else {
            problem = Problem(title: String(localized: "没找到下载工具 yt-dlp"), detail: String(localized: "从链接导入要靠它。在终端里运行下面这行装上，再试一次：\nbrew install yt-dlp ffmpeg"))
            linkJobs.removeAll()      // 后面排着的也都下不了
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let args = ["--no-playlist", "--no-warnings", "--newline", "--progress-template", "BP %(progress._percent_str)s",
                    "-f", "bestaudio/best", "-x", "--audio-format", "m4a",
                    "--write-info-json", "--write-subs", "--sub-langs", "zh-Hans,zh-CN,zh,zh-Hant,zh-TW,en",
                    "--sub-format", "vtt/srt/best", "--convert-subs", "vtt",
                    "-o", work.appendingPathComponent("media.%(ext)s").path, url]
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            // 进度行形如「BP  43.2%」
            guard line.hasPrefix("BP"), let percent = Double(line.dropFirst(2).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { return }
            Task { @MainActor in
                if let k = self?.linkJobs.firstIndex(where: { $0.id == id }) { self?.linkJobs[k].progress = percent / 100 }
            }
        }
        // 在豆仓里登录过这个平台：带上登录状态
        let cookies = Self.cookieFile(platform)
        let login = FileManager.default.fileExists(atPath: cookies.path) ? ["--cookies", cookies.path] : []
        // 换着网络路线最多试三次：开着代理软件的机器上，网络时好时坏，
        // 实测同一条链接这一次走代理通、直连被要求验证，下一次正好反过来。
        // 国内平台先直连：走代理时出口在海外，B 站的服务器直接回 HTTP 567 拒绝下载，直连一秒就下好了。
        // 国外平台先按系统的代理设置：直连多半连不上，白等 20 秒超时。
        let direct = ["--proxy", ""]
        let routes: [[String]] = Self.domesticPlatforms.contains(platform) ? [direct, [], direct] : [[], direct, []]
        var result = await Self.runTool(tool, login + routes[0] + args, onLine: onLine)
        // 被要求登录也换条路再试：YouTube 对直连常常要求「确认不是机器人」，走代理就不用
        for (n, route) in routes.dropFirst().enumerated() {
            guard result.status != 0, Self.looksLikeNetworkTrouble(result.errors) || Self.needsLogin(result.errors)
                    || Self.looksLikeRegionBlock(result.errors) else { break }
            addLog("第 \(n + 2) 次尝试（\(route.isEmpty ? "按系统代理设置" : "直连")），上次：\(result.errors.suffix(100))")
            result = await Self.runTool(tool, login + route + args, onLine: onLine)
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        let audio = files.first { ["m4a", "mp3", "opus", "ogg", "wav", "aac", "flac", "webm", "mp4"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.contains(".info.") }
        guard result.status == 0, let audio else {
            addLog("链接导入失败（\(result.status)）：\(result.errors.suffix(300))")
            if Self.needsLogin(result.errors), Self.loginPage(platform) != nil, login.isEmpty {
                // 要登录、还没登录过：弹登录窗口，登录好了再接着导入这一条
                linkLogin = LinkLoginRequest(platform: platform, url: url)
            } else if Self.needsLogin(result.errors), !login.isEmpty {
                // 已经登录过还是被拦：再弹登录窗口只会原地打转
                problem = Problem(title: String(localized: "这条\(platform)链接没能导入"),
                                  detail: String(localized: "已经带着你在密盒助手里的\(platform)登录状态试过了，还是被拦下。可能是登录过期了（去设置的「连接」里清掉重新登录），也可能是\(platform)改了接口。"))
            } else {
                problem = Problem(title: String(localized: "这条\(platform)链接没能导入"), detail: Self.explain(result.errors, platform: platform))
            }
            return
        }

        // 标题、作者从 yt-dlp 写下的信息文件里读
        var title = "", author = "", page = url
        if let info = files.first(where: { $0.lastPathComponent.hasSuffix(".info.json") }),
           let data = try? Data(contentsOf: info), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            author = (json["uploader"] as? String ?? json["channel"] as? String ?? json["creator"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            page = json["webpage_url"] as? String ?? url
        }
        // 平台自带的人工字幕：按中文优先挑一份
        let subs = files.filter { $0.pathExtension.lowercased() == "vtt" }
        let order = ["zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW", "en"]
        let best = subs.min { a, b in
            (order.firstIndex { a.lastPathComponent.contains(".\($0).") } ?? 99) < (order.firstIndex { b.lastPathComponent.contains(".\($0).") } ?? 99)
        }
        let cues = best.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(SubtitleParser.parse) ?? []
        finishLinkImport(id, audio: audio, title: title, author: author, page: page, platform: platform, cues: cues, fetchVideo: true)
    }

    /// 声音拿到之后：放进录音库，标好来源，交给整理。
    /// video：手上已有的视频文件（按规则决定留不留画面）；fetchVideo：只下了声音，要留画面时另外去下一份（yt-dlp 那一路）。
    func finishLinkImport(_ id: UUID, audio: URL, title: String, author: String, page: String, platform: String, cues: [SubtitleParser.Cue],
                          video: URL? = nil, fetchVideo: Bool = false) {
        if let k = linkJobs.firstIndex(where: { $0.id == id }) { linkJobs[k].title = title; linkJobs[k].progress = 1 }
        // 贴的是短链时，导入前认不出是哪条；解析出作品页后再查一次，导入过的不再放一份
        if let old = importedRecording(for: page) {
            addLog("链接导入：「\(title)」之前导入过（\(old.id)），这次下的不留")
            toast("checkmark.circle", String(localized: "导入过了，在素材里：\(String((old.title ?? title).prefix(18)))"))
            return
        }
        let before = Set(recordings.map(\.id))
        importFile(audio, consume: true, processNow: false)
        guard let k = recordings.firstIndex(where: { !before.contains($0.id) }) else {
            problem = Problem(title: String(localized: "这条\(platform)链接没能导入"), detail: String(localized: "声音下下来了，但密盒助手读不出这个音频文件。"))
            return
        }
        let rid = recordings[k].id
        recordings[k].title = title.isEmpty ? nil : String(title.prefix(80))
        recordings[k].titleEdited = !title.isEmpty        // 原作者起的标题留着，整理时不换
        recordings[k].origin = author.isEmpty ? platform : "\(platform) · @\(author)"
        recordings[k].source = page
        if cues.count >= 3 {
            recordings[k].segments = cues.map { Segment(start: $0.start, text: applyVocabulary($0.text)) }
            recordings[k].transcript = recordings[k].segments.map(\.text).joined(separator: "\n")
            recordings[k].transcribedBy = "平台字幕"
        }
        saveLibrary()
        addLog("链接导入完成：\(rid)「\(title)」\(cues.count >= 3 ? "，用了平台字幕 \(cues.count) 句" : "")")
        toast("checkmark.circle.fill", String(localized: "导入好了：\(title.isEmpty ? platform : String(title.prefix(18)))"))
        // 画面：按设置（和导入时的勾选）决定留不留
        let override = linkJobs.first { $0.id == id }?.keepVideo
        if let video, video != audio {
            adoptVideo(video, for: rid, override: override)
        } else if fetchVideo, wantsVideo(duration: recordings.first { $0.id == rid }?.duration, override: override) {
            self.fetchVideo(rid)
        }
        if settings.autoProcess { process(rid) }
    }

    /// 库里已经有的同一条作品（按作品键比，不管链接怎么写）。
    func importedRecording(for url: String) -> Recording? {
        guard let key = LinkTools.contentKey(of: url) else { return nil }
        return recordings.first { $0.source.flatMap(LinkTools.contentKey(of:)) == key }
    }

    /// 国内平台：下载先直连，不走代理
    nonisolated static let domesticPlatforms: Set = ["B 站", "抖音", "快手", "微博", "喜马拉雅", "小宇宙", "视频号", "小红书"]

    /// 平台按地区拦下载（出口 IP 不对）：换条网络路线常常就好
    nonisolated static func looksLikeRegionBlock(_ errors: String) -> Bool {
        let e = errors.lowercased()
        return ["http error 567", "ip address is blocked", "geo restrict", "not available in your country", "not available from your location"]
            .contains { e.contains($0) }
    }

    nonisolated static func needsLogin(_ errors: String) -> Bool {
        let e = errors.lowercased()
        return ["sign in", "log in", "login", "cookies", "confirm you", "not a bot", "需要登录", "请登录", "registered users"].contains { e.contains($0) }
    }

    nonisolated static func looksLikeNetworkTrouble(_ errors: String) -> Bool {
        let e = errors.lowercased()
        return ["ssl", "timed out", "timeout", "connection", "unable to download webpage", "unable to download api page", "proxy", "eof occurred", "network is unreachable"]
            .contains { e.contains($0) }
    }

    /// 把 yt-dlp 的报错换成人话。
    nonisolated static func explain(_ errors: String, platform: String) -> String {
        let e = errors.lowercased()
        if e.contains("unsupported url") { return String(localized: "认不出这是哪个平台的视频链接。确认贴的是某一条作品的链接，不是主页或搜索页。") }
        if needsLogin(errors) {
            return String(localized: "\(platform)要登录之后才给看这条内容。可以用别的工具把它下载成文件，再拖进密盒助手的窗口。")
        }
        if e.contains("private") { return String(localized: "这条内容是私密的，不能导入。") }
        if looksLikeRegionBlock(errors) {
            return String(localized: "\(platform)不让从现在的网络下载这条。直连和走代理都试过了，可以换个代理节点，或者关掉代理再试。")
        }
        if e.contains("429") || e.contains("too many requests") { return String(localized: "\(platform)嫌请求太频繁，过几分钟再试。") }
        if e.contains("403") || e.contains("forbidden") { return String(localized: "\(platform)拒绝了这次下载（403）。可能要登录，或者它最近改了接口，可以先升级 yt-dlp：brew upgrade yt-dlp") }
        if looksLikeNetworkTrouble(errors) {
            return String(localized: "连不上\(platform)。看看网络，再试一次。")
        }
        if e.contains("ffmpeg") || e.contains("ffprobe") { return String(localized: "这台 Mac 上没有 ffmpeg，声音转不出来。在终端里运行：brew install ffmpeg") }
        let last = errors.split(separator: "\n").last(where: { $0.lowercased().contains("error") }) ?? errors.split(separator: "\n").last ?? ""
        return last.isEmpty ? String(localized: "下载工具没有说明原因。") : String(last.prefix(220))
    }

    // MARK: 调外部工具

    /// 找命令行工具。从图形界面启动的应用拿不到终端里的 PATH，所以先看常见位置，再借登录 shell 找一遍。
    nonisolated static func findTool(_ name: String) async -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let found = await runTool("/bin/zsh", ["-lc", "command -v \(name)"]) { _ in }.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: found) ? found : nil
    }

    nonisolated static func runTool(_ path: String, _ args: [String], env extra: [String: String] = [:], cwd: URL? = nil,
                                    onLine: @Sendable @escaping (String) -> Void) async -> (status: Int32, output: String, errors: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env.merge(extra) { _, new in new }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let collected = Collected()
            out.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self)
                guard !text.isEmpty else { return }
                collected.add(text)
                text.split(whereSeparator: \.isNewline).forEach { onLine(String($0)) }
            }
            do { try p.run() } catch { return (Int32(-1), "", error.localizedDescription) }
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            return (p.terminationStatus, collected.text, errors)
        }.value
    }
}

private nonisolated final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func add(_ s: String) { lock.withLock { buffer += s } }
    var text: String { lock.withLock { buffer } }
}

// MARK: - 粘贴链接的窗口

struct LinkImportSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var typing: Bool
    /// 要先登录的平台（导入前就看得出来的）
    @State private var mustLogin: Set<String> = []
    /// 从这里打开的登录窗口
    @State private var login: LinkLoginRequest?
    /// 登录窗口关上后加一，让「已登录」重新看一遍
    @State private var loginTick = 0
    /// 单独勾过「保留画面」的链接；没勾过的按设置（设计稿 design/ui/ui_video_import.png）
    @State private var keep: [String: Bool] = [:]

    /// 只有声音的平台不给「保留画面」
    private static func audioOnly(_ platform: String) -> Bool { ["喜马拉雅", "小宇宙", "播客"].contains { platform.contains($0) } }

    private var urls: [String] { LinkTools.urls(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("从链接导入").font(.title2.bold())
                Text("粘贴视频链接或整段分享口令，可以一次贴好几条。").font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body).focused($typing)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(typing ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.separator), lineWidth: typing ? 1.5 : 0.5))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: String(localized: "比如：https://www.bilibili.com/video/BV…")).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
            if !urls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        if url != urls.first { Divider().padding(.leading, 34) }
                        let platform = LinkTools.platform(of: url)
                        let logged = loginTick >= 0 && BeanStore.isLoggedIn(platform)
                        let old = store.importedRecording(for: url)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 10) {
                                Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent)
                                    .frame(width: 24, height: 24).background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: Theme.Radius.chip))
                                Text(platform).fontWeight(.medium)
                                Text(url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if old != nil {
                                    Text("已导入过").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                } else {
                                    loginState(platform: platform, url: url, logged: logged)
                                    if !Self.audioOnly(platform) {
                                        Toggle("保留画面", isOn: Binding(get: { keep[url] ?? (store.settings.keepVideo != .never) },
                                                                      set: { keep[url] = $0 }))
                                            .toggleStyle(.checkbox).font(.caption).fixedSize()
                                            .help(keep[url] == nil && store.settings.keepVideo == .short ? "按设置：5 分钟以内的才留画面；勾选或取消就按你选的" : "保留 720p 画面")
                                    }
                                }
                            }
                            if let old {
                                Text("「\(String((old.title ?? old.origin ?? String(localized: "这条")).prefix(30)))」已经在素材里，这条会跳过。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 34).fixedSize(horizontal: false, vertical: true)
                            } else if mustLogin.contains(platform), !logged, let why = Self.why(platform) {
                                // 要先登录的，说一句为什么、登录会打开哪里
                                Text(why).font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 34).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .panel(radius: Theme.Radius.card)
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("这段文字里没有找到链接。", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            Text(store.settings.keepVideo == .short
                 ? "只导入你有权保存的公开内容。画面按设置保留（5 分钟以内的留 720p，没单独勾过的照这个来），声音用来转成文字。"
                 : "只导入你有权保存的公开内容。勾了「保留画面」的留 720p 画面，声音用来转成文字。")
                .font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                let fresh = urls.filter { store.importedRecording(for: $0) == nil }.count
                Button(fresh > 1 ? "导入 \(fresh) 条" : "导入") {
                    store.importLinks(text, keepVideo: keep)
                    dismiss()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(fresh == 0)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear {
            // 剪贴板里正好是链接，就先替人贴上
            if let clip = NSPasteboard.general.string(forType: .string), clip.count < 2000, !LinkTools.urls(in: clip).isEmpty { text = clip }
            typing = true
        }
        // 贴进来的平台里哪些要先登录（小红书要探一下这台 Mac 是不是被当成海外访问）
        .task(id: Set(urls.map(LinkTools.platform(of:)))) {
            for platform in Set(urls.map(LinkTools.platform(of:))) where await LoginNeeds.required(platform) {
                mustLogin.insert(platform)
            }
        }
        .sheet(item: $login, onDismiss: { loginTick += 1 }) { request in LinkLoginSheet(request: request) }
    }

    /// 行尾：登录过的写「已登录」；要先登录还没登的给「登录」按钮；别的打个勾表示认出来了
    @ViewBuilder
    private func loginState(platform: String, url: String, logged: Bool) -> some View {
        if logged {
            HStack(spacing: 5) {
                Text("已登录").font(.caption.weight(.medium))
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(Theme.ok)
        } else if mustLogin.contains(platform) {
            HStack(spacing: 6) {
                Text("要先登录").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.chip))
                Button("登录") { login = LinkLoginRequest(platform: platform, url: url, continueImport: false) }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.accent.opacity(0.75), lineWidth: 1))
                    .contentShape(.rect(cornerRadius: Theme.Radius.chip))
            }
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        }
    }

    private static func why(_ platform: String) -> String? {
        switch platform {
        case "小红书": String(localized: "这台 Mac 走的是海外网络，小红书要登录才给看笔记。会直接打开这条笔记，在页面上登录。")
        case "视频号": String(localized: "视频号借腾讯元宝解析，要用微信扫码登录元宝，只要登一次。")
        default: nil
        }
    }
}

// MARK: - 登录

extension BeanStore {
    /// 每个平台的登录状态存一个文件，只在这台 Mac 上，只有自己能读。
    nonisolated static func cookieFile(_ platform: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/Logins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = platform.replacingOccurrences(of: " ", with: "")
        return dir.appendingPathComponent("\(safe).cookies.txt")
    }

    /// 平台的登录页，和它的登录状态落在哪些域名下。
    nonisolated static func loginPage(_ platform: String) -> (url: String, domains: [String])? {
        switch platform {
        case "B 站": ("https://passport.bilibili.com/login", ["bilibili.com"])
        case "抖音": ("https://www.douyin.com/", ["douyin.com"])
        // 海外访问会被跳到 rednote.com，登录状态落在那边
        case "小红书": ("https://www.xiaohongshu.com/explore", ["xiaohongshu.com", "rednote.com"])
        case "YouTube": ("https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F", ["youtube.com", "google.com"])
        case "TikTok": ("https://www.tiktok.com/login", ["tiktok.com"])
        case "快手": ("https://www.kuaishou.com/", ["kuaishou.com"])
        case "微博": ("https://passport.weibo.com/sso/signin", ["weibo.com", "weibo.cn"])
        case "X": ("https://x.com/i/flow/login", ["x.com", "twitter.com"])
        case "Instagram": ("https://www.instagram.com/accounts/login/", ["instagram.com"])
        // 视频号借腾讯元宝解析：登录的是元宝（微信扫码）
        case "视频号": ("https://yuanbao.tencent.com/", ["tencent.com"])
        default: nil
        }
    }

    /// 登录窗口打开哪一页：小红书、抖音直接打开要导入的这一条——在作品页上登录，登好就看到这条内容；
    /// 别的平台打开它的登录页（视频号登录的是腾讯元宝）。
    nonisolated static func loginURL(platform: String, link: String) -> URL {
        if ["小红书", "抖音"].contains(platform), let url = URL(string: link), url.host != nil { return url }
        return URL(string: loginPage(platform)?.url ?? "about:blank")!
    }

    nonisolated static func isLoggedIn(_ platform: String) -> Bool {
        FileManager.default.fileExists(atPath: cookieFile(platform).path)
    }

    var loggedInPlatforms: [String] {
        ["B 站", "抖音", "小红书", "YouTube", "TikTok", "快手", "微博", "X", "Instagram", "视频号"]
            .filter { FileManager.default.fileExists(atPath: Self.cookieFile($0).path) }
    }

    func forgetLogin(_ platform: String) {
        try? FileManager.default.removeItem(at: Self.cookieFile(platform))
        // 登录窗口里那份也清掉，不然下次打开还是登录着的
        let store = WKWebsiteDataStore.default()
        let domains = Self.loginPage(platform)?.domains ?? []
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { r in domains.contains { r.displayName.hasSuffix($0) } }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {}
        }
        addLog("清掉了\(platform)的登录状态")
    }

    /// 把登录窗口里的登录状态写成下载工具认的格式（Netscape cookies.txt）。返回写进去了几条。
    func saveLogin(_ platform: String) async -> Int {
        guard let domains = Self.loginPage(platform)?.domains else { return 0 }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let mine = all.filter { c in domains.contains { c.domain == $0 || c.domain.hasSuffix("." + $0) } }
        guard !mine.isEmpty else { return 0 }
        // 元宝没扫码时也会种几条访客 cookie，要看到登录票据才算登好了
        if platform == "视频号", !mine.contains(where: { $0.name == "hy_token" && !$0.value.isEmpty }) { return 0 }
        var lines = ["# Netscape HTTP Cookie File", "# 密盒助手的登录窗口导出，只用于下载你自己能看的内容"]
        for c in mine {
            let domain = c.domain.hasPrefix(".") ? c.domain : "." + c.domain
            let expiry = Int(c.expiresDate?.timeIntervalSince1970 ?? Date.now.addingTimeInterval(86400 * 30).timeIntervalSince1970)
            lines.append([domain, "TRUE", c.path, c.isSecure ? "TRUE" : "FALSE", String(expiry), c.name, c.value].joined(separator: "\t"))
        }
        let file = Self.cookieFile(platform)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        addLog("保存了\(platform)的登录状态（\(mine.count) 条）")
        return mine.count
    }
}

/// 登录窗口：豆仓里开一个小浏览器，打开平台的登录页，用户自己扫码或输入登录。
/// 豆仓不碰账号密码，只在用户点「登录好了」之后把这个窗口里的登录状态存下来。
struct LinkLoginSheet: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: LinkLoginRequest
    @State private var saving = false
    @State private var note: String?

    private var then: String { request.continueImport ? String(localized: "，密盒助手会接着导入") : String(localized: "回到导入") }
    private var onItsPage: Bool { BeanStore.loginURL(platform: request.platform, link: request.url).absoluteString == request.url }
    /// 登录窗口顶上的说明
    private var intro: String {
        if request.platform == "视频号" {
            return String(localized: "\(request.hint)视频号网页版不给下载地址，密盒助手借腾讯元宝的视频号解析拿视频。在下面点「登录」用微信扫码，登好了点右边的按钮\(then)。只要登一次。")
        }
        if onItsPage {
            let kind = request.platform == "小红书" ? String(localized: "笔记") : String(localized: "作品")
            return String(localized: "\(request.hint)下面打开的就是这条\(kind)，在页面上扫码或输入账号登录，登好了点右边的按钮\(then)。")
        }
        return String(localized: "\(request.hint)在下面扫码或输入账号登录，登好了点右边的按钮\(then)。")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.platform == "视频号" ? "用微信扫码登录腾讯元宝" : "在\(request.platform)登录一下").font(.headline)
                    Text(note ?? intro)
                        .font(.callout).foregroundStyle(note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    saving = true
                    Task {
                        let n = await store.saveLogin(request.platform)
                        saving = false
                        if n == 0 {
                            note = String(localized: "还没有看到登录状态。确认登录成功了再点一次。")
                        } else {
                            dismiss()
                            if request.continueImport { store.importLinks(request.url) }
                        }
                    }
                } label: { Text(saving ? "正在保存…" : request.continueImport ? "登录好了，接着导入" : "登录好了") }
                .buttonStyle(.glassProminent).disabled(saving)
            }
            .padding(16)
            Divider()
            LoginWebView(url: BeanStore.loginURL(platform: request.platform, link: request.url),
                         direct: request.platform == "视频号" ? LoginProxy.tencent : [])
            Divider()
            Text("登录状态只存在这台 Mac 上，用来下载你自己能看的内容。不想要了可以在设置的「连接」里清掉。")
                .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
        }
        .frame(width: 900, height: 720)
    }
}

private struct LoginWebView: NSViewRepresentable {
    let url: URL
    /// 这些域名不走系统代理（只在这个窗口开着的时候）
    var direct: [String] = []

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if !direct.isEmpty { LoginProxy.bypass(direct) }
        let web = WKWebView(frame: .zero, configuration: config)
        // 用普通 Safari 的身份，不然有的平台会把登录页换成「请用 App 打开」
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: ()) {
        LoginProxy.reset()
    }
}

/// 导入前就看得出来哪些链接要先登录：
/// 视频号一定要（借腾讯元宝解析）；小红书在这台 Mac 被当成海外访问时要（xiaohongshu.com 会跳到 rednote.com，那边要登录才给看笔记）。
@MainActor
enum LoginNeeds {
    private static var xhsOverseas: Bool?

    static func required(_ platform: String) async -> Bool {
        switch platform {
        case "视频号": return true
        case "小红书":
            if let xhsOverseas { return xhsOverseas }
            guard let to = await redirectTarget(URL(string: "https://www.xiaohongshu.com/explore")!) else { return false }   // 没探成功不记，下次再探
            xhsOverseas = to.contains("rednote.")
            return xhsOverseas ?? false
        default: return false
        }
    }

    /// 只问一次、不跟跳转，看它往哪跳。没跳返回空字符串，连不上返回 nil。
    nonisolated static func redirectTarget(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(ChannelsAPI.agent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request, delegate: NoRedirect()),
              let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "Location") ?? ""
    }

    private nonisolated final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

/// 开着代理软件的机器上，微信的几个站（open.weixin.qq.com 的扫码二维码、channels.weixin.qq.com）走代理会在握手时被断开，
/// 直连是好的。视频号的登录窗口开着时，让登录窗口用的那份网页数据对腾讯的域名直连，别的照旧走系统代理；关窗就还原。
/// 不改系统和代理软件的设置。
@MainActor
enum LoginProxy {
    static let tencent = ["qq.com", "tencent.com", "qlogo.cn", "qpic.cn", "gtimg.cn", "gtimg.com", "idqqimg.com"]

    static func bypass(_ domains: [String]) {
        // 读系统当前的代理；没开代理就本来是直连，什么都不用做
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return }
        let (hostKey, portKey) = (settings["HTTPSEnable"] as? Int) == 1 ? ("HTTPSProxy", "HTTPSPort")
            : (settings["HTTPEnable"] as? Int) == 1 ? ("HTTPProxy", "HTTPPort") : ("", "")
        guard let host = settings[hostKey] as? String, !host.isEmpty,
              let raw = settings[portKey] as? Int, let port = NWEndpoint.Port(rawValue: UInt16(clamping: raw)) else { return }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(host), port: port))
        proxy.excludedDomains = domains + ((settings["ExceptionsList"] as? [String]) ?? []).filter { !$0.contains("/") && !$0.hasPrefix("<") }
        WKWebsiteDataStore.default().proxyConfigurations = [proxy]
    }

    static func reset() {
        WKWebsiteDataStore.default().proxyConfigurations = []
    }
}

// MARK: - 抖音：用看不见的网页窗口拿视频信息

extension BeanStore {
    /// 成功放进录音库返回 true；拿不到返回 false，交给 yt-dlp 再试。
    fileprivate func importDouyin(_ id: UUID, _ url: String) async -> Bool {
        let page = DouyinPage()
        guard let found = await page.fetch(url) else { return false }
        addLog("抖音页面拿到了：\(found.awemeId)「\(found.title.prefix(30))」，\(found.media.count) 个音视频地址")
        if let k = linkJobs.firstIndex(where: { $0.id == id }) { linkJobs[k].title = found.title; linkJobs[k].progress = 0.2 }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 地址按「纯音频 → 带声音的视频」排好了，挨个试，下到一个能用的就停；要留画面时反过来，先要带画面的
        var media: URL?
        let wantVideo = mightKeepVideo(linkJobs.first { $0.id == id })
        for link in wantVideo ? found.media.reversed() : found.media {
            var request = URLRequest(url: link, timeoutInterval: 60)
            request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            request.setValue(DouyinPage.agent, forHTTPHeaderField: "User-Agent")
            guard let (tmp, response) = try? await URLSession.shared.download(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int, size > 20_000 else { continue }
            let dest = work.appendingPathComponent("raw.mp4")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            media = dest
            break
        }
        guard let media else { addLog("抖音的音视频地址都没下下来"); return false }
        if let k = linkJobs.firstIndex(where: { $0.id == id }) { linkJobs[k].progress = 0.8 }

        let audio = await audioTrack(of: media, in: work) ?? media
        finishLinkImport(id, audio: audio, title: found.title, author: found.author,
                         page: "https://www.douyin.com/video/\(found.awemeId)", platform: "抖音", cues: [], video: media)
        return true
    }
}

extension BeanStore {
    /// 只留声音：把下下来的视频抽成 m4a。没有 ffmpeg 就原样交给导入；ffmpeg 读不了这个文件返回 nil。
    func audioTrack(of media: URL, in work: URL) async -> URL? {
        guard let ffmpeg = await Self.findTool("ffmpeg") else { return media }
        let out = work.appendingPathComponent("media.m4a")
        let r = await Self.runTool(ffmpeg, ["-v", "error", "-y", "-i", media.path, "-vn", "-c:a", "aac", "-b:a", "128k", out.path]) { _ in }
        if r.status == 0, FileManager.default.fileExists(atPath: out.path) { return out }
        addLog("抽声音失败：\(r.errors.suffix(200))")
        return nil
    }
}

/// 在后台开一个看不见的网页窗口打开抖音视频页，听页面自己请求的作品详情，读出标题、作者和音视频地址。
/// 和登录窗口共用同一份登录状态（WKWebsiteDataStore.default），登录过的话能看到更多内容。
@MainActor
private final class DouyinPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Found { var awemeId: String; var title: String; var author: String; var media: [URL] }

    nonisolated static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var web: WKWebView?
    private var window: NSWindow?
    private var detail: [String: Any]?

    /// 在页面自己的脚本之前装好：作品详情接口一回来，就把原文递给豆仓。
    private static let hook = """
    (function(){
      if (window.__bpHooked) return; window.__bpHooked = true;
      var want = function(u){ return /aweme\\/v1\\/web\\/aweme\\/detail/.test(String(u||'')); };
      var send = function(t){ try { window.webkit.messageHandlers.bp.postMessage(String(t)); } catch(e){} };
      var of = window.fetch;
      if (of) window.fetch = function(i, o){
        var u = typeof i === 'string' ? i : (i && i.url);
        var p = of.apply(this, arguments);
        if (want(u)) p.then(function(r){ r.clone().text().then(send); }).catch(function(){});
        return p;
      };
      var op = XMLHttpRequest.prototype.open, sd = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__bp = u; return op.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        if (want(x.__bp)) x.addEventListener('load', function(){
          try { send(x.responseType === 'json' ? JSON.stringify(x.response) : (x.responseType === '' || x.responseType === 'text' ? x.responseText : '')); } catch(e){}
        });
        return sd.apply(this, arguments);
      };
    })();
    """

    func fetch(_ link: String) async -> Found? {
        guard let id = await Self.awemeId(link) else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        ucc.add(self, contentWorld: .page, name: "bp")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        web.customUserAgent = Self.agent
        // 放进一个透明、不抢焦点的窗口里：没有窗口的网页会被系统降速，视频也不加载
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = web
        window.orderBack(nil)
        self.web = web; self.window = window
        defer {
            ucc.removeScriptMessageHandler(forName: "bp", contentWorld: .page)
            web.stopLoading()
            window.orderOut(nil)
            self.web = nil; self.window = nil
        }
        web.load(URLRequest(url: URL(string: "https://www.douyin.com/video/\(id)")!))

        // 最多等 25 秒：先等详情接口；接口没听到的话，退而看页面已经在播的音轨
        var title = "", author = ""
        var media: [URL] = []
        for tick in 0..<50 {
            try? await Task.sleep(for: .milliseconds(500))
            if let d = detail {
                title = (d["desc"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                author = ((d["author"] as? [String: Any])?["nickname"] as? String) ?? ""
                let video = d["video"] as? [String: Any] ?? [:]
                // 纯音轨（新视频是音视频分开的）优先，再是带声音的整段视频，最后是配乐
                var lists: [Any?] = []
                if let bits = video["bit_rate_audio"] as? [[String: Any]] {
                    lists += bits.map { (($0["audio_meta"] as? [String: Any])?["url_list"] as? [String: Any])?["main_url"] }
                }
                lists.append((video["play_addr"] as? [String: Any])?["url_list"])
                lists.append((video["download_addr"] as? [String: Any])?["url_list"])
                if (video["play_addr"] as? [String: Any]) == nil {
                    lists.append(((d["music"] as? [String: Any])?["play_url"] as? [String: Any])?["url_list"])
                }
                for item in lists {
                    let strings = (item as? [String]) ?? ((item as? String).map { [$0] } ?? [])
                    media += strings.compactMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
                }
            }
            if media.isEmpty, tick >= 10, let found = try? await web.evaluateJavaScript(
                "performance.getEntriesByType('resource').map(function(e){return e.name}).filter(function(n){return /media-audio/.test(n)}).slice(-1)[0] || ''") as? String,
               let u = URL(string: found), !found.isEmpty {
                media = [u]
            }
            if !media.isEmpty {
                if title.isEmpty, let t = try? await web.evaluateJavaScript("document.title") as? String {
                    title = t.replacingOccurrences(of: " - 抖音", with: "").trimmingCharacters(in: .whitespaces)
                }
                return Found(awemeId: id, title: title, author: author, media: media)
            }
        }
        return nil
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["aweme_detail"] as? [String: Any] else { return }
        let box = SendableDict(d)
        MainActor.assumeIsolated { self.detail = box.value }
    }

    /// 从各种分享链接里找出作品号：v.douyin.com 短链先跟一次跳转。
    static func awemeId(_ link: String) async -> String? {
        func pick(_ s: String) -> String? {
            for pattern in [#"/video/(\d{8,})"#, #"/note/(\d{8,})"#, #"modal_id=(\d{8,})"#, #"aweme_id=(\d{8,})"#] {
                if let r = s.range(of: pattern, options: .regularExpression) {
                    return String(s[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).filter { $0.count >= 8 }.first
                }
            }
            return nil
        }
        if let id = pick(link) { return id }
        guard let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request), let final = response.url?.absoluteString else { return nil }
        return pick(final)
    }
}

private nonisolated struct SendableDict: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
