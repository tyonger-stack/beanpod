import AVFoundation
import AppKit
import BeanKit
import Foundation
import SwiftUI

/// 视频素材的画面：从链接导入视频时，按设置决定要不要把画面留下来（默认 5 分钟以内的留）。
///
/// 画面单独存成 `<录音编号>.video.mp4`，放在录音文件夹里，最高 720p（短边不超过 720）。
/// 转写和整理照旧只用声音；播放时声音是主时钟，画面静音跟着走。
/// 删掉画面不影响声音、文字稿和纪要。
extension BeanStore {
    func videoURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).video.mp4") }
    func hasVideo(_ id: UInt32) -> Bool { FileManager.default.fileExists(atPath: videoURL(id).path) }
    /// 列表里用的小封面（画面第 1 秒，宽 160）。
    func videoThumbURL(_ id: UInt32) -> URL { folder.appendingPathComponent("\(id).video.jpg") }

    func makeVideoThumb(_ id: UInt32) async {
        guard hasVideo(id), let ffmpeg = await Self.findTool("ffmpeg") else { return }
        let r = await Self.runTool(ffmpeg, ["-v", "error", "-y", "-ss", "1", "-i", videoURL(id).path, "-frames:v", "1", "-vf", "scale=160:-2", videoThumbURL(id).path]) { _ in }
        if r.status != 0 {   // 不到 1 秒的片子：取第一帧
            _ = await Self.runTool(ffmpeg, ["-v", "error", "-y", "-i", videoURL(id).path, "-frames:v", "1", "-vf", "scale=160:-2", videoThumbURL(id).path]) { _ in }
        }
        videoRevision += 1
    }

    /// 所有画面加起来占多少空间、几条。
    func videoUsage() -> (bytes: Int64, count: Int) {
        recordings.reduce((Int64(0), 0)) { sum, r in
            let size = ((try? FileManager.default.attributesOfItem(atPath: videoURL(r.id).path))?[.size] as? NSNumber)?.int64Value ?? 0
            return size > 0 ? (sum.0 + size, sum.1 + 1) : sum
        }
    }

    /// 按设置（和导入时的勾选）决定这条要不要留画面。
    func wantsVideo(duration: TimeInterval?, override: Bool?) -> Bool {
        if let override { return override }
        switch settings.keepVideo {
        case .never: return false
        case .always: return true
        case .short: return (duration ?? 0) <= AppSettings.shortVideoSeconds
        }
    }

    /// 导入前能不能先要带画面的版本（时长还不知道时：设置不是「都不保留」，或者用户勾了）。
    func mightKeepVideo(_ job: LinkJob?) -> Bool {
        if let o = job?.keepVideo { return o }
        return settings.keepVideo != .never
    }

    /// 导入时手上已经有一份视频文件（抖音、视频号、social-dl 那几路）：按规则决定留不留。
    /// 下载用的临时文件夹在调用方返回后就删了，所以先挪到录音文件夹里，再慢慢压缩。
    func adoptVideo(_ media: URL, for id: UInt32, override: Bool?) {
        guard let r = recordings.first(where: { $0.id == id }), wantsVideo(duration: r.duration, override: override) else { return }
        let staging = folder.appendingPathComponent("\(id).video.incoming")
        try? FileManager.default.removeItem(at: staging)
        guard (try? FileManager.default.moveItem(at: media, to: staging)) != nil
                || (try? FileManager.default.copyItem(at: media, to: staging)) != nil else { return }
        Task {
            await keepVideo(from: staging, for: id)
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// 把一份视频存成这条录音的画面：本来就是 720p 以内的 H.264 直接拷，不然用硬件编码压到 720p。没有画面的文件不留。
    func keepVideo(from media: URL, for id: UInt32) async {
        guard let ffmpeg = await Self.findTool("ffmpeg") else { addLog("留画面：没有 ffmpeg，跳过"); return }
        let ffprobe = await Self.findTool("ffprobe")
        var width = 0, height = 0, codec = ""
        if let ffprobe {
            let r = await Self.runTool(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,codec_name",
                                                 "-of", "csv=p=0", media.path]) { _ in }
            let parts = r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
            if parts.count >= 3 { codec = parts[0]; width = Int(parts[1]) ?? 0; height = Int(parts[2]) ?? 0 }
            guard !codec.isEmpty else { addLog("留画面：\(id) 这份文件里没有画面"); return }
        }
        // 只下了画面、没有声音（B 站这类声音单独一路、常被 CDN 拒）：配上本地已有的那份声音，它本来就是从同一条视频来的
        var hasAudio = true
        if let ffprobe {
            let a = await Self.runTool(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", media.path]) { _ in }
            hasAudio = !a.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let localAudio = !hasAudio && FileManager.default.fileExists(atPath: wavURL(id).path)
        videoWorking.insert(id)
        defer { videoWorking.remove(id) }
        let out = folder.appendingPathComponent("\(id).video.tmp.mp4")
        try? FileManager.default.removeItem(at: out)
        let small = width > 0 && min(width, height) <= 720
        var args = ["-v", "error", "-y", "-i", media.path]
        if localAudio { args += ["-i", wavURL(id).path, "-map", "0:v:0", "-map", "1:a:0", "-shortest"] }
        else { args += ["-map", "0:v:0", "-map", "0:a:0?"] }
        if small && codec == "h264" {
            args += ["-c:v", "copy"] + (localAudio ? ["-c:a", "aac", "-b:a", "128k"] : ["-c:a", "copy"])
        } else {
            // 短边压到 720（竖屏就是宽 720），Mac 的硬件编码很快
            let scale = "scale='if(gt(iw,ih),-2,min(720,iw))':'if(gt(iw,ih),min(720,ih),-2)'"
            args += ["-vf", scale, "-c:v", "h264_videotoolbox", "-b:v", "1800k", "-c:a", "aac", "-b:a", "128k"]
        }
        args += ["-movflags", "+faststart", out.path]
        let r = await Self.runTool(ffmpeg, args) { _ in }
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            addLog("留画面失败（\(id)）：\(r.errors.suffix(200))")
            try? FileManager.default.removeItem(at: out)
            return
        }
        try? FileManager.default.removeItem(at: videoURL(id))
        try? FileManager.default.moveItem(at: out, to: videoURL(id))
        await makeVideoThumb(id)
        let size = ((try? FileManager.default.attributesOfItem(atPath: videoURL(id).path))?[.size] as? NSNumber)?.int64Value ?? 0
        addLog("留画面：\(id) \(small && codec == "h264" ? "原样" : "压到 720p")，\(size / 1_000_000) MB")
    }

    /// 只有声音的素材，事后要画面：重新去原链接下一份最高 720p 的视频。
    func fetchVideo(_ id: UInt32) {
        guard let r = recordings.first(where: { $0.id == id }), let page = r.source, !videoWorking.contains(id) else { return }
        let platform = LinkTools.platform(of: page)
        videoWorking.insert(id)
        Task {
            defer { videoWorking.remove(id) }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-video-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var media: URL?
            if SocialDL.platforms.contains(platform), let python = await SocialDL.prepare().python {
                let cookie = Self.cookieHeader(platform)
                var env = ["BEANPOD_WANT_VIDEO": "1"]
                if !cookie.isEmpty { env["BEANPOD_COOKIE"] = cookie }
                let run = await Self.runTool(python, ["-B", SocialDL.home.appendingPathComponent("beanpod_social.py").path, page, work.path], env: env) { _ in }
                let result = run.output.split(separator: "\n").reversed().lazy.compactMap { SocialDL.event(String($0)) }.first { $0["type"] as? String == "result" }
                media = (result?["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
                    .first { ["mp4", "mov", "m4v", "webm", "mkv", "flv"].contains($0.pathExtension.lowercased()) }
            }
            if media == nil, let tool = await Self.findTool("yt-dlp") {
                let cookies = Self.cookieFile(platform)
                let login = FileManager.default.fileExists(atPath: cookies.path) ? ["--cookies", cookies.path] : []
                let route = Self.domesticPlatforms.contains(platform) ? ["--proxy", ""] : []
                let args = ["--no-playlist", "--no-warnings",
                            // 只要画面：声音本地已经有了（keepVideo 会配上）。B 站的声音流常被 CDN 回 567，少下一路也快
                            "-f", "bv*[height<=720][vcodec^=avc1]/bv*[height<=720]/b[height<=720]/b",
                            "-o", work.appendingPathComponent("video.%(ext)s").path, page]
                // B 站连着要几次会被 CDN 回 567（限流），隔几秒再要通常就好；另外换条网络路线也试一次
                var run = await Self.runTool(tool, login + route + args) { _ in }
                for attempt in 1...2 where run.status != 0 {
                    try? await Task.sleep(for: .seconds(attempt * 4))
                    run = await Self.runTool(tool, login + (attempt == 1 ? route : []) + args) { _ in }
                }
                media = ((try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
                    .first { ["mp4", "mkv", "webm", "mov"].contains($0.pathExtension.lowercased()) }
                if media == nil { addLog("下载画面失败（\(id)）：\(run.errors.suffix(200))") }
            }
            guard let media else {
                problem = Problem(title: String(localized: "画面没下下来"), detail: String(localized: "可能是这个平台不让下载，或者网络不通。声音和文字稿不受影响；也可以点「打开原链接」去平台上看。"))
                return
            }
            videoWorking.remove(id)     // keepVideo 自己会再标一次
            await keepVideo(from: media, for: id)
        }
    }

    /// 把画面另存到「下载」文件夹（用素材标题当文件名，重名就加编号），然后在访达里选中它。
    func saveVideoToDownloads(_ id: UInt32) {
        guard hasVideo(id), let r = recordings.first(where: { $0.id == id }) else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = String(r.displayTitle.prefix(60).map { "/:\\?%*|\"<>\n".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "密盒助手视频-\(id)" : safe
        var target = downloads.appendingPathComponent(base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(base) (\(n)).mp4"); n += 1
        }
        do {
            try FileManager.default.copyItem(at: videoURL(id), to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
            toast("checkmark.circle.fill", String(localized: "已存到「下载」：\(target.lastPathComponent)"))
            addLog("画面另存到 \(target.path)")
        } catch {
            problem = Problem(title: String(localized: "视频没存下来"), detail: error.localizedDescription)
        }
    }

    /// 删掉一条的画面（声音、文字稿、纪要都留着）。
    func removeVideo(_ id: UInt32) {
        if playingID == id { stop() }
        try? FileManager.default.removeItem(at: videoURL(id))
        try? FileManager.default.removeItem(at: videoThumbURL(id))
        videoRevision += 1
        addLog("删掉了 \(id) 的画面")
    }

    /// 清理所有画面。
    func removeAllVideos() {
        let ids = recordings.map(\.id).filter(hasVideo)
        ids.forEach { try? FileManager.default.removeItem(at: videoURL($0)); try? FileManager.default.removeItem(at: videoThumbURL($0)) }
        videoRevision += 1
        addLog("清理了 \(ids.count) 条素材的画面")
    }
}

// MARK: - 界面

/// 视频画面：静音，跟着豆仓的播放器走（声音是主时钟）。点画面 = 播放/暂停。
struct VideoSurface: NSViewRepresentable {
    let url: URL
    let id: UInt32
    var playing: Bool          // 这一条正在放
    var time: TimeInterval     // 播放到哪了
    var rate: Float

    final class Coordinator { var player: AVPlayer?; var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        if c.url != url {
            let p = AVPlayer(url: url)
            p.isMuted = true
            p.actionAtItemEnd = .pause
            c.player = p; c.url = url
            (v.layer as? AVPlayerLayer)?.player = p
        }
        guard let p = c.player else { return }
        let now = p.currentTime().seconds
        // 和声音差出 0.25 秒以上才对一下，免得一直跳
        if !now.isFinite || abs(now - time) > 0.25 {
            p.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playing {
            if p.rate != rate { p.rate = rate }
        } else if p.rate != 0 {
            p.pause()
        }
    }
}

/// 素材详情顶上那张卡片：画面 + 来源 + 打开原链接 / 删掉画面（设计稿 design/ui/ui_video_detail.png）。
struct MaterialVideoCard: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var size: CGSize?
    @State private var confirmRemove = false

    private var isPlaying: Bool { store.playingID == recording.id && store.isPlaying }

    var body: some View {
        let _ = store.videoRevision
        let has = store.hasVideo(recording.id)
        let vertical = (size.map { $0.height > $0.width }) ?? true
        // 详情够宽：画面在左、说明和按钮在右；窗口窄放不下时，说明和按钮挪到画面下面
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                screen(has, vertical: vertical)
                info(has).padding(.top, 6)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 14) {
                screen(has, vertical: vertical)
                info(has)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .panel()
        .task(id: "\(recording.id)-\(store.videoRevision)") { size = await Self.naturalSize(store.videoURL(recording.id)) }
        .confirmationDialog("删掉这条素材的画面？", isPresented: $confirmRemove) {
            Button("删掉画面", role: .destructive) { store.removeVideo(recording.id) }
        } message: {
            Text("只删画面，声音、文字稿和纪要都留着。以后可以在「⋯」菜单里重新下载画面（要原链接还能打开）。")
        }
    }

    private func screen(_ has: Bool, vertical: Bool) -> some View {
        ZStack {
            if has {
                VideoSurface(url: store.videoURL(recording.id), id: recording.id, playing: isPlaying,
                             time: store.playingID == recording.id ? store.playhead : 0, rate: store.playRate)
                if !isPlaying {
                    Image(systemName: "play.fill").font(.system(size: 22)).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(.black.opacity(0.35), in: .circle)
                        .allowsHitTesting(false)
                }
            } else {
                Color.black.opacity(0.06)
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在保存画面…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: vertical ? 200 : 360, height: vertical ? 356 : 203)
        .clipShape(.rect(cornerRadius: Theme.Radius.card))
        .overlay {
            // 点画面 = 播放/暂停（用按钮而不是点按手势，读屏和键盘也能按）
            Button { store.togglePlay(recording.id) } label: { Color.clear.contentShape(.rect) }
                .buttonStyle(.plain).disabled(!has)
                .accessibilityLabel(isPlaying ? "暂停视频" : "播放视频")
        }
    }

    private func info(_ has: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.origin ?? String(localized: "视频素材")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.warm900)
            Text(detail(has)).font(.callout).foregroundStyle(Theme.warm500).monospacedDigit()
            // 按钮文字不截断：一行放得下就横排，放不下就竖排
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons(has) }
                VStack(alignment: .leading, spacing: 8) { actionButtons(has) }
            }
            Text("删掉画面后声音和文字稿都还在。").font(.caption).foregroundStyle(Theme.warm400)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func actionButtons(_ has: Bool) -> some View {
        Group {
            if let s = recording.source, let url = URL(string: s) {
                Button { NSWorkspace.shared.open(url) } label: { Label("打开原链接", systemImage: "arrow.up.right.square") }
            }
            if has {
                Button { store.saveVideoToDownloads(recording.id) } label: { Label("保存到本地", systemImage: "square.and.arrow.down") }
                    .help("存一份到「下载」文件夹，并在访达里打开")
                Button { confirmRemove = true } label: { Label("删掉画面", systemImage: "trash") }
            }
        }
        .buttonStyle(.glass).controlSize(.large).fixedSize()
    }

    private func detail(_ has: Bool) -> String {
        guard has else { return String(localized: "画面保存中") }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: store.videoURL(recording.id).path))?[.size] as? NSNumber)?.int64Value ?? 0
        let short = size.map { Int(min($0.width, $0.height)) } ?? 0
        let mb = Double(bytes) / 1_000_000
        let shown = short > 0 ? "\(short)p" : String(localized: "已保存")
        let amount = mb < 10 ? String(format: "%.1f", mb) : String(Int(mb))
        return String(localized: "画面 \(shown) · \(amount) MB")
    }

    static func naturalSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }
}

/// 设置 → 通用 里的「视频素材」（设计稿 design/ui/ui_video_settings.png）。
struct VideoKeepSettings: View {
    @Environment(BeanStore.self) private var store
    @State private var confirmClean = false

    var body: some View {
        @Bindable var settings = store.settings
        let _ = store.videoRevision
        let usage = store.videoUsage()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("保留画面")
                Spacer()
                Picker("保留画面", selection: $settings.keepVideo) {
                    ForEach(AppSettings.KeepVideo.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text(hint(settings.keepVideo)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("画面占用")
                Spacer()
                Text(usage.count == 0 ? "还没有" : "\(Self.mb(usage.bytes)) · \(usage.count) 条素材").foregroundStyle(.secondary).monospacedDigit()
                Button("清理画面…") { confirmClean = true }.disabled(usage.count == 0)
            }
            Text("清理只删画面，声音、文字稿和纪要都留着。想看画面时也可以打开原链接。").font(.callout).foregroundStyle(.secondary)
        }
        .confirmationDialog("清理所有素材的画面？", isPresented: $confirmClean) {
            Button("清理 \(usage.count) 条的画面（\(Self.mb(usage.bytes))）", role: .destructive) { store.removeAllVideos() }
        } message: {
            Text("只删画面，声音、文字稿和纪要都留着。之后想看，可以在素材的「⋯」菜单里重新下载画面。")
        }
    }

    private func hint(_ k: AppSettings.KeepVideo) -> String {
        switch k {
        case .short: String(localized: "从链接导入视频时，5 分钟以内的保留 720p 画面，更长的只留声音。导入时也可以单独勾选。")
        case .always: String(localized: "从链接导入的视频都保留画面，最高 720p。长视频很占空间，留意下面的占用。")
        case .never: String(localized: "只留声音，用来转成文字。导入时也可以单独勾选保留画面。")
        }
    }

    static func mb(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000) : "\(bytes / 1_000_000) MB"
    }
}
