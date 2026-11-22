import AppKit
import BeanKit
import SwiftUI

/// 刘海快捷面板（设计稿 design/ui/ui_notch.png）。
///
/// 一块贴着 MacBook 刘海的黑色小窗：
/// - 平时和刘海一样大、一样黑，看不出来；录音时刘海两边伸出两只「耳朵」：左边红点和计时，右边声波。
/// - 鼠标移上去就往下展开：设备状态、一键开始录音、用这台 Mac 录、剪贴板里认出来的视频链接一键导入、下载进度。
///   移开就收起；点一下会固定展开，再点别处收起。
/// - 没有刘海的屏幕（外接显示器、老机型）在菜单栏正中放一个同样样式的小胶囊。
/// 不抢焦点：点面板上的按钮不会把豆仓切到前台。
@MainActor @Observable
final class NotchPanel {
    var expanded = false
    var pinned = false
    /// 展开时从剪贴板认出来的那条视频链接
    var clip: Clip?
    var hasNotch = false
    var notchSize = CGSize(width: 0, height: 24)
    /// 菜单「录音」里可以关掉
    var visible = UserDefaults.standard.object(forKey: "notchPanel") as? Bool ?? true
    /// 录音开始和结束时短暂显示的状态。
    var show: Show?

    struct Clip: Equatable {
        var url: String
        var platform: String
        var title: String
        var author: String
    }

    @ObservationIgnored private var window: NotchWindow?
    @ObservationIgnored private weak var store: BeanStore?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var lastSize: CGSize = .zero
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var showEnd: Task<Void, Never>?
    @ObservationIgnored private var recordingSince: Date?
    @ObservationIgnored private var elapsedBase: TimeInterval = 0
    /// 状态提示直接调整窗口大小，照片不做缩放动画。
    @ObservationIgnored private var instantResize = false

    func attach(_ store: BeanStore) {
        guard window == nil else { return }
        self.store = store
        let w = NotchWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // 盖在菜单栏上面
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isMovable = false
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        let host = NotchHostingView(rootView: AnyView(NotchView(panel: self).environment(store)))
        host.sizingOptions = []          // 窗口多大由这里定，别让 SwiftUI 反过来撑窗口
        host.onHover = { [weak self] inside in self?.hover(inside) }
        w.contentView = host
        window = w
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // 固定展开时，点别的地方就收起
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pinned else { return }
                self.pinned = false
                self.expanded = false
            }
        }
        // 点在豆仓自己的窗口里（不是这块面板）也算点了别处
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.pinned, event.window !== self.window {
                    self.pinned = false
                    self.expanded = false
                }
            }
            return event
        }
        place()
        if visible { w.orderFrontRegardless() }
    }

    func setVisible(_ on: Bool) {
        visible = on
        UserDefaults.standard.set(on, forKey: "notchPanel")
        if on { window?.orderFrontRegardless() } else { expanded = false; pinned = false; window?.orderOut(nil) }
    }

    /// 找带刘海的那块屏幕，量出刘海的宽高；没有刘海就用主屏、菜单栏的高度。
    func place() {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        screen = notched ?? NSScreen.main ?? NSScreen.screens.first
        if let s = notched, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: s.frame.width - left.width - right.width, height: s.safeAreaInsets.top)
        } else {
            hasNotch = false
            notchSize = CGSize(width: 0, height: NSStatusBar.system.thickness)
        }
        if lastSize != .zero { resize(lastSize, animated: false) }
    }

    /// 窗口顶边贴着屏幕顶边、水平居中。
    func resize(_ size: CGSize, animated: Bool = true) {
        lastSize = size
        let animated = animated && !instantResize
        instantResize = false
        guard let window, let screen else { return }
        let f = screen.frame
        let frame = NSRect(x: (f.midX - size.width / 2).rounded(), y: f.maxY - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            guard show == nil else { return }
            if !expanded { refreshClip(); expanded = true }
        } else if !pinned {
            // 稍等一下再收：鼠标从刘海滑进面板的那一瞬间会先出后进
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard let self, !Task.isCancelled, !self.pinned else { return }
                self.expanded = false
            }
        }
    }

    func pin() {
        if !expanded { refreshClip(); expanded = true }
        pinned = true
    }

    /// 只在展开的时候看一眼剪贴板（是用户自己把鼠标移上来的），平时不读。
    func refreshClip() {
        guard let store, store.settings.watchClipboard,
              let text = NSPasteboard.general.string(forType: .string), text.count < 2000,
              let url = LinkTools.urls(in: text).first(where: { LinkTools.platform(of: $0) != "网页视频" }),
              !dismissed.contains(url),
              store.importedRecording(for: url) == nil,
              !store.linkJobs.contains(where: { $0.url == url }) else { clip = nil; return }
        // 分享口令里常带着【标题 - 作者 | 平台…】
        var title = "", author = ""
        if let open = text.firstIndex(of: "【"), let close = text[open...].firstIndex(of: "】") {
            let inner = text[text.index(after: open)..<close].split(separator: "|").first.map(String.init) ?? ""
            let parts = inner.components(separatedBy: " - ")
            title = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if parts.count > 1 { author = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        clip = Clip(url: url, platform: LinkTools.platform(of: url), title: title, author: author)
    }

    func recStateChanged(from old: BeanStore.RecState, to new: BeanStore.RecState) {
        if new == .idle {
            let elapsed = elapsedBase + (recordingSince.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0)
            recordingSince = nil
            elapsedBase = 0
            if old != .idle { play(.recordingEnded(elapsed: elapsed, preview: false)) }
        } else {
            recordingSince = store?.recordingSince
            elapsedBase = store?.elapsedBase ?? 0
            if old == .idle { play(.recordingStarted(preview: false)) }
        }
    }

    func preview(started: Bool) {
        play(started ? .recordingStarted(preview: true) : .recordingEnded(elapsed: 48, preview: true))
    }

    private func play(_ state: Show) {
        guard visible else { return }
        collapseTask?.cancel()
        expanded = false
        pinned = false
        instantResize = true
        show = state
        showEnd?.cancel()
        showEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(state.duration))
            guard let self, !Task.isCancelled, self.show == state else { return }
            self.instantResize = true
            self.show = nil
        }
    }

    func importClip() {
        guard let clip, let store else { return }
        store.importLinks(clip.url)
        dismissed.insert(clip.url)
        self.clip = nil
    }
}

