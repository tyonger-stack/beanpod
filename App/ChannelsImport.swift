import Foundation

/// 视频号：yt-dlp 不认这个平台，豆仓自己走一条路，办法照用户那个下载工具（social-dl）来：
///
/// 1. 视频号网页版的作品接口不登录也能问，但只给标题、作者和封面，不给视频地址。
/// 2. 腾讯元宝能解析视频号链接：用微信扫码登录元宝之后，把分享链接交给它，它回一张视频号的预览凭证。
/// 3. 拿这张凭证再去问视频号的作品接口，就有视频地址了。
///
/// 登录在豆仓自己的登录窗口里，用户自己扫码；豆仓只把元宝的登录状态存在这台 Mac 上（和别的平台一样，设置里能清掉）。
extension BeanStore {
    func importChannels(_ id: UUID, _ url: String) async {
        let platform = "视频号"
        guard let sph = ChannelsAPI.sphId(url) else {
            problem = Problem(title: String(localized: "这条视频号链接没能导入"),
                              detail: String(localized: "链接里没找到作品号。在视频号里点「分享 → 复制链接」，贴进来的应该是 https://weixin.qq.com/sph/… 这样的链接。"))
            return
        }
        // 不登录也能看到标题和作者：先填上，列表里认得出是哪一条
        let preview = await ChannelsAPI.preview(sph)
        if let preview {
            addLog("视频号作品 \(sph)：@\(preview.author)「\(preview.title.prefix(30))」")
            setLinkJob(id, title: preview.title, progress: 0.1)
        }
        let known = preview.map { String(localized: "已经认出这条视频号：\($0.author.isEmpty ? "" : "@\($0.author) · ")\(String($0.title.prefix(36)))。") } ?? ""

        let file = Self.cookieFile(platform)
        guard let cookie = ChannelsAPI.cookieHeader(file) else {
            addLog("视频号要先在密盒助手里扫码登录腾讯元宝")
            linkLogin = LinkLoginRequest(platform: platform, url: url, hint: known)
            return
        }

        switch await ChannelsAPI.video(share: url, cookie: cookie) {
        case .expired(let why):
            addLog("元宝没给视频号预览凭证：\(why)")
            // 刚扫完码还是不行，再弹登录窗口只会原地打转
            let justLoggedIn = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date.now.timeIntervalSince($0) < 300 } ?? false
            if justLoggedIn {
                problem = Problem(title: String(localized: "这条视频号链接没能导入"),
                                  detail: String(localized: "\(known)刚登录的腾讯元宝没解析出这条视频\(why.isEmpty ? "" : "（\(why)）")。可能这条作品不让在网页上看，过一会儿再试。"))
            } else {
                try? FileManager.default.removeItem(at: file)
                linkLogin = LinkLoginRequest(platform: platform, url: url, hint: String(localized: "\(known)上次在密盒助手登录的腾讯元宝过期了，再扫一次码。"))
            }
        case .failed(let why):
            addLog("视频号导入失败：\(why)")
            problem = Problem(title: String(localized: "这条视频号链接没能导入"), detail: known + why)
        case .found(let feed):
            let title = feed.title.isEmpty ? (preview?.title ?? "") : feed.title
            let author = feed.author.isEmpty ? (preview?.author ?? "") : feed.author
            addLog("视频号拿到 \(feed.videos.count) 个视频地址")
            setLinkJob(id, title: title, progress: 0.3)

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-link-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let media = work.appendingPathComponent("raw.mp4")
            var got = false
            for link in feed.videos where !got { got = await ChannelsAPI.download(link, to: media) }
            guard got else {
                problem = Problem(title: String(localized: "这条视频号链接没能导入"), detail: String(localized: "\(known)视频地址拿到了，但没下下来。看看网络，再试一次。"))
                return
            }
            setLinkJob(id, title: title, progress: 0.8)
            guard let audio = await audioTrack(of: media, in: work) else {
                // 下下来的文件抽不出声音：多半是加密过的视频，或者给的不是视频
                problem = Problem(title: String(localized: "这条视频号链接没能导入"), detail: String(localized: "\(known)视频下下来了，但抽不出声音，可能是加密过的视频。"))
                return
            }
            finishLinkImport(id, audio: audio, title: title, author: author,
                             page: "https://weixin.qq.com/sph/\(sph)", platform: platform, cues: [], video: media)
        }
    }

    private func setLinkJob(_ id: UUID, title: String, progress: Double) {
        guard let k = linkJobs.firstIndex(where: { $0.id == id }) else { return }
        if !title.isEmpty { linkJobs[k].title = title }
        linkJobs[k].progress = progress
    }
}

