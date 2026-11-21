import Foundation

/// 用户自己的下载工具 social-dl：它的 dl.py、subtitles.py 原样打包在豆仓里（App/SocialDL），
/// 旁边一个 beanpod_social.py 薄包装负责调用它、一行一行回报进度。
/// 小红书、抖音、快手、TikTok 先交给它自己写的解析器；它拿不到，豆仓再走自己的路（抖音的隐藏网页、yt-dlp）。
///
/// 它要 Python 和两个包（curl_cffi、httpx）。第一次用时在 Application Support/BeanPod/social-dl 里
/// 建一个单独的 Python 环境装上，不碰系统的 Python。
extension BeanStore {
    /// 成功放进录音库，或者已经确定这条导入不了（比如图文笔记没有声音），返回 true；
    /// 返回 false 表示交给后面的方式再试。
    func importWithSocialDL(_ id: UUID, _ url: String, platform: String) async -> Bool {
        if !SocialDL.isReady { setJobTitle(id, String(localized: "第一次用 social-dl，正在准备下载组件…")) }
        let prepared = await SocialDL.prepare()
        guard let python = prepared.python else {
            addLog("social-dl 没准备好：\(prepared.note)")
            setJobTitle(id, nil)
            return false
        }
        if !prepared.note.isEmpty { addLog(prepared.note) }
        setJobTitle(id, nil)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-sdl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            guard let event = SocialDL.event(line), event["type"] as? String == "progress",
                  let got = event["received"] as? Double, let total = event["total"] as? Double, total > 0 else { return }
            Task { @MainActor in
                if let k = self?.linkJobs.firstIndex(where: { $0.id == id }) { self?.linkJobs[k].progress = 0.1 + 0.7 * min(1, got / total) }
            }
        }
        // 在豆仓登录窗口里登录过这个平台：把登录状态交给它（小红书没有登录常常只给低清）
        let cookie = Self.cookieHeader(platform)
        var env: [String: String] = cookie.isEmpty ? [:] : ["BEANPOD_COOKIE": cookie]
        if mightKeepVideo(linkJobs.first { $0.id == id }) { env["BEANPOD_WANT_VIDEO"] = "1" }   // 要留画面：小红书别只挑纯音频流
        let run = await Self.runTool(python, ["-B", SocialDL.home.appendingPathComponent("beanpod_social.py").path, url, work.path],
                                     env: env, onLine: onLine)
        let result = run.output.split(separator: "\n").reversed().lazy.compactMap { SocialDL.event(String($0)) }.first { $0["type"] as? String == "result" }
        guard let result, result["ok"] as? Bool == true else {
            let why = (result?["error"] as? String) ?? String(run.errors.suffix(300))
            // 被拦在登录页：没登录过就弹豆仓的登录窗口，登好了接着导入；登录过还被拦就说清楚，别原地打转
            if let wall = result?["needs_login"] as? String, !wall.isEmpty, Self.loginPage(platform) != nil {
                addLog("social-dl：\(platform)要登录（\(why.prefix(80))）")
                if cookie.isEmpty {
                    linkLogin = LinkLoginRequest(platform: platform, url: url, hint: platform == "小红书"
                        ? String(localized: "小红书把这台 Mac 当成海外访问，跳到了 rednote.com，那边要登录才给看笔记。用小红书 App 扫码登录一次就行。")
                        : "")
                } else {
                    problem = Problem(title: String(localized: "这条\(platform)链接没能导入"),
                                      detail: String(localized: "已经带着你在密盒助手里的\(platform)登录状态试过了，还是被拦在登录页。可能是登录过期了，去设置的「连接」里退出后重新登录。"))
                }
                return true
            }
            addLog("social-dl 没拿到（\(run.status)）：\(why.prefix(200))，换下一种方式")
            return false
        }
        let title = (result["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (result["author"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (result["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        addLog("social-dl 拿到了（\(result["engine"] as? String ?? "")）：「\(title.prefix(30))」，\(files.count) 个文件")

        let media = files.first { ["mp4", "m4a", "mp3", "mov", "m4v", "webm", "aac", "flv", "mkv"].contains($0.pathExtension.lowercased()) }
        guard let media else {
            // 小红书图文笔记：只有图片，没有声音可转
            problem = Problem(title: String(localized: "这条\(platform)没有声音"),
                              detail: String(localized: "「\(String(title.prefix(40)))」是图文，没有视频或音频，转不了文字。"))
            return true
        }
        if let k = linkJobs.firstIndex(where: { $0.id == id }) { linkJobs[k].title = title; linkJobs[k].progress = 0.85 }
        let audio = await audioTrack(of: media, in: work) ?? media
        // 抖音的分享短链会过期，记下作品页的正式地址
        let douyinId = platform == "抖音" ? (result["id"] as? String ?? "") : ""
        finishLinkImport(id, audio: audio, title: title, author: author,
                         page: douyinId.isEmpty ? url : "https://www.douyin.com/video/\(douyinId)",
                         platform: platform, cues: [], video: media)
        return true
    }

    private func setJobTitle(_ id: UUID, _ title: String?) {
        if let k = linkJobs.firstIndex(where: { $0.id == id }) { linkJobs[k].title = title }
    }

    /// 豆仓登录窗口里存下的这个平台的登录状态，拼成一行请求头。没登录过是空的。
    nonisolated static func cookieHeader(_ platform: String) -> String {
        guard let text = try? String(contentsOf: cookieFile(platform), encoding: .utf8) else { return "" }
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 7, seen.insert(String(f[5])).inserted else { return nil }
            return "\(f[5])=\(f[6])"
        }.joined(separator: "; ")
    }
}