/// 不能成为主窗口、不抢焦点的面板。
final class NotchWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 豆仓不在前台时也要能感知鼠标进出、第一下点击就生效。
final class NotchHostingView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

// MARK: - 面板内容

struct NotchView: View {
    @Environment(BeanStore.self) private var store
    let panel: NotchPanel

    private let rose = Theme.rec
    private var job: LinkJob? { store.linkJobs.first }

    /// 各个样子要多大的窗口
    private var target: CGSize {
        let n = panel.notchSize
        if panel.show != nil {
            return CGSize(width: max(320, n.width + 184), height: n.height + 102)
        }
        if panel.expanded {
            var h = n.height + 92
            if panel.clip != nil { h += 66 }
            if job != nil { h += 40 }
            return CGSize(width: max(360, n.width + 170), height: h)
        }
        if store.recState != .idle { return CGSize(width: n.width + 2 * 92, height: n.height) }
        return panel.hasNotch ? n : CGSize(width: 96, height: n.height)
    }

    var body: some View {
        let size = target
        Group {
            if let show = panel.show {
                NotchShowView(show: show, notch: panel.notchSize, size: size)
            } else {
                panelBody(size)
            }
        }
        .onChange(of: size, initial: true) { _, s in panel.resize(s) }
        .onChange(of: store.recState) { old, new in panel.recStateChanged(from: old, to: new) }
    }