/// 视频号和腾讯元宝的两个接口。纯网络活，不碰界面。
nonisolated enum ChannelsAPI {
    struct Feed: Sendable {
        var title: String
        var author: String
        var videos: [URL]
    }

    enum Outcome: Sendable {
        case found(Feed)
        /// 元宝没给凭证：多半是没登录或登录过期。附上元宝自己的说法（可能为空）
        case expired(String)
        case failed(String)
    }

    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    static let feedAPI = URL(string: "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info")!
    static let yuanbaoAPI = URL(string: "https://yuanbao.tencent.com/api/weixin/get_parse_result")!

    /// 分享链接 weixin.qq.com/sph/<作品号>，跳转后是 channels.weixin.qq.com/finder-preview/pages/sph?id=<作品号>。
    static func sphId(_ url: String) -> String? {
        guard let r = url.range(of: #"(weixin\.qq\.com/sph/|pages/sph\?id=)[A-Za-z0-9]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(url[r]).components(separatedBy: CharacterSet(charactersIn: "/=")).last
    }

    /// 不登录问作品接口：只有标题、作者。
    static func preview(_ sph: String) async -> Feed? {
        guard let r = await post(feedAPI, ["baseReq": ["generalToken": ""], "shortUri": sph],
                                 headers: ["Origin": "https://channels.weixin.qq.com",
                                           "Referer": "https://channels.weixin.qq.com/finder-preview/pages/sph?id=\(sph)"]) else { return nil }
        let feed = parse(r.json)
        return feed.title.isEmpty && feed.author.isEmpty ? nil : feed
    }

    /// 带元宝的登录状态：先换预览凭证，再拿凭证要视频地址。
    static func video(share: String, cookie: String) async -> Outcome {
        guard let r = await post(yuanbaoAPI, ["type": "video_channel_url", "url": share, "scene": 1],
                                 headers: ["Origin": "https://yuanbao.tencent.com", "Referer": "https://yuanbao.tencent.com/", "Cookie": cookie]) else {
            return .failed(String(localized: "连不上腾讯元宝。看看网络，再试一次。"))
        }
        let says = [r.json["msg"], r.json["message"], r.json["errMsg"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        if r.status == 401 || r.status == 403 { return .expired(says.isEmpty ? "HTTP \(r.status)" : says) }
        let data = r.json["data"] as? [String: Any] ?? [:]
        let items = URLComponents(string: data["playable_url"] as? String ?? "")?.queryItems ?? []
        let token = items.first { $0.name == "token" }?.value ?? ""
        let exportId = items.first { $0.name == "eid" }?.value ?? ""
        guard !token.isEmpty, !exportId.isEmpty else { return .expired(says) }

        guard let f = await post(feedAPI, ["baseReq": ["generalToken": token], "exportId": exportId],
                                 headers: ["Origin": "https://channels.weixin.qq.com",
                                           "Referer": "https://channels.weixin.qq.com/finder-preview/pages/feed"]) else {
            return .failed(String(localized: "连不上视频号。看看网络，再试一次。"))
        }
        let feed = parse(f.json)
        return feed.videos.isEmpty ? .failed(String(localized: "拿到了预览凭证，但视频号没给视频地址。可能这条作品不让在网页上看。")) : .found(feed)
    }

    static func parse(_ json: [String: Any]) -> Feed {
        let data = json["data"] as? [String: Any] ?? [:]
        let info = data["feedInfo"] as? [String: Any] ?? [:]
        let author = (data["authorInfo"] as? [String: Any])?["nickname"] as? String ?? ""
        let title = (info["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // H.264 排前面：哪台机器都解得开
        var raw: [String] = ["h264VideoInfo", "h265VideoInfo"].compactMap { (info[$0] as? [String: Any])?["videoUrl"] as? String }
        if let plain = info["videoUrl"] as? String { raw.append(plain) }
        var seen = Set<String>()
        let videos: [URL] = raw.compactMap { s in
            var u = s.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
            if u.hasPrefix("//") { u = "https:" + u } else if u.hasPrefix("http://") { u = "https://" + u.dropFirst(7) }
            guard !u.isEmpty, seen.insert(u).inserted else { return nil }
            return URL(string: u)
        }
        return Feed(title: title, author: author, videos: videos)
    }

    /// 从豆仓存下的登录状态（cookies.txt）里取元宝那几条，拼成请求头。没扫码登录过就是 nil。
    static func cookieHeader(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var parts: [String] = [], seen = Set<String>()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 7 else { continue }
            let name = String(f[5]), value = String(f[6])
            guard f[0].contains("yuanbao.tencent.com") || name.hasPrefix("hy_"), seen.insert(name).inserted else { continue }
            parts.append("\(name)=\(value)")
        }
        let header = parts.joined(separator: "; ")
        return header.contains("hy_user=") && header.contains("hy_token=") ? header : nil
    }

    static func download(_ url: URL, to dest: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://channels.weixin.qq.com/", forHTTPHeaderField: "Referer")
        for session in sessions {
            guard let (tmp, response) = try? await session.download(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int, size > 20_000 else { continue }
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { return true }
        }
        return false
    }

    /// 先直连，不通再按系统代理（见 sessions）。
    static func post(_ url: URL, _ body: [String: Any], headers: [String: String]) async -> (status: Int, json: [String: Any])? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        for session in sessions {
            guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { continue }
            return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        return nil
    }

    /// 不走代理的连接。要给空表才是真直连：写 HTTPEnable = 0 之类，实测还是进了系统代理
    static let direct: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// 都是腾讯国内的站：先直连，不通再按系统代理。实测开着代理软件时，channels.weixin.qq.com 走代理会在握手时被断开
    static let sessions = [direct, URLSession.shared]
}