nonisolated enum SocialDL {
    /// 交给它自己的解析器的平台（视频号豆仓自己做，别的平台它也是转给 yt-dlp）
    static let platforms: Set<String> = ["小红书", "抖音", "快手", "TikTok"]
    static let scripts = ["dl.py", "subtitles.py", "beanpod_social.py"]
    static let packages = ["curl_cffi", "httpx[http2]"]

    static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanPod/social-dl", isDirectory: true)
    }
    static var python: URL { home.appendingPathComponent("venv/bin/python") }
    static var marker: URL { home.appendingPathComponent("venv/.beanpod-ready") }
    static var isReady: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// 把脚本放到位、Python 环境建好。返回能用的 python；不能用时 python 为 nil，note 说明原因。
    static func prepare() async -> (python: String?, note: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        // 每次都从豆仓里拷一份最新的脚本过去（脚本跟着豆仓的版本走）
        for name in scripts {
            let base = (name as NSString).deletingPathExtension
            guard let src = Bundle.main.url(forResource: base, withExtension: "py") else { return (nil, "密盒助手里没找到 \(name)") }
            let dst = home.appendingPathComponent(name)
            if fm.contentsEqual(atPath: src.path, andPath: dst.path) { continue }
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: src, to: dst) } catch { return (nil, "放不下 \(name)：\(error.localizedDescription)") }
        }
        if isReady, fm.isExecutableFile(atPath: python.path) { return (python.path, "") }

        // 第一次：找一个 Python 3，建单独的环境，装上它要的包
        guard let system = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return (nil, "这台 Mac 上没有 Python 3。在终端里运行：brew install python")
        }
        try? fm.removeItem(at: home.appendingPathComponent("venv"))
        let venv = await BeanStore.runTool(system, ["-m", "venv", home.appendingPathComponent("venv").path]) { _ in }
        guard venv.status == 0, fm.isExecutableFile(atPath: python.path) else {
            return (nil, "建 Python 环境失败：\(venv.errors.suffix(200))")
        }
        let pip = ["-m", "pip", "install", "-q", "--disable-pip-version-check"] + packages
        // 先直连装；不通再按系统代理装
        var install = await BeanStore.runTool(python.path, pip) { _ in }
        if install.status != 0, let proxy = systemProxy() {
            install = await BeanStore.runTool(python.path, pip, env: ["HTTPS_PROXY": proxy, "HTTP_PROXY": proxy]) { _ in }
        }
        guard install.status == 0 else { return (nil, "装 social-dl 要的包失败：\(install.errors.suffix(240))") }
        try? Data(packages.joined(separator: " ").utf8).write(to: marker)
        return (python.path, "social-dl 的下载组件准备好了（\(system)）")
    }

    /// 系统代理设置里的 HTTPS 代理，写成 http://主机:端口
    static func systemProxy() -> String? {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              (s["HTTPSEnable"] as? Int) == 1, let host = s["HTTPSProxy"] as? String, let port = s["HTTPSPort"] as? Int else { return nil }
        return "http://\(host):\(port)"
    }

    /// 包装脚本的一行回报：「BPJSON {...}」
    static func event(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("BPJSON ") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8))) as? [String: Any]
    }
}