    private func panelBody(_ size: CGSize) -> some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: panel.expanded ? 24 : 10, bottomTrailingRadius: panel.expanded ? 24 : 10)
                .fill(.black)
                .contentShape(Rectangle())
                .onTapGesture { panel.pin() }
            if panel.expanded {
                expandedContent.frame(width: size.width).transition(.opacity)
            } else if store.recState != .idle {
                ears.frame(width: size.width, height: size.height)
            } else if !panel.hasNotch {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: panel.expanded)
    }

    // MARK: 展开

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: max(0, panel.notchSize.height - 10))     // 让开刘海和摄像头
            header
            controls
            if let clip = panel.clip { clipCard(clip) }
            if let job { progress(job) }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DevicePhotoView().frame(width: 30, height: 30).accessibilityHidden(true)
            if store.xiaomiRecording {
                Text(store.sourceName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            } else if store.link == .ready {
                Text(store.displayDeviceName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Circle().fill(Theme.ok).frame(width: 6, height: 6).padding(.leading, 2)
                Text(store.info.map { String(localized: "已连接 · 电量 \($0.micBattery)%") } ?? String(localized: "已连接"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            } else {
                Text(store.recordingOnMac ? "正在用这台 Mac 录" : "密盒没连上 · 可以用这台 Mac 录")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
    }

    /// 一行两个一样高的按钮：主操作玫瑰红，次要操作灰。录音中左边换成计时。
    @ViewBuilder
    private var controls: some View {
        switch store.recState {
        case .idle:
            HStack(spacing: 8) {
                if store.link == .ready {
                    pill(String(localized: "用密盒录"), primary: true) { Circle().fill(.white).frame(width: 7, height: 7) } action: { store.startRecording() }
                }
                pill(String(localized: "用 Mac 录"), primary: store.link != .ready) {
                    Image(systemName: "laptopcomputer").font(.system(size: 10, weight: .semibold))
                } action: { store.startMacRecording(withSystem ? .both : .mic) }
                // 用 Mac 录时要不要连电脑里的声音一起录（线上会议、视频）；勾选记住
                Button { store.macSource = withSystem ? .mic : .both } label: {
                    HStack(spacing: 5) {
                        Image(systemName: withSystem ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13)).foregroundStyle(withSystem ? rose : .white.opacity(0.45))
                        Text("含电脑声音").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("勾上：麦克风和电脑里播放的声音一起录，适合线上会议、语音通话")
                Spacer(minLength: 0)
            }
        case .recording, .paused:
            let paused = store.recState == .paused
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(paused ? .white.opacity(0.4) : rose).frame(width: 7, height: 7)
                    timer.font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(paused ? 0.6 : 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !store.xiaomiRecording {
                    pill(paused ? String(localized: "继续") : String(localized: "暂停"), primary: false) {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 9, weight: .bold))
                    } action: { paused ? store.resumeRecording() : store.pauseRecording() }
                }
                pill(String(localized: "结束"), primary: true) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 7, height: 7)
                } action: { store.finishRecording() }
            }
        }
    }

    /// 用 Mac 录时连电脑声音一起录（只录电脑声音的也算勾上）
    private var withSystem: Bool { store.macSource != .mic }

    private func pill<Icon: View>(_ title: String, primary: Bool, width: CGFloat? = nil,
                                  @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(width: width, height: 30)
            .background(primary ? AnyShapeStyle(rose) : AnyShapeStyle(.white.opacity(0.12)), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(NotchPress())
    }

    private func clipCard(_ clip: NotchPanel.Clip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(rose, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("剪贴板里有一条\(clip.platform)链接").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(clip.title.isEmpty
                     ? clip.url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
                     : clip.title + (clip.author.isEmpty ? "" : " · @\(clip.author)"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { panel.importClip() } label: {
                Text("导入").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(rose, in: .capsule)
            }
            .buttonStyle(NotchPress())
        }
        .padding(12)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private func progress(_ job: LinkJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(rose).frame(width: geo.size.width * min(1, max(0.03, job.progress ?? 0.03)))
                }
            }
            .frame(height: 5)
            Text(progressLine(job)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.tail)
        }
        .animation(.easeOut(duration: 0.25), value: job.progress)
    }

    private func progressLine(_ job: LinkJob) -> String {
        let title = (job.title ?? "").isEmpty ? "" : " · " + (job.title ?? "")
        let more = store.linkJobs.count > 1 ? String(localized: "（还有 \(store.linkJobs.count - 1) 条）") : ""
        guard let p = job.progress else { return String(localized: "正在准备 \(job.platform)\(title)\(more)") }
        return String(localized: "正在下载 \(job.platform)\(title) \(Int(p * 100))%\(more)")
    }

    // MARK: 录音中的耳朵

    private var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.recState == .recording ? rose : .white.opacity(0.4)).frame(width: 7, height: 7)
                timer.font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.leading, 14)
            Spacer(minLength: panel.notchSize.width)
            Bars(levels: store.liveLevels, live: store.recState == .recording, color: rose)
                .frame(width: 44, height: 12)
                .padding(.trailing, 14)
        }
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = store.elapsed(at: ctx.date)
            Text(Self.clock(elapsed)).monospacedDigit()
                .accessibilityLabel("已录时长")
                .accessibilityValue(spokenDuration(elapsed))
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 显示实际音量；没有音量数据时保持静止。
private struct Bars: View {
    let levels: [Float]
    let live: Bool
    let color: Color

    var body: some View {
        let recent = Array(levels.suffix(9))
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<9, id: \.self) { index in
                let level = live && recent.indices.contains(index) ? CGFloat(recent[index]) : 0
                Capsule().fill(color).frame(width: 2.5, height: max(2, 12 * min(1, max(0, level * 6))))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 按下时轻轻缩一下：反馈在按下的那一刻就出来。
private struct NotchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
