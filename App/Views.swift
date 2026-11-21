import BeanKit
import SwiftUI

// MARK: - 导航

enum Route: Hashable {
    case dashboard, all, starred, scene(Scene), knowledge, device
    /// 从链接导入的素材。
    case materials
    /// 一个项目里的录音和素材。
    case project(UUID)
    /// 带某个标签的录音和素材。
    case tag(String)
    /// 最近删除（TrashView.swift）。
    case trash
    /// 语音输入记下的话（DictationView.swift）。
    case dictation

    /// 是不是录音列表那一类页面（全部、素材、项目、场景）。
    var isList: Bool {
        switch self {
        case .all, .starred, .scene, .materials, .project, .tag: true
        default: false
        }
    }
}

@Observable
final class Navigator {
    var route: Route = .dashboard
    var selection: UInt32?
    /// 录音舞台是不是铺开着。录音一开始就铺开，可以收起来接着用豆仓。
    var stageOpen = false
    /// 上手引导是不是开着。
    var welcomeOpen = false
    /// 正在问「真的要删吗」。放在这里，工具栏按钮和菜单栏命令都能触发同一个确认框。
    var confirmDeviceDelete = false
    var confirmWiFiSync = false
    /// 「从链接导入」的窗口开没开。
    var linkSheet = false
    /// 正在给哪条录音改名（弹窗挂在录音页上）。
    var renaming: UInt32?
    var confirmLocalDelete = false
    /// 新建项目的弹窗；建好之后要放进去的录音。
    var newProject = false
    var pendingMove: Set<UInt32> = []
    var renamingProject: UUID?
    var deletingProject: UUID?

    func open(_ id: UInt32) { route = .all; selection = id }
}

struct RootView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(ClipboardWatch.self) private var clipboard
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch nav.route {
            case .dashboard: DashboardView().background(Backdrop())
            case .knowledge: KnowledgeView().background(Backdrop())
            case .device: DeviceView().background(Backdrop())
            case .trash: TrashView().background(Backdrop())
            case .dictation: DictationView().background(Backdrop())
            case .all, .starred, .scene, .materials, .project, .tag: RecordingsView().background(Backdrop())
            }
        }
        .accessibilityHidden(nav.stageOpen && store.recState != .idle)
        .preferredColorScheme(store.settings.appearance.scheme)
        .onChange(of: store.recState != .idle) { _, recording in nav.stageOpen = recording }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { store.importFile($0, consume: false) }
            if !urls.isEmpty { nav.route = .all }
            return !urls.isEmpty
        }
        .overlay(alignment: .bottom) { if !nav.stageOpen { RecordDock().padding(.bottom, 16) } }
        .overlay {
            if nav.stageOpen, store.recState != .idle {
                RecordStage().transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 1), value: nav.stageOpen)
        // 舞台铺开时，窗口顶上那排工具按钮也收起来，不然会浮在舞台上面
        .toolbar(nav.stageOpen && store.recState != .idle ? .hidden : .automatic, for: .windowToolbar)
        .overlay(alignment: .top) {
            if let banner = store.banner {
                HStack(spacing: 12) {
                    Label(banner.text, systemImage: banner.icon)
                    if !banner.undo.isEmpty {
                        Divider().frame(height: 14)
                        Button("撤销") { store.restore(banner.undo); store.banner = nil }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).fontWeight(.semibold)
                            .keyboardShortcut("z", modifiers: .command)
                    }
                }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.banner)
        .overlay(alignment: .top) {
            // Wi‑Fi 快传期间一直挂着：这一分钟电脑不在原来的网络上，得让人随时知道进行到哪了
            if let wifi = store.wifi {
                HStack(spacing: 10) {
                    Image(systemName: "wifi").foregroundStyle(Theme.accent).symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(wifi.text).font(.callout.weight(.medium)).monospacedDigit()
                    if wifi.phase == .transferring, let pull = store.pull {
                        ProgressView(value: pull.fraction).frame(width: 90).tint(Theme.accent)
                        Text("\(Int(pull.fraction * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, store.banner == nil ? 10 : 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.wifi?.phase)
        .overlay(alignment: .top) {
            // 正在从链接导入：下载要等一会儿，一直挂着让人知道进行到哪了
            if let job = store.linkJobs.first, store.wifi == nil {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.to.line").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(job.title.map { String(localized: "正在导入「\(String($0.prefix(16)))」") } ?? String(localized: "正在下载\(job.platform)的内容…")).font(.callout.weight(.medium)).lineLimit(1)
                            if let p = job.progress { Text("\(Int(p * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary) }
                            if store.linkJobs.count > 1 { Text("后面还有 \(store.linkJobs.count - 1) 条").font(.caption).foregroundStyle(.tertiary) }
                        }
                        if let p = job.progress { ProgressView(value: p).tint(Theme.accent) } else { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
                    }
                    .frame(width: 260, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
                .padding(.top, store.banner == nil ? 10 : 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.linkJobs.first?.id)
        .overlay(alignment: .top) {
            if !(nav.stageOpen && store.recState != .idle) {
                ClipboardOffer().padding(.top, store.banner == nil && store.linkJobs.isEmpty ? 10 : 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: clipboard.offer?.url)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in clipboard.check(store) }
        .task {
            // 豆仓开在前台时，复制了一条链接再切回来之前也能看到：在前台每两秒看一眼剪贴板有没有变
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if NSApp.isActive { clipboard.check(store) }
            }
        }
        .sheet(isPresented: Bindable(nav).linkSheet) { LinkImportSheet() }
        .sheet(item: Binding(get: { store.linkLogin }, set: { store.linkLogin = $0 })) { request in LinkLoginSheet(request: request) }
        .overlay(alignment: .top) {
            if let just = store.justRecorded, !(nav.stageOpen && store.recState != .idle) {
                KeepCard(just: just)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.justRecorded?.id)
        .alert("用 Wi‑Fi 快传？", isPresented: Bindable(nav).confirmWiFiSync) {
            Button("开始快传") { store.startWiFiSync() }
            Button("还是用蓝牙", role: .cancel) {}
        } message: {
            Text(store.wifiSyncEstimate + "\n\n" + String(localized: "快传时这台 Mac 会离开现在的 Wi‑Fi、连到密盒上，大约一分钟上不了网，传完自动连回来。"))
        }
        .alert(store.problem?.title ?? "", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } }), presenting: store.problem) { p in
            if let action = p.action {
                Button(action.label) {
                    switch action {
                    case .settings: SettingsView.open(.models, with: openSettings)
                    case .device: nav.route = .device
                    default: store.resolve(action)
                    }
                }
                Button("先不管", role: .cancel) {}
            } else {
                Button("好") {}
            }
        } message: { p in
            Text(p.detail)
        }
        .sheet(isPresented: $nav.welcomeOpen) { WelcomeView() }
        .modifier(ProjectDialogs())
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "welcomed"), store.recordings.isEmpty { nav.welcomeOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.open)) { note in
            if let id = note.object as? UInt32 { nav.stageOpen = false; nav.open(id) }
        }
    }
}

/// 窗口最上面的录音控制，哪个页面都能点到。
struct RecordButton: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        RecordControls(size: .regular)
    }
}

/// 录音的三个动作：开始、暂停/继续、结束。没在录时只有一个「录音」；录起来后显示已录时长、暂停键和结束键。
struct RecordControls: View {
    @Environment(BeanStore.self) private var store
    var size: ControlSize

    var body: some View {
        switch store.recState {
        case .idle:
            Button { store.startRecording() } label: {
                Label(size == .regular ? String(localized: "action.record", defaultValue: "录音") : String(localized: "开始录音"), systemImage: "record.circle.fill").labelStyle(.titleAndIcon).fixedSize()
                    .padding(.horizontal, size == .regular ? 0 : 8)
            }
            .buttonStyle(size == .regular ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
            .tint(Theme.rec).controlSize(size)
            .help("开始录音，声音来自：\(store.sourceName)（⌘R）")
        case .recording, .paused:
            let paused = store.recState == .paused
            HStack(spacing: size == .regular ? 6 : 10) {
                HStack(spacing: 6) {
                    Circle().fill(paused ? Theme.accent : Theme.rec).frame(width: 8, height: 8)
                        .opacity(paused ? 1 : 0.9)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(clock(store.elapsed(at: context.date))).monospacedDigit()
                    }
                    if paused { Text("已暂停").foregroundStyle(.secondary).fixedSize() }
                }
                .font(size == .regular ? .callout.weight(.medium) : .title3.weight(.medium))
                .padding(.horizontal, 8)

                Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                        .labelStyle(size == .regular ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .buttonStyle(size == .regular ? AnyButtonStyle(.borderless) : AnyButtonStyle(.glass)).controlSize(size)
                .help(paused ? "继续录（⌘R）" : "暂停，稍后可以接着录进同一条（⌘R）")

                Button { store.finishRecording() } label: {
                    Label("结束", systemImage: "stop.fill")
                        .labelStyle(size == .regular ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .buttonStyle(size == .regular ? AnyButtonStyle(.borderless) : AnyButtonStyle(.glassProminent))
                .tint(Theme.rec).foregroundStyle(size == .regular ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(.white)).controlSize(size)
                    .help("结束这条录音（⌘.）。结束后会自动下载并整理成纪要。")
            }
        }
    }
}

/// 选声音从哪来：录音豆、这台 Mac 的麦克风、电脑里的声音，或者后两样一起。就放在录音按钮旁边。
struct SourceMenu: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        Menu {
            if store.link == .ready {
                Button { store.preferMac = false } label: { Label(store.displayDeviceName + (store.preferMac ? "" : "　✓"), systemImage: "dot.radiowaves.left.and.right") }
                Divider()
            }
            Section("用这台 Mac 录") {
                ForEach(BeanStore.MacSource.allCases) { source in
                    let on = (store.link != .ready || store.preferMac) && store.macSource == source
                    Button { store.macSource = source; store.preferMac = true } label: {
                        Label(source.name + (on ? "　✓" : ""), systemImage: source.icon)
                    }
                    .help(source.hint)
                }
            }
        } label: {
            Label(store.sourceName, systemImage: store.sourceIcon).labelStyle(.titleAndIcon).lineLimit(1)
        }
        .menuStyle(.button).buttonStyle(.glass).controlSize(.extraLarge).fixedSize()
        .help("声音从哪来。点一下可以换")
        .accessibilityLabel("声音来源").accessibilityValue(store.sourceName)
    }
}

/// 让同一个按钮在不同场合用不同的按钮样式。
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) { make = { configuration in AnyView(Button(configuration).buttonStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 让同一个按钮在不同场合用不同的标签样式。
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) {
        make = { configuration in AnyView(Label { configuration.title } icon: { configuration.icon }.labelStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct Sidebar: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    /// 侧栏只有三个去处。录音页里的场景筛选、星标都算「录音」。
    private var section: Int {
        switch nav.route {
        case .dashboard: 0
        case .all, .starred, .scene: 1
        case .knowledge: 2
        case .materials: 3
        case .dictation: 4
        case .device, .project, .tag, .trash: -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌卡：图标、名字、一行小字
            HStack(spacing: 11) {
                DevicePhotoView().frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm300.opacity(0.5), lineWidth: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text("密盒助手").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warm900)
                    Text("语音工作台").font(.system(size: 11)).foregroundStyle(Theme.warm500)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.surface.opacity(0.6), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
            .accessibilityElement(children: .combine)
            .padding(.bottom, 20)

            SidebarRecord().padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 4) {
                        item(String(localized: "总览"), "house.fill", 0) { nav.route = .dashboard }
                        item(String(localized: "录音"), "waveform", 1, count: store.ownRecordings.count) { nav.route = .all }
                        item(String(localized: "素材"), "play.rectangle.fill", 3, count: store.recordings.filter(\.isMaterial).count) { nav.route = .materials }
                        // 语音输入：开着「记下说过的话」或者已经记过才出现
                        if store.settings.dictationSave || !store.dictations.isEmpty {
                            item(String(localized: "语音输入"), "keyboard", 4, count: store.dictations.count) { nav.route = .dictation }
                        }
                        item(String(localized: "知识库"), "book.closed.fill", 2) { nav.route = .knowledge }
                    }
                    projectList.padding(.top, 20)
                    SidebarTags().padding(.top, 16)
                }
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            // 最近删除：里面有东西（或者正开着）才出现
            if !store.trash.isEmpty || nav.route == .trash {
                let on = nav.route == .trash
                Button { nav.route = .trash } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash").font(.system(size: 12)).frame(width: 20)
                            .foregroundStyle(on ? Theme.accent : Theme.warm400)
                        Text("最近删除").font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.accent : Theme.warm700)
                        Spacer()
                        if !store.trash.isEmpty {
                            Text("\(store.trash.count)").font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(on ? Theme.accent : Theme.warm400)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(on ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .accessibilityLabel("最近删除，\(store.trash.count) 条")
            }
            Divider().overlay(Theme.warm200.opacity(0.6)).padding(.horizontal, -16).padding(.bottom, 14)
            HStack(spacing: 6) {
                DeviceChip()
                SettingsChip()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }

    /// 项目：小标题、加号，下面一个个项目。右键可以改名、删掉。
    private var projectList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("项目").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warm500)
                Spacer()
                Button { nav.pendingMove = []; nav.newProject = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warm500)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("新建项目").accessibilityLabel("新建项目")
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
            if store.projects.isEmpty {
                Text("把相关的录音和素材放在一起")
                    .font(.system(size: 11)).foregroundStyle(Theme.warm400).lineLimit(2)
                    .padding(.horizontal, 12)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.projects) { p in
                        let on = nav.route == .project(p.id)
                        Button { nav.route = .project(p.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: on ? "folder.fill" : "folder").font(.system(size: 13)).frame(width: 20)
                                    .foregroundStyle(on ? Theme.accent : Theme.warm500)
                                Text(p.name).font(.system(size: 13, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Theme.warm900 : Theme.warm700).lineLimit(1)
                                Spacer()
                                Text("\(store.count(in: p.id))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.warm400)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(on ? Theme.warm300.opacity(0.4) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名…") { nav.renamingProject = p.id }
                            Button("删除项目…", role: .destructive) { nav.deletingProject = p.id }
                        }
                    }
                }
            }
            // 只占项目实际需要的高度，多了才滚；不然空着也会把侧栏顶上的东西挤出窗口
            .frame(height: min(204, CGFloat(store.projects.count) * 34))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func item(_ title: String, _ icon: String, _ index: Int, count: Int = 0, action: @escaping () -> Void) -> some View {
        let on = section == index
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(on ? Theme.accent : Theme.warm500)
                Text(title).font(.system(size: 14, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.warm900 : Theme.warm700)
                    .lineLimit(1).minimumScaleFactor(0.8)      // 英文词长：放不下就稍微缩一点，不折行
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(on ? Theme.accent : Theme.warm500)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background((on ? Theme.accent : Theme.warm400).opacity(0.12), in: .capsule)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(on ? Theme.warm300.opacity(0.4) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 整个应用里唯一的录音按钮，固定在侧栏顶上：哪一页都在同一个位置、同一个大小、同一个形状。
struct SidebarRecord: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        VStack(spacing: 6) {
            if store.recState == .idle {
                Button { store.startRecording() } label: {
                    HStack(spacing: 8) {
                        PulsingDot()
                        Text("开始录音").font(.system(size: 14, weight: .medium)).tracking(0.5)
                    }
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [Theme.rec, Theme.recDeep], startPoint: .leading, endPoint: .trailing), in: .rect(cornerRadius: Theme.Radius.card))
                    .shadow(color: Theme.rec.opacity(0.25), radius: 10, y: 5)
                    .contentShape(.rect(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(PressScale())
                .help("开始录音，声音来自：\(store.sourceName)（⌘R）")
                SourceLine()
            } else {
                let paused = store.recState == .paused
                // 录音中：同一个位置换成计时，点一下回到录音舞台
                Button { nav.stageOpen = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(paused ? Theme.accent : Theme.rec).frame(width: 8, height: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(store.elapsed(at: context.date))).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        Text(paused ? "已暂停" : "录音中").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Theme.rec.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.rec.opacity(0.35), lineWidth: 1))
                    .contentShape(.rect(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(.plain).help("回到录音舞台（⌘L）")
            }
        }
    }
}

/// 录音按钮下面的一行小字：声音从哪来，点一下可以换。
struct SourceLine: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        Menu {
            if store.link == .ready {
                Button { store.preferMac = false } label: { Label(store.displayDeviceName + (store.preferMac ? "" : "　✓"), systemImage: "dot.radiowaves.left.and.right") }
                Divider()
            }
            Section("用这台 Mac 录") {
                ForEach(BeanStore.MacSource.allCases) { source in
                    let on = (store.link != .ready || store.preferMac) && store.macSource == source
                    Button { store.macSource = source; store.preferMac = true } label: {
                        Label(source.name + (on ? "　✓" : ""), systemImage: source.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.sourceIcon)
                Text(store.sourceName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("声音从哪来。点一下可以换")
        .accessibilityLabel("声音来源").accessibilityValue(store.sourceName)
    }
}

/// 侧栏底部、设备卡右边的设置按钮：和设备卡一样高的方块，点一下打开设置（停在上次看的那一页）。
struct SettingsChip: View {
    @Environment(\.openSettings) private var openSettings
    @State private var hover = false

    var body: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hover ? Theme.warm900 : Theme.warm500)
                .frame(width: 36).frame(maxHeight: .infinity)
                .background(Theme.surface.opacity(hover ? 1 : 0.7), in: .rect(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
                .contentShape(.rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(PressScale())
        .onHover { hover = $0 }
        .help("设置（⌘,）")
        .accessibilityLabel("设置")
    }
}

/// 侧栏底部的设备卡，点一下进设备页。
struct DeviceChip: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    var body: some View {
        let on = nav.route == .device
        Button { nav.route = .device } label: {
            // 侧栏窄：名字要整行放得下（「soundcore Work」原先被右边的箭头挤成「soundcor…」）。
            // 整张卡本身就是按钮、选中时有描边，不再放箭头；只有正在下载时右边放进度圈
            HStack(spacing: 8) {
                Image(systemName: showCard ? "rectangle.fill" : "headphones")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(store.link == .ready || showCard ? Theme.amber : Theme.warm500)
                    .frame(width: 28, height: 28).background((store.link == .ready || showCard ? Theme.amber : Theme.warm400).opacity(0.16), in: .rect(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: 2) {
                    Text(showCard ? store.card.name : store.link == .ready ? store.displayDeviceName : String(localized: "密盒")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm900)
                        .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(status).font(.system(size: 10.5)).foregroundStyle((store.link == .ready || showCard) && store.wifi == nil && store.recState == .idle ? Theme.ok : Theme.warm500).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let pull = store.pull { ProgressView(value: pull.fraction).progressViewStyle(.circular).controlSize(.small) }
                else if showCard, let p = store.card.progress { ProgressView(value: p.fraction).progressViewStyle(.circular).controlSize(.small) }
            }
            .padding(.horizontal, 9).padding(.vertical, 11)
            .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.warm200.opacity(0.6), lineWidth: on ? 1.5 : 1))
            .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showCard ? "\(store.card.name)：卡里的录音和连接" : "\(store.link == .ready ? store.displayDeviceName : String(localized: "密盒"))：电量、存储和连接")
    }

    /// 录音豆没连上、得到录音卡连着：这张卡片显示录音卡。
    private var showCard: Bool { store.link != .ready && store.card.link == .ready }

    private var status: String {
        if store.wifi != nil { return String(localized: "Wi‑Fi 快传中") }
        if showCard { return store.card.progress != nil ? String(localized: "正在下载") : String(localized: "已连接") }
        switch store.link {
        case .ready:
            if store.recState == .recording { return String(localized: "录音中") }
            if store.recState == .paused { return String(localized: "录音已暂停") }
            return String(localized: "已连接")
        case .connecting: return String(localized: "正在连接…")
        case .scanning: return String(localized: "正在搜索…")
        case .off: return String(localized: "蓝牙未打开")
        case .unauthorized: return String(localized: "没有蓝牙权限")
        case .idle: return String(localized: "未连接")
        }
    }

    private var statusColor: Color {
        if store.wifi != nil { return Theme.accent }
        if showCard { return Theme.ok }
        if store.link == .ready { return store.info?.recording == true ? Theme.rec : Theme.ok }
        return .secondary.opacity(0.5)
    }
}

// MARK: - 小组件

struct ScenePill: View {
    let scene: Scene
    var body: some View {
        Label(scene.name, systemImage: scene.icon)
            .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 8) {
                    if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent) }
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.warm900)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warm50, in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.02), radius: 2, y: 1)
    }
}

extension View {
    /// 放内容的底板：一块半透明的实底加一圈细线。玻璃只留给浮在内容上面的控件。
    func panel(radius: CGFloat = Theme.Radius.panel) -> some View {
        modifier(Panel(radius: radius))
    }
}

/// 底板的样子跟着深浅色走：深色是比底色亮一级的石墨，上沿一道极细的亮边；浅色是白纸加很轻的影子。
struct Panel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.86), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.warm200.opacity(scheme == .dark ? 0.9 : 0.8), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.03), radius: 3, y: 1)
    }
}

/// 内容区的底：暖灰，平的，不加光晕。深色是暖黑。
/// 不透出桌面：桌面是什么颜色，豆仓就跟着变灰变花，没有自己的样子。
struct Backdrop: View {
    var body: some View {
        Theme.dynamic(light: (0.976, 0.969, 0.961), dark: (0.110, 0.098, 0.090)).ignoresSafeArea()
    }
}

/// 点下去轻轻缩一下。
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// 录音键上那个白点：慢慢一明一暗，告诉人这是录音。
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var dim = false
    var body: some View {
        Circle().fill(.white).frame(width: 10, height: 10)
            .opacity(dim ? 0.45 : 1)
            .onAppear { if !still { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true } } }
    }
}

/// 让窗口透出后面的桌面。
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .underWindowBackground
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct StageBadge: View {
    let stage: BeanStore.Stage
    var body: some View {
        HStack(spacing: 6) {
            switch stage {
            case .queued:
                Image(systemName: "clock"); Text("排队中")
            case .transcribing(let f):
                ProgressView(value: f).progressViewStyle(.circular).controlSize(.small); Text("转写 \(Int(f * 100))%")
            case .analyzing:
                ProgressView().controlSize(.small); Text("整理中")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - 录音列表

struct RecordingsView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var quick: Quick = .all
    @State private var renameText = ""
    @FocusState private var searching: Bool
    @FocusState private var listFocused: Bool
    /// 多选：开着的时候点一张卡片是勾选，不是打开。
    @State private var selecting = false
    @State private var picked: Set<UInt32> = []
    @State private var listWidth: CGFloat = 368
    /// 素材库里按平台筛。
    @State private var platform: String?
    /// 按来源筛：录音豆、Mac、导入……（设计稿 design/ui/ui_source.png）
    @State private var source: Recording.Source?
    @State private var linkText = ""

    /// 列表头上的快速筛选。星标以前是侧栏里单独的一页，没有星标时整页是空的，所以收进这里。
    enum Quick: String, CaseIterable, Identifiable {
        case all = "全部", starred = "星标", todos = "有待办", marked = "有重点"
        var id: String { rawValue }
        /// 显示用的名字（rawValue 只当标识用）。
        var name: String {
            switch self {
            case .all: String(localized: "全部")
            case .starred: String(localized: "星标")
            case .todos: String(localized: "有待办")
            case .marked: String(localized: "有重点")
            }
        }
        var emptyHint: String {
            switch self {
            case .all: ""
            case .starred: String(localized: "还没有星标的录音。打开一条录音，点右上角的星，它就会出现在这里。")
            case .todos: String(localized: "没有还没做完的待办。")
            case .marked: String(localized: "还没有打过重点标记的录音。录音时按 ⌘D，或者按密盒上的标记键。")
            }
        }
    }

    /// 按来源筛之前的那一份：来源下拉里只列这里面真有的来源。
    private var sourceBase: [Recording] {
        var base: [Recording]
        switch nav.route {
        case .starred: base = store.ownRecordings.filter(\.starred)
        case .scene(let s): base = store.ownRecordings.filter { $0.scene == s }
        case .materials:
            base = store.recordings.filter(\.isMaterial)
            if let platform { base = base.filter { Self.platform(of: $0) == platform } }
        case .project(let id): base = store.recordings.filter { $0.project == id }
        case .tag(let t): base = store.recordings(tagged: t)
        default: base = store.ownRecordings
        }
        switch quick {
        case .all: break
        case .starred: base = base.filter(\.starred)
        case .todos: base = base.filter { r in r.todos.contains { !$0.done } }
        case .marked: base = base.filter { !$0.marks.isEmpty }
        }
        return base
    }

    private var scoped: [Recording] {
        guard let source, nav.route != .materials else { return sourceBase }
        return sourceBase.filter { $0.recordedOn == source }
    }

    /// 这一页里有哪几种来源。只有一种时不显示来源下拉。
    private var sources: [Recording.Source] {
        let have = Set(sourceBase.map(\.recordedOn))
        return Recording.Source.allCases.filter(have.contains)
    }

    private var narrowed: Bool { quick != .all || source != nil || !query.isEmpty || { if case .scene = nav.route { return true }; return false }() }

    private func showAll() { quick = .all; source = nil; query = ""; nav.route = .all }

    /// 搜索：标题、摘要、文字稿、话题里有这个词就算。
    private var items: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scoped }
        return scoped.filter { r in
            r.displayTitle.lowercased().contains(q) || (r.summary ?? "").lowercased().contains(q)
                || (r.transcript ?? "").lowercased().contains(q) || r.tags.contains { $0.lowercased().contains(q) }
        }
    }

    /// 按天分组：今天、昨天、更早的写日期。
    private var days: [(label: String, items: [Recording])] {
        let cal = Calendar.current
        var out: [(String, [Recording])] = []
        for r in items {
            let label: String
            if let d = r.date {
                if cal.isDateInToday(d) { label = String(localized: "今天") }
                else if cal.isDateInYesterday(d) { label = String(localized: "昨天") }
                else { label = d.formatted(.dateTime.month().day().weekday(.abbreviated)) }
            } else { label = String(localized: "没有日期") }
            if out.last?.0 == label { out[out.count - 1].1.append(r) } else { out.append((label, [r])) }
        }
        return out
    }

    private var title: String {
        switch nav.route {
        case .starred: String(localized: "星标")
        case .scene(let s): s.name
        case .materials: String(localized: "素材库")
        case .project(let id): store.project(id)?.name ?? String(localized: "项目")
        case .tag(let t): "#\(t)"
        default: String(localized: "全部录音")
        }
    }

    /// 素材的平台：来源写成「抖音 · @某某」，取点号前面那段。
    static func platform(of r: Recording) -> String {
        (r.origin ?? "").components(separatedBy: " · ").first ?? ""
    }

    private var platforms: [String] {
        var seen: [String] = []
        for r in store.recordings where r.isMaterial {
            let p = Self.platform(of: r)
            if !p.isEmpty, !seen.contains(p) { seen.append(p) }
        }
        return seen
    }

    private var isProjectPage: Bool { if case .project = nav.route { return true }; return false }

    /// 一个小筛选块：选中的是深色，其他是浅灰。
    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: on ? .medium : .regular))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .foregroundStyle(on ? Theme.warm50 : Theme.warm700)
                .background(on ? Theme.warm900 : Theme.warm200.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 「来源：全部 ⌄」：只列这一页里真有的来源。选了某个来源时整块变成选中色。
    private var sourceMenu: some View {
        Menu {
            Button { source = nil } label: { Text("全部来源") }
            Divider()
            ForEach(sources) { s in
                Button { source = s } label: { Label(s.name, systemImage: s.icon) }
            }
        } label: {
            HStack(spacing: 4) {
                if let source { Image(systemName: source.icon).font(.system(size: 11)) }
                Text(source?.name ?? String(localized: "来源"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: source == nil ? .regular : .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(source == nil ? Theme.warm700 : Theme.warm50)
            .background(source == nil ? Theme.warm200.opacity(0.7) : Theme.warm900, in: .rect(cornerRadius: Theme.Radius.card))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("只看某台设备录的，或者导入的")
        .accessibilityLabel("来源：\(source?.name ?? String(localized: "全部"))")
    }

    /// 素材库顶上的粘贴框：贴进来就导入。
    private var pasteBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm400)
            TextField("粘贴视频链接或分享口令", text: $linkText).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(importPasted)
            Button(action: importPasted) {
                Text("导入").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(LinkTools.urls(in: linkText).isEmpty ? Theme.warm400 : Theme.accent, in: .rect(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain).disabled(LinkTools.urls(in: linkText).isEmpty)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.warm100.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))
    }

    private func importPasted() {
        guard !LinkTools.urls(in: linkText).isEmpty else { return }
        store.importLinks(linkText)
        linkText = ""
    }

    var body: some View {
        @Bindable var nav = nav
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.warm900)
                        Spacer()
                        Text("\(items.count) 条").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warm500).monospacedDigit()
                        Button(selecting ? "完成" : "选择") {
                            selecting.toggle(); picked = []
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.leading, 4)
                        .disabled(items.isEmpty && !selecting)
                        .help("选几条一起移到项目、打星或删除")
                        listMenu
                    }
                    if nav.route == .materials { pasteBar }
                    // 搜索就放在列表头上：在哪找，就在哪输
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.warm400)
                        TextField("搜标题、内容、话题", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.warm400) }
                                .buttonStyle(.plain).help("清空").accessibilityLabel("清空搜索")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.warm100.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(searching ? Theme.accent : Theme.warm200.opacity(0.8), lineWidth: searching ? 1.5 : 1))
                    .focused($searching)
                    // 快速筛选：素材库按平台，其他页按星标、待办、重点
                    // 来源下拉固定在最右边，不跟着前面那排一起滑：列表窄的时候前面的可以滑，它总是完整的
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                if nav.route == .materials {
                                    chip(String(localized: "全部"), on: platform == nil) { platform = nil }
                                    ForEach(platforms, id: \.self) { p in chip(p, on: platform == p) { platform = p } }
                                } else {
                                    ForEach(Quick.allCases) { q in chip(q.name, on: quick == q) { quick = q } }
                                }
                            }
                        }
                        if nav.route != .materials, sources.count > 1 || source != nil { sourceMenu }
                    }
                }
                .padding(16)
                Divider().overlay(Theme.warm200.opacity(0.6))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(days.enumerated()), id: \.element.label) { n, day in
                                HStack {
                                    Text(day.label)
                                    Spacer()
                                    Text("\(day.items.count) 条 • \(spokenDuration(day.items.reduce(0) { $0 + $1.duration }))").monospacedDigit()
                                }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warm500)
                                .padding(.horizontal, 8).padding(.top, n == 0 ? 4 : 12).padding(.bottom, 2)
                                ForEach(day.items) { rec in
                                    RecordingRow(recording: rec, selected: selecting ? picked.contains(rec.id) : nav.selection == rec.id,
                                                 checked: selecting ? picked.contains(rec.id) : nil, showProject: !isProjectPage)
                                        .id(rec.id)
                                        .onTapGesture { tap(rec.id) }
                                        // 读屏和辅助功能点按走同一个动作
                                        .accessibilityAction { tap(rec.id) }
                                        .contextMenu { rowMenu(rec) }
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityAddTraits(nav.selection == rec.id ? .isSelected : [])
                                }
                            }
                        }
                        .padding(12)
                        .padding(.bottom, selecting ? 64 : 0)
                    }
                    // 上下键换一条：列表不是系统的列表了，键盘照样能用
                    .focusable().focused($listFocused).focusEffectDisabled()
                    .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
                    .onKeyPress(.downArrow) { move(1, proxy); return .handled }
                }
                .overlay {
                    // 列表空的时候这里只留一句小字；要说的话放在右边，一个页面只出现一个空状态
                    if items.isEmpty {
                        if store.loadingList { ProgressView("正在读取录音列表…") }
                        else { Text(emptyLine).font(.callout).foregroundStyle(Theme.warm400).multilineTextAlignment(.center).padding(24) }
                    }
                }
                .overlay(alignment: .bottom) { if selecting { batchBar.padding(12) } }
            }
            .frame(width: listWidth)
            .background(Theme.surface.opacity(0.5))

            Divider().overlay(Theme.warm200.opacity(0.7))
            Group {
                if let id = nav.selection, let rec = store.recordings.first(where: { $0.id == id }) {
                    RecordingDetail(recording: rec).id(rec.id)
                } else if !store.recordings.isEmpty {
                    // 有录音，只是这个筛选条件下没有：说清为什么，给一个回去的按钮
                    VStack(spacing: 12) {
                        Image(systemName: emptyIcon).font(.system(size: 34)).foregroundStyle(Theme.warm400)
                        Text(emptyTitle).font(.title3.weight(.semibold)).foregroundStyle(Theme.warm900)
                        Text(emptyDetail).foregroundStyle(Theme.warm500).multilineTextAlignment(.center).frame(maxWidth: 380)
                        if !(nav.route == .materials && query.isEmpty && quick == .all) {
                            Button("看全部录音") { showAll() }.buttonStyle(.glass).controlSize(.large).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 只有一条录音都没有的时候才会到这里：给一个能直接动手的开始
                    VStack(spacing: 14) {
                        DevicePhotoView().frame(width: 130, height: 130).accessibilityHidden(true)
                        Text("录下第一段").font(.title2.bold())
                        Text("点左上角的「开始录音」。录完会自动转成文字，再整理成摘要、待办和重点。").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface.opacity(0.8))
        }
        // 窗口窄的时候列表让一点宽度给右边的详情：详情至少留 480，列表在 300～368 之间
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { total in
            listWidth = min(368, max(300, (total - 480).rounded()))
        }
        .navigationTitle(title)
        .toolbar(removing: .title)
        // 不留空白：没选中任何一条时，自动打开最新的那条
        .onAppear { pickFirstIfNeeded() }
        .onChange(of: nav.renaming) { _, id in
            if let id { renameText = store.recordings.first { $0.id == id }?.title ?? "" }
        }
        .alert("重命名", isPresented: Binding(get: { nav.renaming != nil }, set: { if !$0 { nav.renaming = nil } })) {
            TextField("标题", text: $renameText)
            Button("好") { if let id = nav.renaming { store.rename(id, to: renameText) }; nav.renaming = nil }
            Button("取消", role: .cancel) { nav.renaming = nil }
        } message: {
            Text("留空的话，下次整理时会让 AI 重新起一个。")
        }
        .onChange(of: items.map(\.id)) { pickFirstIfNeeded(); picked.formIntersection(Set(items.map(\.id))) }
        .onChange(of: nav.route) { selecting = false; picked = []; platform = nil }
        .onChange(of: nav.route) { if nav.route == .starred { nav.route = .all; quick = .starred } }
    }

    private var emptyIcon: String {
        if !query.isEmpty { return "magnifyingglass" }
        if quick == .starred { return "star" }
        switch nav.route {
        case .materials: return "play.rectangle"
        case .project: return "folder"
        case .tag: return "number"
        default: return "line.3.horizontal.decrease.circle"
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return String(localized: "没找到「\(query)」") }
        if quick != .all { return String(localized: "「\(quick.name)」里现在是空的") }
        if let source { return String(localized: "没有来源是「\(source.name)」的录音") }
        switch nav.route {
        case .materials: return String(localized: "还没有素材")
        case .project: return String(localized: "「\(title)」里还没有东西")
        case .tag: return String(localized: "没有带「\(title)」的录音了")
        default: return String(localized: "这个场景下还没有录音")
        }
    }

    private var emptyDetail: String {
        if !query.isEmpty { return String(localized: "换个词试试，或者到知识库里直接提问。") }
        if quick != .all { return quick.emptyHint }
        if source != nil { return String(localized: "在「来源」里换回「全部来源」，就能看到其它录音。") }
        switch nav.route {
        case .materials: return String(localized: "把抖音、B 站、YouTube 这些视频链接贴到左边的框里，密盒助手会下载声音、转成文字稿，再整理成纪要。")
        case .project: return String(localized: "在任意一条录音上右键「移到项目」，或者在「全部录音」里点「选择」，一次放好几条进来。")
        case .tag: return String(localized: "在录音详情的标题下面点「＋ 标签」，就能给它加上。")
        default: return String(localized: "整理过的录音会自动归到对应的场景。")
        }
    }

    private var emptyLine: String {
        switch nav.route {
        // 素材库、项目空着时，右边已经有完整的说明，这里不再重复一遍
        case .materials, .project, .tag: ""
        default: store.ownRecordings.isEmpty ? String(localized: "还没有录音") : String(localized: "这个条件下没有录音")
        }
    }

    /// 多选时浮在列表底部的一条：已选几条、移到项目、星标、删除。
    private var batchBar: some View {
        HStack(spacing: 10) {
            Text(picked.isEmpty ? "点卡片来选" : "已选 \(picked.count) 条").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warm700)
            Spacer(minLength: 4)
            Menu {
                ProjectMenuItems(ids: picked)
            } label: {
                Label("移到项目", systemImage: "folder").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            Button { store.setStar(picked, !picked.allSatisfy { id in store.recordings.first { $0.id == id }?.starred == true }) } label: {
                Label("星标", systemImage: "star").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            Button {
                store.trashWithUndo(picked.filter { id in store.recordings.first(where: { $0.id == id })?.downloaded == true })
                picked = []; selecting = false
            } label: {
                Label("删除", systemImage: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(!picked.contains { id in store.recordings.first { $0.id == id }?.downloaded == true })
        }
        .disabled(picked.isEmpty)
        .foregroundStyle(Theme.warm700)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    /// 列表头上的「…」：导入、录音豆、按场景筛选。不常用，收在一起。
    private var listMenu: some View {
        Menu {
            Section("导入") {
                Button("从文件导入…", systemImage: "doc") { store.chooseFilesToImport() }
                Button("从链接导入…", systemImage: "link") { nav.linkSheet = true }
            }
            Section("密盒") {
                Button("重新读取密盒", systemImage: "arrow.clockwise") { store.refreshFiles() }
                    .disabled(store.link != .ready || store.loadingList || store.pull != nil)
                if store.wifi == nil, store.pull != nil || !store.queue.isEmpty {
                    Button("取消下载", systemImage: "xmark.circle") { store.cancelDownloads() }
                } else if store.recordings.contains(where: { $0.onDevice && !$0.downloaded && !$0.inProgress }) {
                    Button("全部下载", systemImage: "arrow.down.circle") { store.downloadAll() }.disabled(!store.encryptionReady)
                    if store.wifiSyncWorthOffering { Button("用 Wi‑Fi 快传…", systemImage: "wifi") { nav.confirmWiFiSync = true } }
                }
            }
            Section("按场景看") {
                Button("全部场景") { nav.route = .all }
                ForEach(Scene.allCases.filter { s in store.ownRecordings.contains { $0.scene == s } }) { s in
                    Button { nav.route = .scene(s) } label: { Label(s.name, systemImage: s.icon) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warm500)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("导入、密盒、按场景看")
    }

    /// 点一张卡片：多选时是勾选，平时是打开。
    private func tap(_ id: UInt32) {
        if selecting {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        } else {
            nav.selection = id; listFocused = true
        }
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let i = nav.selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        let next = ids[max(0, min(ids.count - 1, i + step))]
        nav.selection = next
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(next) }
    }

    /// 右键一行：不用先点开，就能改名、打星、删掉。
    @ViewBuilder private func rowMenu(_ rec: Recording) -> some View {
        Button("重命名…") { nav.renaming = rec.id }
        if rec.transcript != nil {
            Button("让 AI 重新起标题") { store.retitle(rec.id) }
                .disabled(!store.analysisAvailable || store.retitling.contains(rec.id))
        }
        Button(rec.starred ? "取消星标" : "标为星标") { store.toggleStar(rec.id) }
        Menu("移到项目") { ProjectMenuItems(ids: [rec.id]) }
        if let text = rec.transcript, !text.isEmpty {
            Button("拷贝文字稿") { copy(text) }
        }
        if rec.downloaded || (rec.onDevice && store.link == .ready) {
            Divider()
            // 删除要再确认一次，确认框挂在详情页上，所以先选中这一条
            if rec.downloaded {
                Button("移到最近删除", role: .destructive) { store.trashWithUndo([rec.id]) }
            }
            if rec.onDevice, store.link == .ready, !rec.inProgress {
                Button("从密盒删除…", role: .destructive) { nav.selection = rec.id; Task { nav.confirmDeviceDelete = true } }
            }
        }
    }

    private func pickFirstIfNeeded() {
        if let id = nav.selection, items.contains(where: { $0.id == id }) { return }
        nav.selection = items.first?.id
    }
}

/// 列表里的一行：左边一个场景色块，右边两层——AI 起的标题，和一行小信息（时间、时长、场合、关键词、待办和重点的个数）。
struct RecordingRow: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let recording: Recording
    var selected = false
    /// 多选时：勾了没有（不在多选就是 nil）。
    var checked: Bool? = nil
    /// 小信息里要不要带项目名（在项目页里就不用了）。
    var showProject = true
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                // 场景：一个小方块，扫一眼就知道这条是什么场合。选中的那条换成强调色
                if let checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20)).foregroundStyle(checked ? Theme.accent : Theme.warm300)
                        .frame(width: 24, height: 28)
                        .accessibilityLabel(checked ? "已选" : "未选")
                }
                let _ = store.videoRevision
                if recording.isMaterial, let thumb = NSImage(contentsOf: store.videoThumbURL(recording.id)) {
                    // 留了画面的视频素材：用画面第 1 秒当小封面
                    Image(nsImage: thumb).resizable().scaledToFill()
                        .frame(width: 28, height: 28).clipShape(.rect(cornerRadius: Theme.Radius.card))
                        .overlay(Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).shadow(radius: 2))
                        .help("从链接导入的视频素材，留了画面")
                } else {
                    Image(systemName: recording.isMaterial ? "play.fill" : (recording.scene ?? .other).icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(selected ? 0.1 : 0.12), in: .rect(cornerRadius: Theme.Radius.card))
                        .help(recording.isMaterial ? String(localized: "从链接导入的素材") : (recording.scene ?? .other).name)
                }
                Text(recording.displayTitle)
                    .font(.system(size: 14, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected || hover ? Theme.warm900 : Theme.warm800)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if store.retitling.contains(recording.id) { ProgressView().controlSize(.mini).padding(.top, 6) }
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if recording.starred { Image(systemName: "star.fill").foregroundStyle(Theme.accent).accessibilityLabel("星标") }
                    let todo = recording.todos.filter { !$0.done }.count
                    if todo > 0 { Label("\(todo)", systemImage: "square").labelStyle(.titleAndIcon).help("\(todo) 件待办没做完") }
                    if !recording.marks.isEmpty {
                        Label("\(recording.marks.count)", systemImage: "flag").labelStyle(.titleAndIcon).help("\(recording.marks.count) 个重点标记")
                    }
                    trailing
                }
                .font(.system(size: 12)).foregroundStyle(Theme.warm400).monospacedDigit()
                .padding(.top, 6)
            }
            // 标题下面只放小信息：几点、多长、什么场合，右边两个关键词。不放摘要句子，那是点开之后看的
            HStack(spacing: 6) {
                if !recording.isMaterial { SourceBadge(recording: recording) }
                Text(meta).lineLimit(1).monospacedDigit()
                Spacer(minLength: 4)
                // 归了项目的：先写项目名，再放关键词
                if showProject, let p = store.project(recording.project) {
                    Label(p.name, systemImage: "folder").labelStyle(.titleAndIcon).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Theme.warm700)
                        .background(Theme.warm200.opacity(0.7), in: .rect(cornerRadius: 4))
                        .fixedSize()
                }
                ViewThatFits(in: .horizontal) {
                    tags(showProject && recording.project != nil ? 1 : 2)
                    tags(1)
                    EmptyView()
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.warm500)
            .padding(.leading, checked == nil ? 38 : 72)
        }
        .padding(14)
        .background(Theme.surface.opacity(selected || hover ? 1 : 0.6), in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.warm200.opacity(0.6), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(selected ? 0.06 : hover ? 0.05 : 0.02), radius: selected || hover ? 4 : 1.5, y: 1)
        .contentShape(.rect(cornerRadius: Theme.Radius.card))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private var tint: Color {
        if selected || recording.isMaterial { return Theme.accent }     // 素材一律是红色的播放块，和自己的录音分开
        return recording.isAnalyzed ? Theme.amber : Theme.warm400
    }

    private func tags(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(shortTags.prefix(count)), id: \.self) { tag in
                // 正在看某个标签：这个标签排第一个，用强调色
                let on = nav.route == .tag(tag)
                Text(tag).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(on ? Theme.accent : Theme.warm600)
                    .background(on ? Theme.accent.opacity(0.12) : Theme.warm100, in: .rect(cornerRadius: 4))
            }
        }
    }

    /// 关键词：去掉井号，太长的不要（放不下，也说明它不是个词）。
    private var shortTags: [String] {
        let all = recording.tags.map(BeanStore.cleanTag).filter { !$0.isEmpty && $0.count <= 6 }
        if case .tag(let t) = nav.route, all.contains(t) { return [t] + all.filter { $0 != t } }
        return all
    }

    /// 日期已经写在分组标题上了，这里只写几点、多长、什么场合。
    private var meta: String {
        var parts: [String] = []
        // 从链接来的：先写平台和作者，再写多长
        if recording.isMaterial {
            return [recording.origin ?? String(localized: "素材"), clock(recording.duration)].joined(separator: " • ")
        }
        if let d = recording.date { parts.append(d.formatted(.dateTime.hour().minute())) }
        // 文字笔记的来源胶囊已经写了「文字」，不再重复
        if !recording.textOnly { parts.append(clock(recording.duration)) }
        else if recording.recordedOn != .note { parts.append(String(localized: "文字")) }
        if let scene = recording.scene { parts.append(scene.name) }
        else if !recording.downloaded { parts.append(String(localized: "还在密盒里")) }
        else if recording.transcript == nil { parts.append(String(localized: "还没转成文字")) }
        else if !recording.isAnalyzed { parts.append(String(localized: "还没整理")) }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var trailing: some View {
        if recording.inProgress {
            Image(systemName: "record.circle").foregroundStyle(Theme.rec).help("正在录音")
        } else if let pull = store.pull, pull.id == recording.id {
            ProgressView(value: pull.fraction).progressViewStyle(.circular).controlSize(.small)
        } else if store.isQueued(recording.id) {
            Image(systemName: "clock").foregroundStyle(.secondary).help("排队下载")
        } else if let stage = store.stages[recording.id] {
            StageBadge(stage: stage)
        } else if !recording.downloaded {
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("还在密盒里，没下载")
        }
    }
}

// MARK: - 录音详情

struct RecordingDetail: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let recording: Recording
    @State private var title = ""
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.warm200.opacity(0.6))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if recording.downloaded {
                        // 视频素材留了画面（或正在保存画面）：顶上放画面，跟着播放条走
                        let _ = store.videoRevision
                        if recording.isMaterial, store.hasVideo(recording.id) || store.videoWorking.contains(recording.id) {
                            MaterialVideoCard(recording: recording)
                        }
                        if let stage = store.stages[recording.id] { processing(stage) }
                        if recording.transcript != nil {
                            switch tab {
                            case 0: NotesView(recording: recording)
                            case 1: TranscriptView(recording: recording)
                            default: RewriteView(recording: recording)
                            }
                        } else if store.stages[recording.id] == nil {
                            notProcessed
                        }
                    } else {
                        notDownloaded
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 播放条固定在底部，文字稿从它上面滚过去
            if recording.downloaded, !recording.textOnly, store.recState == .idle {
                VStack(spacing: 8) {
                    if !recording.marks.isEmpty {
                        // 重点标记：点一个就从那一刻前两秒开始放
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recording.marks, id: \.self) { m in
                                    Button { store.play(recording.id, at: max(0, m - 2)) } label: {
                                        Label(clock(m), systemImage: "flag.fill").font(.system(size: 12, weight: .medium).monospacedDigit())
                                            .padding(.horizontal, 10).padding(.vertical, 4)
                                            .foregroundStyle(Theme.accent)
                                            .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.card))
                                    }
                                    .buttonStyle(.plain)
                                    .help("跳到这个重点标记。右键可以删掉")
                                    .accessibilityLabel("重点标记 \(clock(m))")
                                    .contextMenu { Button("删掉这个标记", role: .destructive) { store.removeMark(recording.id, m) } }
                                }
                            }
                        }
                    }
                    PlayerBar(recording: recording)
                }
                .padding(16)
                .background(Theme.surface.opacity(0.9))
                .overlay(alignment: .top) { Divider().overlay(Theme.warm200.opacity(0.6)) }
            }
        }
        .onAppear { title = recording.title ?? "" }
        .onChange(of: recording.id) { _, _ in title = recording.title ?? "" }
        .onChange(of: recording.title) { _, value in
            if title.trimmingCharacters(in: .whitespacesAndNewlines) != (value ?? "") {
                title = value ?? ""
            }
        }
        .confirmationDialog("从密盒里删除这条录音？", isPresented: Bindable(nav).confirmDeviceDelete) {
            Button("删除", role: .destructive) { store.deleteFromDevice(recording.id) }
        } message: {
            Text(recording.downloaded ? "这台 Mac 上已下载的副本会保留。" : "这条录音还没下载，删除后无法找回。")
        }
    }

    /// 顶上一块：场景、时间、一排工具；下面是标题和三个页签。
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Scene.allCases) { s in
                        Button { store.setScene(recording.id, s) } label: { Label(s.name, systemImage: s.icon) }
                    }
                } label: {
                    Label(recording.scene?.name ?? String(localized: "未分类"), systemImage: recording.scene?.icon ?? "tag")
                        .font(.system(size: 12, weight: .semibold)).labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.warm700)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("场景是自动判断的，判断错了可以在这里改")
                if !recording.isMaterial { SourceBadge(recording: recording, detailed: true).font(.system(size: 12, weight: .medium)) }
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warm500).lineLimit(1)
                Spacer(minLength: 8)
                tools
            }
            HStack(alignment: .center, spacing: 16) {
                // 标题长的时候折成两行，不被右边的页签挤掉
                TextField("标题", text: Binding(get: { title }, set: { value in
                    title = value
                    store.rename(recording.id, to: value)
                }), prompt: Text(recording.displayTitle), axis: .vertical)
                    .lineLimit(1...2)
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.warm900)
                    .disabled(!recording.downloaded)
                if recording.downloaded, recording.transcript != nil {
                    PaneSwitch(selection: $tab, titles: [String(localized: "纪要"), String(localized: "文字稿"), String(localized: "改写")])
                }
            }
            if recording.downloaded { TagBar(recording: recording) }
        }
        .padding(24)
        .background(Theme.surface.opacity(0.9))
    }

    /// 右上角一排：重新整理、导出、星标、AI 起标题、更多、删除。
    private var tools: some View {
        HStack(spacing: 4) {
            if recording.downloaded, recording.transcript != nil {
                IconTool("arrow.triangle.2.circlepath", help: String(localized: "重新整理纪要")) { store.process(recording.id) }
                    .disabled(store.stages[recording.id] != nil)
            }
            if recording.downloaded {
                IconMenu("square.and.arrow.up", help: String(localized: "导出")) {
                    Button("导出为 Markdown…") { store.exportMarkdown([recording]) }.disabled(!recording.isAnalyzed)
                    if !recording.textOnly {
                        Button("导出音频（M4A，体积小）…") { store.exportAudio(recording.id, m4a: true) }
                        Button("导出音频（WAV，无损）…") { store.exportAudio(recording.id, m4a: false) }
                    }
                    Button("拷贝文字稿") { copy(recording.transcript ?? "") }.disabled(recording.transcript == nil)
                }
            }
            IconTool(recording.starred ? "star.fill" : "star", help: recording.starred ? String(localized: "取消星标") : String(localized: "标为星标"),
                     tint: recording.starred ? Theme.accent : nil) { store.toggleStar(recording.id) }
            if recording.transcript != nil {
                IconTool("wand.and.sparkles", help: String(localized: "让 AI 重新起标题")) { store.retitle(recording.id) }
                    .disabled(!store.analysisAvailable || store.retitling.contains(recording.id))
            }
            if recording.downloaded {
                IconMenu("ellipsis", help: String(localized: "更多操作")) {
                    Menu("移到项目") { ProjectMenuItems(ids: [recording.id]) }
                    Divider()
                    Button("重新整理纪要") { store.process(recording.id) }.disabled(recording.transcript == nil)
                    Button("重新转写") { store.process(recording.id, retranscribe: true) }.disabled(recording.textOnly)
                    Button(store.settings.asrConfig == nil ? "交给云端重转（先在设置里配好云端转写）" : "交给云端重转") {
                        store.process(recording.id, retranscribe: true, cloud: true)
                    }
                    .disabled(recording.textOnly || store.settings.asrConfig == nil || store.settings.engine == .cloud)
                    if recording.isMaterial {
                        Divider()
                        if store.hasVideo(recording.id) {
                            Button("删掉画面（保留声音和文字稿）") { store.removeVideo(recording.id) }
                        } else {
                            Button(store.videoWorking.contains(recording.id) ? "正在下载画面…" : "下载画面（最高 720p）") { store.fetchVideo(recording.id) }
                                .disabled(store.videoWorking.contains(recording.id) || recording.source == nil)
                        }
                    }
                    Divider()
                    if let source = recording.source, let url = URL(string: source) {
                        Button("打开原链接") { NSWorkspace.shared.open(url) }
                        Button("拷贝原链接") { copy(source) }
                    }
                    if recording.origin == nil { Button("在访达中显示音频") { store.reveal(recording.id) } }
                    if let url = FeishuSync.shared.link(for: recording.id) { Button("在飞书妙记里打开") { NSWorkspace.shared.open(url) } }
                }
                .disabled(store.stages[recording.id] != nil)
            }
            IconMenu("trash", help: String(localized: "删除"), danger: true) {
                if recording.downloaded { Button("移到最近删除") { store.trashWithUndo([recording.id]) } }
                if recording.onDevice { Button("从密盒删除…") { nav.confirmDeviceDelete = true } }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let p = store.project(recording.project) { parts.append(String(localized: "项目「\(p.name)」")) }
        // 自己录的来源已经在前面的小胶囊里了；素材这里写平台和作者
        if recording.isMaterial, let o = recording.origin { parts.append(o) }
        if let d = recording.date {
            // 今年的不写年份，省地方
            let thisYear = Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
            parts.append(thisYear ? d.formatted(.dateTime.month().day().hour().minute()) : d.formatted(.dateTime.year().month().day().hour().minute()))
        }
        if !recording.textOnly { parts.append(spokenDuration(recording.duration)) }
        return "•  " + parts.joined(separator: "  •  ")
    }

    private func processing(_ stage: BeanStore.Stage) -> some View {
        HStack(spacing: 10) {
            switch stage {
            case .queued:
                Image(systemName: "clock"); Text("排队中，等前面的处理完")
            case .transcribing(let f):
                ProgressView(value: f).frame(width: 140); Text("正在本机转写 \(Int(f * 100))%")
            case .analyzing:
                ProgressView().controlSize(.small); Text("正在判断场景、整理纪要…")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    private var notProcessed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这条录音还没转写。").foregroundStyle(.secondary)
            Button("转写并整理", systemImage: "sparkles") { store.process(recording.id) }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recording.inProgress {
                Label("这条还在录。在密盒上按一下停止，或者点「结束录音」；录完会自动下载、转成文字。", systemImage: "record.circle").foregroundStyle(.secondary)
            } else if let pull = store.pull, pull.id == recording.id {
                if store.wifi != nil {
                    ProgressView(value: pull.fraction) { Text("正在通过 Wi‑Fi 快传 \(Int(pull.fraction * 100))%") }
                } else {
                    ProgressView(value: pull.fraction) { Text("正在通过蓝牙下载 \(Int(pull.fraction * 100))%") }
                    Text("蓝牙比较慢，长录音要等几分钟。期间请让密盒留在电脑旁边。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { store.cancelDownloads() }
                        if store.wifiSyncWorthOffering { Button("改用 Wi‑Fi 快传…") { nav.confirmWiFiSync = true } }
                    }
                }
            } else if store.isQueued(recording.id) {
                Label("排队中，等前面的下载完", systemImage: "clock").foregroundStyle(.secondary)
            } else {
                Text("这条录音还在密盒里。下载后会自动转写并整理。").foregroundStyle(.secondary)
                Button("下载到这台 Mac", systemImage: "arrow.down.circle") { store.download(recording.id) }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(store.link != .ready || !store.encryptionReady)
            }
        }
    }
}

private struct RecordingToolTip: ViewModifier {
    let text: String
    @Binding var hover: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var visible = false

    func body(content: Content) -> some View {
        ZStack {
            content.disabled(!enabled)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
            visible = false
        }
        .task(id: hover) {
            guard hover else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                visible = true
            } catch { }
        }
        .overlay(alignment: .topTrailing) {
            if hover && visible {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warm900)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.chip))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(Theme.warm200, lineWidth: 1)
                    }
                    .fixedSize()
                    .offset(y: -24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear {
            hover = false
            visible = false
        }
        .environment(\.isEnabled, true)
    }
}

/// 详情页右上角的一个图标按钮：36 见方，悬停时垫一块浅灰。
struct IconTool: View {
    let icon: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ icon: String, help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon; self.help = help; self.tint = tint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? Theme.warm600)
                .frame(width: 36, height: 36)
                .background(hover && enabled ? Theme.warm100 : .clear, in: .rect(cornerRadius: Theme.Radius.card))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(help)
        .modifier(RecordingToolTip(text: help, hover: $hover))
    }
}

/// 同上，点开是一个菜单。删除那颗悬停时变成浅红。
struct IconMenu<Content: View>: View {
    let icon: String
    let help: String
    var danger = false
    @ViewBuilder let content: Content
    @State private var hover = false

    init(_ icon: String, help: String, danger: Bool = false, @ViewBuilder content: () -> Content) {
        self.icon = icon; self.help = help; self.danger = danger; self.content = content()
    }

    var body: some View {
        Menu { content } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(danger && hover ? Theme.accent : Theme.warm600)
                .frame(width: 36, height: 36)
                .background(hover ? (danger ? Theme.accent.opacity(0.1) : Theme.warm100) : .clear, in: .rect(cornerRadius: Theme.Radius.card))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(help)
        .modifier(RecordingToolTip(text: help, hover: $hover))
    }
}

/// 「纪要 / 文字稿 / 改写」：浅灰底，选中的那格是白的。
struct PaneSwitch: View {
    @Binding var selection: Int
    let titles: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { selection = i } } label: {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == i ? Theme.warm900 : Theme.warm500)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background {
                            if selection == i {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == i ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
        .fixedSize()
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct PlayerBar: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var bars: [Float] = []
    /// 播放条太窄：把前后跳的按钮收起来（菜单和快捷键还在），先保住时间轴的长度。
    @State private var compact = false

    var body: some View {
        let active = store.playingID == recording.id
        HStack(spacing: compact ? 10 : 14) {
            Button { store.togglePlay(recording.id) } label: {
                Image(systemName: active && store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white).offset(x: active && store.isPlaying ? 0 : 1)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: .circle)
                    .shadow(color: Theme.accent.opacity(0.25), radius: 6, y: 3)
            }
            .buttonStyle(PressScale())
            .keyboardShortcut(.space, modifiers: [])
            .help(active && store.isPlaying ? "暂停（空格）" : "播放（空格）")
            .accessibilityLabel(active && store.isPlaying ? "暂停" : "播放")
            if !compact {
                Button { store.skip(recording.id, by: -15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("往回 15 秒（⌥⌘←）")
                    .accessibilityLabel("往回 15 秒")
                Button { store.skip(recording.id, by: 15) } label: { Image(systemName: "goforward.15").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("往后 15 秒（⌥⌘→）")
                    .accessibilityLabel("往后 15 秒")
            }
            Timeline(bars: bars, duration: recording.duration, playhead: active ? store.playhead : 0,
                     marks: recording.segments.map(\.start), flags: recording.marks) { time in
                store.play(recording.id, at: time)
            }
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel("播放进度")
            .accessibilityValue(String(localized: "\(clock(active ? store.playhead : 0))，共 \(clock(recording.duration))") + (recording.marks.isEmpty ? "" : String(localized: "，\(recording.marks.count) 个重点标记")))
            .accessibilityAdjustableAction { direction in
                store.skip(recording.id, by: direction == .increment ? 15 : -15)
            }
            Text(compact ? clock(active ? store.playhead : 0) : "\(clock(active ? store.playhead : 0)) / \(clock(recording.duration))")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.warm700)
            // 点一下换下一档速度
            Button {
                let i = BeanStore.rates.firstIndex(of: store.playRate) ?? 1
                store.setRate(BeanStore.rates[(i + 1) % BeanStore.rates.count])
            } label: {
                Text(rateLabel(store.playRate)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.warm200.opacity(0.8), in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain).help("播放速度，点一下换一档（⌘] 加快，⌘[ 放慢）")
            .accessibilityLabel("播放速度").accessibilityValue(String(localized: "\(String(rateLabel(store.playRate).dropLast())) 倍"))
        }
        .padding(12)
        .background(Theme.warm100.opacity(0.8), in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.warm200, lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { compact = $0 }
        .task(id: recording.id) {
            let url = store.wavURL(recording.id)
            bars = await Task.detached { BeanStore.waveform(of: url) }.value
        }
    }
}

func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
}

/// 录音的时间轴：一条波形，播过的部分着色，每句话开头有个小刻度。点一下或拖动就跳到那里。
struct Timeline: View {
    let bars: [Float]
    let duration: TimeInterval
    let playhead: TimeInterval
    let marks: [TimeInterval]
    var flags: [TimeInterval] = []
    let seek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let progress = duration > 0 ? CGFloat(min(1, playhead / duration)) : 0
            Canvas { context, size in
                let count = max(bars.count, 1)
                let step = size.width / CGFloat(count)
                for (i, level) in (bars.isEmpty ? [Float](repeating: 0.08, count: 80) : bars).enumerated() {
                    let x = CGFloat(i) * (bars.isEmpty ? size.width / 80 : step)
                    let barH = max(2, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - barH) / 2, width: max(1.5, (bars.isEmpty ? size.width / 80 : step) * 0.6), height: barH)
                    let played = x <= size.width * progress
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(played ? Theme.accent.opacity(0.85) : Theme.warm300))
                }
                // 每句话开头的刻度
                if duration > 0 {
                    for m in marks {
                        let x = size.width * CGFloat(m / duration)
                        context.fill(Path(CGRect(x: x, y: size.height - 3, width: 1, height: 3)), with: .color(.secondary.opacity(0.7)))
                    }
                    // 重点标记：琥珀色的一根线，顶上一个点
                    for f in flags {
                        let x = size.width * CGFloat(min(1, f / duration))
                        context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.accent))
                        context.fill(Path(ellipseIn: CGRect(x: x - 3, y: 0, width: 6, height: 6)), with: .color(Theme.accent))
                    }
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                seek(duration * Double(max(0, min(1, value.location.x / w))))
            })
        }
        .help("点一下或拖动，跳到那里")
    }
}

/// 窗口底部的录音条。录音时显示实时波形、已录时长、暂停和结束；没在录时是一颗开始按钮。
struct RecordDock: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    /// 没在录的时候，首页和录音页自己有开始按钮和播放条，就不再多摆一颗。
    private var hiddenWhenIdle: Bool {
        true
    }

    var body: some View {
        Group {
            if store.recState == .idle {
                if !hiddenWhenIdle {
                    Button { store.startRecording() } label: {
                        Label(store.link == .ready ? "开始录音" : "用 Mac 录音", systemImage: "record.circle.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.extraLarge)
                            .help(store.link == .ready ? "让密盒开始录音（⌘R）" : "密盒没连上，用这台 Mac 的麦克风录（⌘R）")
                }
            } else {
                active
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.recState)
    }

    private var active: some View {
        let paused = store.recState == .paused
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(paused ? Theme.accent : Theme.rec).frame(width: 9, height: 9)
                    .symbolEffect(.pulse, isActive: !paused)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(store.elapsed(at: context.date)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            Button { nav.stageOpen = true } label: {
                FlowWave(levels: store.liveLevels, total: store.liveLevelTotal, marks: store.liveMarks,
                         elapsed: { store.elapsed(at: $0) }, paused: paused, color: .primary)
                    .frame(width: 220, height: 30)
            }
            .buttonStyle(.plain)
            .help("回到录音舞台")
            if paused { Text("已暂停").font(.callout).foregroundStyle(.secondary) }

            Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).controlSize(.large)
            .help(paused ? "继续录（⌘R）" : "暂停，稍后可以接着录进同一条（⌘R）")

            Button { store.finishRecording() } label: {
                Label("结束", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.large)
            .help("结束这条录音（⌘.）。结束后会自动下载并整理成纪要。")
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 把录音改写成别的东西：口播稿、文章、邮件，或者自己写要求。
struct RewriteView: View {
    @Environment(BeanStore.self) private var store
    @Environment(VideoMaker.self) private var maker
    @State private var makingVideo = false
    let recording: Recording
    @State private var template: RewriteTemplate = .voiceover
    @State private var extra = ""

    private var templatePicker: some View {
        Picker("改成", selection: $template) {
            ForEach(RewriteTemplate.allCases) { Text($0.name).tag($0) }
        }
    }

    var body: some View {
        let busy = store.rewriting.contains(recording.id)
        VStack(alignment: .leading, spacing: 14) {
            Card {
                // 七个模板一排放得下就用分段控件；窗口窄放不下时换成下拉菜单，不把整页撑出窗口
                ViewThatFits(in: .horizontal) {
                    templatePicker.pickerStyle(.segmented).labelsHidden()
                    HStack(spacing: 8) {
                        Text("改成").foregroundStyle(.secondary)
                        templatePicker.pickerStyle(.menu).labelsHidden().fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                if template != .custom {
                    Text(template.instruction).font(.callout).foregroundStyle(.secondary)
                }
                TextField(template == .custom ? "写下你想把它改成什么样，比如：改成给投资人的三句话电梯演讲" : "补充要求（可不填），比如：控制在 200 字以内、语气再轻松一点",
                          text: $extra, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button { store.rewrite(recording.id, template: template, extra: extra) } label: {
                        Label(busy ? "正在写…" : "生成", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(busy || !store.analysisAvailable || (template == .custom && extra.trimmingCharacters(in: .whitespaces).isEmpty))
                    if busy { ProgressView().controlSize(.small) }
                    if !store.analysisAvailable {
                        Text("需要先设置分析模型。").font(.callout).foregroundStyle(.secondary)
                        ModelSettingsLink()
                    }
                }
            }
            // 正在做的视频：一直挂在最上面，点「看进度」打开那张单子
            if maker.recording == recording.id, maker.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(maker.statusLine)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("看进度") { makingVideo = true }
                }
                .padding(12).panel(radius: Theme.Radius.card)
            }
            // 用这条录音做出来的视频：成片、封面、口播稿、包装说明、质检都回到这里（VideoResultCard）
            ForEach(recording.videos) { clip in
                VideoResultCard(recording: recording, clip: clip)
            }
            ForEach(recording.rewrites) { item in
                Card {
                    HStack {
                        Text(item.name).font(.headline)
                        Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            makingVideo = true
                            maker.prepare(text: item.text, recording: recording.id, title: recording.displayTitle, template: item.name)
                        } label: { Label("做成视频", systemImage: "play.rectangle.on.rectangle") }
                            .buttonStyle(.glass).tint(Theme.accent)
                            .disabled(maker.busy && maker.recording != recording.id)
                            .help("交给 Claude 桌面版，用 Renoise 的数字人和口播剪辑 skill 做成带包装的成片。会先报价，确认了才开始")
                        Button("拷贝", systemImage: "doc.on.doc") { copy(item.text); store.toast("doc.on.doc", String(localized: "已拷贝")) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        Button("删除", systemImage: "trash") { store.deleteRewrite(recording.id, item.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    MarkdownView(text: item.text)
                }
            }
            if recording.rewrites.isEmpty {
                Text("改写会按你在设置里选的职业来把握语气。结果由模型生成，发出去之前请自己过一遍。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $makingVideo) { VideoSheet() }
    }
}

struct NotesView: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 英文为主的录音：可以勾「英语学习模式」（StudyView.swift），默认是普通纪要
            if BeanStore.isMostlyEnglish(recording.transcript ?? "") { StudyToggle(recording: recording) }
            if recording.studyMode {
                if let study = recording.study { StudyView(recording: recording, study: study) }
                else if !store.studying.contains(recording.id) {
                    Text("还没有学习笔记。点上面的「英语学习模式」重新勾一下，或者检查整理纪要的模型是否设置好。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                normal
            }
        }
    }

    private var normal: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary = recording.summary {
                Card(title: String(localized: "摘要"), icon: "text.alignleft") {
                    Text(MarkdownView.inline(summary)).font(.system(size: 14)).foregroundStyle(Theme.warm700).textSelection(.enabled).lineSpacing(5)
                }
            }
            ForEach(recording.sections) { section in
                Card(title: section.heading, icon: "checklist") {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(y: -2)
                            Text(MarkdownView.inline(item)).font(.system(size: 14)).foregroundStyle(Theme.warm700).textSelection(.enabled).lineSpacing(4)
                        }
                    }
                }
            }
            if !recording.todos.isEmpty {
                Card(title: String(localized: "待办"), icon: "checkmark.square.fill") {
                    ForEach(recording.todos) { todo in
                        Toggle(isOn: Binding(get: { todo.done }, set: { _ in store.toggleTodo(recording.id, todo.id) })) {
                            Text(todo.text).font(.system(size: 14)).strikethrough(todo.done).foregroundStyle(Theme.warm800)
                                .opacity(todo.done ? 0.75 : 1).padding(.leading, 4)
                        }
                        .toggleStyle(.checkbox)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.6), lineWidth: 1))
                    }
                }
            }
            if !recording.tags.isEmpty || !recording.people.isEmpty {
                // 人物和标签多的时候一行放不下：换行排，不能挤在一行里把字压成竖排（issue #2）
                FlowLayout(spacing: 6) {
                    ForEach(recording.people, id: \.self) { p in chip(p, "person.fill") }
                    ForEach(recording.tags, id: \.self) { t in chip(t, "number") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if recording.analyzedBy == "关键词规则" {
                Card {
                    Label("这条只按关键词粗略分了类，还没有完整纪要。", systemImage: "info.circle").foregroundStyle(.secondary)
                    if store.analysisAvailable {
                        Button("用分析模型整理", systemImage: "sparkles") { store.process(recording.id) }
                            .buttonStyle(.glassProminent).controlSize(.large)
                            .disabled(store.stages[recording.id] != nil)
                    } else {
                        Text("先在设置里配置云端模型，或下载本机模型。").font(.callout).foregroundStyle(.secondary)
                        ModelSettingsLink(title: String(localized: "打开设置"))
                    }
                }
            }
            Text(credits).font(.system(size: 11)).foregroundStyle(Theme.warm500)
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Text(icon == "number" ? "# " + text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : text)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warm700)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
    }

    private var credits: String {
        var parts: [String] = []
        if let t = recording.transcribedBy { parts.append(String(localized: "转写：\(t)")) }
        if let a = recording.analyzedBy, a != "—" { parts.append(String(localized: "整理：\(a)")) }
        parts.append(String(localized: "内容由模型生成，重要信息请对照录音核实"))
        return parts.joined(separator: " • ")
    }
}

struct TranscriptView: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    @State private var showClean = true
    @State private var editing = false
    @State private var segmentEdit: SegmentEdit?
    @State private var replacing = false
    @State private var wrong = ""
    @State private var right = ""
    @State private var remember = true
    @State private var everywhere = false
    @State private var renaming: Int?
    @State private var newName = ""
    /// 原文、双语、译文。有译文时默认双语。
    @State private var view: Shown = .both
    @State private var translateOpen = false
    /// 逐句回听（设计稿 design/ui/ui_listen.png）：单句循环、跟着播放滚动、鼠标停在哪一句
    @AppStorage("sentenceLoop") private var loopOn = false
    @AppStorage("followPlayback") private var follow = true
    @State private var hovered: TimeInterval?

    private struct SegmentEdit: Identifiable {
        let start: TimeInterval
        let clean: Bool
        let text: String
        var id: TimeInterval { start }
    }

    enum Shown: String, CaseIterable {
        case original = "原文", both = "双语", translated = "译文"
        /// 显示用的名字（rawValue 只当标识用）。
        var name: String {
            switch self {
            case .original: String(localized: "原文")
            case .both: String(localized: "双语")
            case .translated: String(localized: "译文")
            }
        }
    }

    private var hasClean: Bool { recording.segments.contains { $0.clean != nil } }
    private var replacingTranscript: Bool {
        if case .transcribing = store.stages[recording.id] { return true }
        if case .queued = store.stages[recording.id], store.retranscribing.contains(recording.id) { return true }
        return false
    }
    private var translation: Translation? { recording.translation }
    /// 这一句的译文（分句数对不上就不显示，免得错位）。
    private func translated(_ index: Int) -> String? {
        guard let t = translation, view != .original else { return nil }
        let count = recording.segments.isEmpty ? 1 : recording.segments.count
        guard t.lines.count == count, t.lines.indices.contains(index) else { return nil }
        let line = t.lines[index].trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
    private let palette: [Color] = Theme.speakers

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let fix = store.pendingFix, fix.recording == recording.id { fixBar(fix) }
            if let p = store.translating[recording.id] {
                HStack(spacing: 10) {
                    ProgressView(value: p).frame(width: 140).tint(Theme.accent)
                    Text("正在翻译 \(Int(p * 100))%").font(.callout).foregroundStyle(Theme.warm500)
                }
            } else if translation == nil, store.needsTranslation(recording) {
                // 外语的：主动问一句
                HStack(spacing: 10) {
                    Image(systemName: "character.bubble").foregroundStyle(Theme.accent)
                    Text("这条不是\(store.settings.translateTo)的。要逐句翻译成\(store.settings.translateTo)吗？").font(.callout).foregroundStyle(Theme.warm700)
                    Spacer()
                    Button("翻译（\(store.settings.translateStyle.name)）") { store.translate(recording.id) }
                        .buttonStyle(.borderedProminent).disabled(!store.analysisAvailable)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
            }
            if recording.segments.isEmpty {
                if view != .translated || translated(0) == nil {
                    Text(recording.transcript ?? "").textSelection(.enabled).lineSpacing(5)
                }
                if let t = translated(0) { translationLine(t, solo: view == .translated) }
            }
            if canListen { listenBar }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(recording.segments.enumerated()), id: \.element.id) { i, seg in row(seg, index: i).id(seg.start) }
                }
                // 跟着播放滚：当前句换了就把它滚到中间
                .onChange(of: currentIndex) { _, i in
                    guard follow, !editing, let i, store.isPlaying else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(recording.segments[i].start, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $segmentEdit) { edit in
            TranscriptSegmentSheet(text: edit.text, clean: edit.clean) { text in
                store.editSegment(recording.id, start: edit.start, to: text, clean: edit.clean)
            }
        }
        .alert("给这位说话人起个名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("好") { if let r = renaming { store.renameSpeaker(recording.id, r, to: newName) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    // MARK: 逐句回听

    /// 有音频、有分句时间的才能逐句听
    private var canListen: Bool { !recording.textOnly && !recording.segments.isEmpty }
    private var mine: Bool { store.playingID == recording.id }

    /// 第 i 句的时间段：从这句开头到下一句开头（最后一句到结尾）
    private func span(_ i: Int) -> ClosedRange<TimeInterval> {
        let segs = recording.segments
        let start = segs[i].start
        let end = i + 1 < segs.count ? segs[i + 1].start : max(start + 0.5, recording.duration)
        return start...max(start + 0.3, end)
    }

    /// 正在播的是第几句（没在播这条时为空）
    private var currentIndex: Int? {
        guard mine else { return nil }
        return recording.segments.lastIndex { $0.start <= store.playhead + 0.05 }
    }

    /// 这一句读到哪了（0…1），按时间在这句里的比例估
    private func progress(_ i: Int) -> Double {
        let s = span(i)
        return max(0, min(1, (store.playhead - s.lowerBound) / max(0.3, s.upperBound - s.lowerBound)))
    }

    /// 读过的部分深色带底色，没读的浅色。按字数比例推进；英文推到当前单词结尾，不把一个词切成两半。
    private func spoken(_ text: String, fraction: Double) -> AttributedString {
        let chars = Array(text)
        var k = Int((Double(chars.count) * fraction).rounded())
        while k > 0, k < chars.count, chars[k - 1].isASCII, chars[k - 1].isLetter, chars[k].isASCII, chars[k].isLetter { k += 1 }
        var a = AttributedString(text)
        let cut = a.index(a.startIndex, offsetByCharacters: min(k, chars.count))
        a[a.startIndex..<cut].foregroundColor = Theme.warm900
        a[a.startIndex..<cut].backgroundColor = Theme.accent.opacity(0.16)
        a[cut..<a.endIndex].foregroundColor = Theme.warm500
        return a
    }

    /// 点一句：开着单句循环就循环这句，否则从这句一直往下播
    private func listen(_ i: Int) {
        if loopOn { store.playSpan(recording.id, span(i), loop: true) }
        else { store.play(recording.id, at: recording.segments[i].start) }
    }

    private func step(_ delta: Int) {
        let n = recording.segments.count
        guard n > 0 else { return }
        let i = max(0, min(n - 1, (currentIndex ?? -1) + delta))
        listen(i)
    }

    private func replayCurrent() {
        guard let i = currentIndex ?? (recording.segments.isEmpty ? nil : 0) else { return }
        store.playSpan(recording.id, span(i), loop: loopOn)
    }

    /// 文字稿上面的一排：单句循环、上一句 / 下一句 / 这句再听、跟着滚动，和快捷键提示。
    private var listenBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { loopOn }, set: { on in
                    loopOn = on
                    if on, mine, let i = currentIndex { store.loopSpan = span(i); store.loopCount = 1 } else if !on { store.endLoop() }
                })) { Label("单句循环", systemImage: "repeat") }
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent).fixedSize()
                    .keyboardShortcut("l", modifiers: .option)
                    .help("开着时点哪句就一直重复那句，适合听不清、跟读（⌥L）")
                Divider().frame(height: 16)
                Button { step(-1) } label: { Label("上一句", systemImage: "arrow.up") }
                    .keyboardShortcut(.upArrow, modifiers: .option).help("上一句（⌥↑）")
                Button { step(1) } label: { Label("下一句", systemImage: "arrow.down") }
                    .keyboardShortcut(.downArrow, modifiers: .option).help("下一句（⌥↓）")
                Button { replayCurrent() } label: { Label("这句再听", systemImage: "gobackward") }
                    .keyboardShortcut("r", modifiers: .option).help("从句首再听一遍这句（⌥R）")
                Spacer(minLength: 8)
                Toggle(isOn: $follow) { Text("跟着滚动") }
                    .toggleStyle(.checkbox).fixedSize()
                    .help("播放时把正在播的那句滚到中间")
            }
            .buttonStyle(.glass).controlSize(.small)
            // 「修改」时在编辑框里打字：⌥↑ ⌥↓ 要留给光标，⌥R ⌥L 不能被拿去换句、开循环
            .disabled(editing)
            Text("点一句就从那里播 · 空格 暂停 · ⌥↑ ⌥↓ 换句 · ⌥R 这句再听 · ⌥L 单句循环")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// 上面一排：左边是改文字稿的工具，右边是翻译。放不下就分成两行，不挤掉文字。
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { editTools; Spacer(minLength: 12); translateTools }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { editTools; Spacer() }
                HStack(spacing: 10) { translateTools; Spacer() }
            }
        }
    }

    @ViewBuilder private var editTools: some View {
        if hasClean {
            Picker("", selection: $showClean) {
                Text("润色版").tag(true)
                Text("原文").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .help("润色版去掉了语气词和重复；原文是模型听到的原话")
        }
        Toggle(isOn: $editing) { Label("修改", systemImage: "pencil") }
            .toggleStyle(.button).fixedSize()
            .help("打开后可以直接改每一句的文字")
        Button { replacing.toggle() } label: { Label("替换词语", systemImage: "arrow.left.arrow.right") }
            .fixedSize()
            .popover(isPresented: $replacing, arrowEdge: .bottom) { replaceForm }
    }

    @ViewBuilder private var translateTools: some View {
        if translation != nil {
            PaneSwitch(selection: Binding(get: { Shown.allCases.firstIndex(of: view) ?? 1 }, set: { view = Shown.allCases[$0] }),
                       titles: Shown.allCases.map(\.name))
        }
        if let t = translation {
            Text("\(t.language) · \(t.style)").font(.caption).foregroundStyle(Theme.warm500).fixedSize()
        }
        Button { translateOpen.toggle() } label: {
            Label(translation == nil ? "翻译" : "重新翻译", systemImage: "character.bubble").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent).fixedSize()
        .disabled(store.translating[recording.id] != nil || recording.transcript == nil)
        .popover(isPresented: $translateOpen, arrowEdge: .bottom) {
            TranslatePanel(recording: recording) { translateOpen = false }
        }
    }

    /// 一句译文：比原文略小、暖灰色，左边一条细红线。只看译文时就是正文的样子。
    private func translationLine(_ text: String, solo: Bool) -> some View {
        Text(text).textSelection(.enabled).lineSpacing(4)
            .font(solo ? .body : .system(size: 13))
            .foregroundStyle(solo ? Theme.warm900 : Theme.warm600)
            .padding(.leading, solo ? 0 : 10)
            .overlay(alignment: .leading) { if !solo { Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 2) } }
    }

    private var replaceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把听错的词全部改掉").font(.headline)
            TextField("听错成了", text: $wrong).frame(width: 240)
            TextField("应该是", text: $right).frame(width: 240)
            Toggle("记住，以后转写时自动改", isOn: $remember)
            Toggle("所有录音都改，不只这一条", isOn: $everywhere)
            HStack {
                Spacer()
                Button("替换") {
                    let n = store.replaceWord(wrong, with: right, in: recording.id, everywhere: everywhere, remember: remember)
                    store.toast("checkmark.circle.fill", n > 0 ? String(localized: "改了 \(n) 处") : (remember ? String(localized: "这里没有这个词，已记进词库") : String(localized: "这里没有这个词")))
                    wrong = ""; right = ""; replacing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(wrong.isEmpty || wrong == right)
            }
        }
        .padding(16)
    }

    private func fixBar(_ fix: BeanStore.PendingFix) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("你把「\(fix.wrong)」改成了「\(fix.right)」。").lineLimit(1)
            Spacer()
            Button("全部替换并记住") {
                let n = store.replaceWord(fix.wrong, with: fix.right, in: recording.id, everywhere: true, remember: true)
                store.toast("checkmark.circle.fill", String(localized: "又改了 \(n) 处，以后会自动改"))
                store.pendingFix = nil
            }
            .buttonStyle(.borderedProminent)
            Button("只改这一处") { store.pendingFix = nil }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
    }

    private func row(_ seg: Segment, index: Int) -> some View {
        let useClean = showClean && seg.clean != nil
        let line = translated(index)
        let marked = isMarked(seg)
        let playingThis = canListen && currentIndex == index
        let looping = playingThis && store.loopSpan != nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(clock(seg.start)) { store.play(recording.id, at: seg.start) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout.monospacedDigit())
                .frame(width: 46, alignment: .leading)
                .help("从这里开始播放")
                .overlay(alignment: .leading) {
                    if marked { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Theme.accent).offset(x: -16).help("这句标了重点") }
                }
            speakerMenu(seg)
            if editing {
                SegmentEditor(text: useClean ? (seg.clean ?? seg.text) : seg.text) { new in
                    store.editSegment(recording.id, start: seg.start, to: new, clean: useClean)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if view != .translated || line == nil {
                        let shown = useClean ? (seg.clean ?? seg.text) : seg.text
                        if playingThis {
                            // 正在读的这句：读过的部分跟着进度变深、带底色（像卡拉 OK 歌词）
                            Text(spoken(shown, fraction: progress(index))).lineSpacing(5)
                        } else {
                            // 能逐句听的时候单击是「从这句播」，可选中的文字会把单击吞掉；拷贝走右键「拷贝这句」
                            Text(shown).modifier(Selectable(on: !canListen)).lineSpacing(5)
                                .foregroundStyle(isCurrent(seg) ? .primary : .secondary)
                        }
                    }
                    if let line { translationLine(line, solo: view == .translated) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 点句子本身就从这句播（文字还能拖选拷贝）
                .contentShape(.rect)
                .onTapGesture { if canListen, !editing { listen(index) } }
                .accessibilityAction(named: "从这句播") { if canListen { listen(index) } }
                if looping {
                    Label("第 \(store.loopCount) 遍", systemImage: "repeat").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: .capsule).fixedSize()
                } else if canListen, hovered == seg.start, !editing {
                    HStack(spacing: 6) {
                        Button { store.play(recording.id, at: seg.start) } label: { Label("从这句播", systemImage: "play.fill") }
                        Button { store.playSpan(recording.id, span(index), loop: false) } label: { Label("这句再听", systemImage: "gobackward") }
                    }
                    .buttonStyle(.glass).controlSize(.small).labelStyle(.titleAndIcon).fixedSize()
                }
            }
        }
        .padding(.vertical, marked || playingThis || hovered == seg.start ? 6 : 0)
        .padding(.horizontal, marked || playingThis || hovered == seg.start ? 8 : 0)
        .background(playingThis ? Theme.accent.opacity(0.09) : marked ? Theme.accent.opacity(0.12) : hovered == seg.start && canListen && !editing ? Theme.warm100 : .clear,
                    in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if playingThis { Rectangle().fill(Theme.accent).frame(width: 3).padding(.vertical, 4) }
        }
        .padding(.horizontal, marked || playingThis || hovered == seg.start ? -8 : 0)
        .onHover { inside in
            if inside { hovered = seg.start } else if hovered == seg.start { hovered = nil }
        }
        .contextMenu {
            Button("修改这段文字") {
                segmentEdit = SegmentEdit(start: seg.start, clean: useClean, text: useClean ? (seg.clean ?? seg.text) : seg.text)
            }
            .disabled(editing || replacingTranscript)
            .help(replacingTranscript ? "转写中，请等它完成后修改" : "修改这段文字")
            Divider()
            if marked {
                Button("取消重点标记") { for m in marksIn(seg) { store.removeMark(recording.id, m) } }
            } else {
                Button("标为重点") { store.addMark(recording.id, at: seg.start + 0.5) }
            }
            Button("从这里开始播放") { store.play(recording.id, at: seg.start) }
            Button("拷贝这句") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(useClean ? (seg.clean ?? seg.text) : seg.text, forType: .string)
            }
            if canListen {
                Button("这句再听一遍") { store.playSpan(recording.id, span(index), loop: false) }
                Button("循环这一句") { loopOn = true; store.playSpan(recording.id, span(index), loop: true) }
            }
        }
    }

    /// 落在这句话里的重点标记。
    private func marksIn(_ seg: Segment) -> [TimeInterval] {
        let next = recording.segments.first { $0.start > seg.start }?.start ?? .infinity
        let first = recording.segments.first?.start == seg.start
        return recording.marks.filter { ($0 >= seg.start || first) && $0 < next }
    }

    private func isMarked(_ seg: Segment) -> Bool { !recording.marks.isEmpty && !marksIn(seg).isEmpty }

    /// 每句前面的小标签：点一下选这句是谁说的。
    private func speakerMenu(_ seg: Segment) -> some View {
        Menu {
            ForEach(Array(recording.speakers.enumerated()), id: \.offset) { n, name in
                Button(name) { store.setSpeaker(recording.id, start: seg.start, to: n) }
            }
            Button("新增说话人") { store.addSpeaker(recording.id, start: seg.start) }
            if let n = seg.speaker, recording.speakers.indices.contains(n) {
                Divider()
                Button("改名…") { newName = recording.speakers[n]; renaming = n }
                Button("不标记") { store.setSpeaker(recording.id, start: seg.start, to: nil) }
            }
        } label: {
            if let n = seg.speaker, recording.speakers.indices.contains(n) {
                Text(recording.speakers[n]).font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(palette[n % palette.count])
                    .background(palette[n % palette.count].opacity(0.14), in: Capsule())
            } else {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("标记这句是谁说的")
    }

    private func isCurrent(_ seg: Segment) -> Bool {
        guard store.playingID == recording.id else { return true }
        let next = recording.segments.first { $0.start > seg.start }?.start ?? .infinity
        return store.playhead >= seg.start && store.playhead < next
    }
}

/// 文字能不能拖选：逐句听的时候关掉，单击留给「从这句播」。
struct Selectable: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

private struct TranscriptSegmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var focused: Bool
    let text: String
    let clean: Bool
    let commit: (String) -> Void

    init(text: String, clean: Bool, commit: @escaping (String) -> Void) {
        self.text = text
        self.clean = clean
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改这段文字").font(.title2.bold())
            Text(clean ? "修改润色版本" : "修改原文").foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 150)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warm200))
                .accessibilityLabel("修改这段文字")
            Text("只修改这一段，不会加入词库。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存修改") { commit(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == text)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { focused = true }
    }
}

/// 一句话的编辑框：改完按回车或点到别处才提交。
struct SegmentEditor: View {
    @State private var draft: String
    @FocusState private var focused: Bool
    let commit: (String) -> Void

    init(text: String, commit: @escaping (String) -> Void) {
        _draft = State(initialValue: text)
        self.commit = commit
    }

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).lineSpacing(5)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, now in if !now { commit(draft) } }
    }
}

// MARK: - 设备

struct DeviceView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 这一页内容不多：摆在页面正中间，不贴着左上角留一大片空
        GeometryReader { page in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch store.link {
                case .ready: connected
                case .off: ContentUnavailableView("蓝牙没打开", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text("请在菜单栏或系统设置里打开蓝牙。"))
                case .unauthorized: ContentUnavailableView("没有蓝牙权限", systemImage: "lock", description: Text("请到 系统设置 → 隐私与安全性 → 蓝牙 里允许「密盒助手」。"))
                case .connecting: connecting
                case .idle, .scanning: scanner
                }
                // 得到 AI 录音卡：和录音豆各连各的（CardViews.swift）
                CardPanel()
                // 手机 App 把录音同步进飞书后，从飞书拉回来（FeishuPanel.swift）
                FeishuPanel()
                Button("诊断日志") { openWindow(id: "log") }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: page.size.height, alignment: .center)
        }
        }
        .navigationTitle("设备")
    }

    private var connecting: some View {
        Card {
            VStack(spacing: 14) {
                Radar(active: true, found: true)
                Text(store.waitingForKnownDevice ? "正在等「\(store.displayDeviceName)」出现" : "正在连接…").font(.headline)
                Text("确认密盒已开机，放在电脑旁边。\n手机连着它的话，先关掉手机蓝牙。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("取消") { store.disconnect() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var scanner: some View {
        Card {
            let beans = store.found.filter(\.isBean)
            VStack(spacing: 14) {
                Radar(active: store.link == .scanning, found: !beans.isEmpty)
                Text(beans.isEmpty ? (store.link == .scanning ? "正在找附近的密盒" : "连接密盒") : (beans.count == 1 ? "找到了，正在连接…" : "找到 \(beans.count) 台，选一台"))
                    .font(.headline)
                    .contentTransition(.opacity)
                if beans.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", String(localized: "确认密盒已开机"))
                        step("2", String(localized: "放在电脑旁边"))
                        step("3", String(localized: "手机连着它的话，先关掉手机蓝牙"))
                    }
                    .padding(.top, 2)
                }
                ForEach(beans) { device in
                    Button { store.autoConnectAllowed = true; store.connect(device) } label: {
                        HStack {
                            Image(systemName: "mic.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                            Text(device.name).fontWeight(.medium)
                            Spacer()
                            Text("连接").foregroundStyle(Theme.accent)
                        }
                        .padding(10).glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.card)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                Button(store.link == .scanning ? "停止搜索" : "开始搜索") {
                    if store.link == .scanning { store.stopScan() } else { store.autoConnectAllowed = true; store.scan() }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: beans.count)
        }
        .onAppear { if store.link == .idle, store.autoConnectAllowed { store.scan() } }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(n).font(.caption.bold()).frame(width: 20, height: 20).background(.quaternary, in: Circle())
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 已连接：设备照片、电量、存储空间和设备参数。
    @ViewBuilder private var connected: some View {
        VStack(spacing: 22) {
            HStack(spacing: 28) {
                DevicePhotoView()
                    .frame(width: 230, height: 230)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("给它起个名字", text: Bindable(store.settings).deviceAlias, prompt: Text(store.deviceName))
                        .textFieldStyle(.plain).font(.system(size: 34, weight: .bold, design: .rounded))
                        .help("点这里改名。名字只存在这台 Mac 上")
                    HStack(spacing: 7) {
                        Circle().fill(Theme.ok).frame(width: 9, height: 9)
                        Text(store.recState == .recording ? "已连接 · 正在录音" : store.inCase ? "已连接 · 正在充电" : "已连接").font(.title3).foregroundStyle(.secondary)
                    }
                    Button("断开连接") { store.disconnect() }.buttonStyle(.glass).controlSize(.large)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)

            if let info = store.info {
                HStack(spacing: 18) {
                    ring(String(localized: "密盒"), "\(info.micBattery)%", Double(info.micBattery) / 100, note: info.micCharging ? String(localized: "充电中") : nil, warn: info.micBattery < 20)
                    ring(String(localized: "充电盒"), "\(info.caseBattery)%", Double(info.caseBattery) / 100, note: info.caseCharging ? String(localized: "充电中") : nil, warn: info.caseBattery < 20)
                    if info.totalKB > 0 {
                        ring(String(localized: "已用空间"), size(info.usedKB), max(0.004, Double(info.usedKB) / Double(info.totalKB)), note: String(localized: "共 \(size(info.totalKB))"), warn: false)
                    }
                }

                let onDevice = store.recordings.filter(\.onDevice)
                let waiting = onDevice.filter { !$0.downloaded }.count
                // 每秒 8 KB：160 字节一帧、每秒 50 帧
                let hoursLeft = Double(info.freeKB) / 8 / 3600
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 11) {
                        GridRow {
                            fact(String(localized: "密盒里的录音"), String(localized: "\(onDevice.count) 条") + (waiting > 0 ? String(localized: "，\(waiting) 条没下载") : String(localized: "，都已下载")))
                            fact(String(localized: "还能录"), hoursLeft >= 100 ? String(localized: "约 \(Int(hoursLeft)) 小时") : String(format: String(localized: "约 %.1f 小时"), hoursLeft))
                        }
                        GridRow {
                            fact(String(localized: "密盒固件"), info.firmware)
                            fact(String(localized: "充电盒固件"), info.caseFirmware.isEmpty ? "—" : info.caseFirmware)
                        }
                        GridRow {
                            fact(String(localized: "下载加密"), store.encryptionReady ? String(localized: "密钥已协商") : String(localized: "还没协商好，暂时不能下载"), warn: !store.encryptionReady)
                            fact(String(localized: "序列号"), info.serial.uppercased())
                        }
                    }
                    if waiting > 0 {
                        Divider()
                        HStack {
                            Text("有 \(waiting) 条录音还在密盒里。").foregroundStyle(.secondary)
                            Spacer()
                            if store.wifiSyncWorthOffering { Button("Wi‑Fi 快传…") { nav.confirmWiFiSync = true } }
                            Button("全部下载") { store.downloadAll() }.disabled(store.pull != nil || !store.encryptionReady)
                        }
                    }
                }
            } else {
                ProgressView("正在读取设备信息…").controlSize(.small)
            }
        }
    }

    private func ring(_ title: String, _ value: String, _ fraction: Double, note: String?, warn: Bool) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(width: 132, height: 132)
        .background {
            ZStack {
                Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 7)
                // 和「开始录音」按钮同一套渐变：从浅玫瑰沿着圆弧走到深玫红；电量低时换成琥珀到红。
                // 渐变只铺在画出来的那一段弧上，起点往回让 4°，免得起头的圆角吃到末端的深色
                let arc = min(1, fraction)
                Circle().trim(from: 0, to: arc)
                    .stroke(AngularGradient(colors: warn ? [Theme.amber, Theme.rec] : [Theme.roseLight, Theme.rec, Theme.recDeep],
                                            center: .center, startAngle: .degrees(-4), endAngle: .degrees(max(8, 360 * arc - 4))),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.8, dampingFraction: 1), value: fraction)
            }
        }
        .padding(6)
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).foregroundStyle(warn ? Theme.accent : Color.primary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func size(_ kb: UInt32) -> String { ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory) }
}

struct BatteryRow: View {
    let title: String
    let percent: Int
    let charging: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if charging { Image(systemName: "bolt.fill").foregroundStyle(Theme.ok).font(.caption) }
            Text("\(percent)%").monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: icon).foregroundStyle(percent <= 20 ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(.secondary))
        }
    }

    private var icon: String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - 诊断日志

struct LogView: View {
    @Environment(BeanStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .onChange(of: store.log.count) { proxy.scrollTo(store.log.count - 1, anchor: .bottom) }
        }
        .toolbar {
            Button("拷贝全部", systemImage: "doc.on.doc") { copy(store.log.joined(separator: "\n")) }
        }
    }
}

/// 搜索时的雷达波纹：一圈圈往外扩，找到设备后中间的图标亮起来。
struct Radar: View {
    var active: Bool
    var found: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            Circle().strokeBorder(Theme.accent.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(0.35 + phase * 0.65)
                        }
                    }
                }
            }
            Image(systemName: found ? "mic.circle.fill" : "mic.circle")
                .font(.system(size: 44))
                .foregroundStyle(found ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: found)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 150, height: 150)
    }
}

// MARK: - 录好了：留着还是不要

/// 录完一条之后浮出来的小卡片。十秒不理它就默认留着；点了「不要这条」还有五秒可以反悔。
struct KeepCard: View {
    @Environment(BeanStore.self) private var store
    let just: JustRecorded

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: just.discardAt == nil ? "waveform" : "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(just.discardAt == nil ? Theme.accent : Theme.rec)
                    .frame(width: 46, height: 46)
                    .background((just.discardAt == nil ? Theme.accent : Theme.rec).opacity(0.14), in: .rect(cornerRadius: Theme.Radius.card))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(just.discardAt == nil ? "录好了" : "这条不要了").font(.title3.weight(.semibold))
                    Text("\(clock(just.seconds)) · 来自 \(just.from)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(just.discardAt == nil
                 ? (store.settings.autoProcess ? "留着的话，会自动转成文字并整理成纪要。" : "留着的话，它会出现在录音列表里。")
                 : (just.onMac ? "马上从这台 Mac 上删掉，删了找不回来。" : "马上从密盒里删掉，删了找不回来。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if just.discardAt == nil {
                HStack(spacing: 10) {
                    Button("不要这条") { store.discardJustRecorded() }
                        .buttonStyle(.plain).foregroundStyle(Theme.rec).fontWeight(.medium)
                        .frame(maxWidth: .infinity, minHeight: 34).contentShape(.rect)
                    Button { store.keepJustRecorded() } label: { Text("留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 22) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button { store.undoDiscard() } label: { Text("撤销，还是留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 22) }
                    .buttonStyle(.glass).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }

            // 倒计时：一条越走越短的细线，旁边一句话说到点会怎样
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let end = just.discardAt ?? just.deadline
                let total = just.discardAt == nil ? JustRecorded.patience : JustRecorded.regret
                let left = max(0, end.timeIntervalSince(context.date))
                VStack(alignment: .leading, spacing: 6) {
                    Text(just.discardAt == nil ? "\(Int(left.rounded(.up))) 秒后自动留着" : "\(Int(left.rounded(.up))) 秒后删除")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    GeometryReader { geo in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(just.discardAt == nil ? Theme.accent : Theme.rec)
                                    .frame(width: geo.size.width * left / total)
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.ultraThickMaterial, in: .rect(cornerRadius: Theme.Radius.panel))   // 要厚：后面是正文，透出来会跟卡片上的字打架
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: just.discardAt != nil)
    }
}

// MARK: - 项目

/// 「移到项目」菜单里的几项。
struct ProjectMenuItems: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let ids: Set<UInt32>

    var body: some View {
        ForEach(store.projects) { p in
            Button(p.name) { store.move(ids, to: p.id) }
        }
        if !store.projects.isEmpty { Divider() }
        Button("新建项目…") { nav.pendingMove = ids; nav.newProject = true }
        if ids.contains(where: { id in store.recordings.first { $0.id == id }?.project != nil }) {
            Button("移出项目") { store.move(ids, to: nil) }
        }
    }
}

/// 新建、改名、删除项目的弹窗。挂在窗口上，侧栏和列表都能叫出来。
struct ProjectDialogs: ViewModifier {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var name = ""

    func body(content: Content) -> some View {
        @Bindable var nav = nav
        content
            .alert("新建项目", isPresented: $nav.newProject) {
                TextField("项目名", text: $name)
                Button("新建") {
                    if let id = store.createProject(name) {
                        if !nav.pendingMove.isEmpty { store.move(nav.pendingMove, to: id) }
                        else { nav.route = .project(id) }
                    }
                    nav.pendingMove = []; name = ""
                }
                Button("取消", role: .cancel) { nav.pendingMove = []; name = "" }
            } message: {
                Text(nav.pendingMove.isEmpty ? "把相关的录音和素材放在一起，比如一个客户、一次发布、一组选题。" : "建好之后，选中的 \(nav.pendingMove.count) 条会放进去。")
            }
            .alert("重命名项目", isPresented: Binding(get: { nav.renamingProject != nil }, set: { if !$0 { nav.renamingProject = nil } })) {
                TextField("项目名", text: $name)
                Button("好") { if let id = nav.renamingProject { store.renameProject(id, to: name) }; nav.renamingProject = nil; name = "" }
                Button("取消", role: .cancel) { nav.renamingProject = nil; name = "" }
            }
            .onChange(of: nav.renamingProject) { _, id in if let id { name = store.project(id)?.name ?? "" } }
            .confirmationDialog("删除项目「\(store.project(nav.deletingProject)?.name ?? "")」？",
                                isPresented: Binding(get: { nav.deletingProject != nil }, set: { if !$0 { nav.deletingProject = nil } })) {
                Button("删除项目", role: .destructive) {
                    if let id = nav.deletingProject {
                        if nav.route == .project(id) { nav.route = .all }
                        store.deleteProject(id)
                    }
                    nav.deletingProject = nil
                }
            } message: {
                Text("里面的录音和素材都会留着，只是不再归这个项目。")
            }
    }
}

// MARK: - 翻译

/// 点「翻译」弹出来的小面板：译成什么语言、用哪种风格。
struct TranslatePanel: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    let done: () -> Void
    @State private var language = ""
    @State private var style = TranslateStyle.general

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("翻译成").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm500)
                Picker("翻译成", selection: $language) {
                    ForEach(translateLanguages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("风格").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm500)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(TranslateStyle.allCases) { s in
                        Button { style = s } label: {
                            Text(s.name).font(.system(size: 12, weight: style == s ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .foregroundStyle(style == s ? Theme.warm50 : Theme.warm700)
                                .background(style == s ? Theme.warm900 : Theme.warm200.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(style == .custom && store.settings.translatePrompt.isEmpty ? String(localized: "还没写自定义提示词，在设置的「模型」里写。没写的话按通用风格译。") : style.hint)
                    .font(.caption).foregroundStyle(Theme.warm500).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(store.analysisAvailable ? "使用选定的整理模型翻译" : "还没设置分析模型")
                    .font(.caption).foregroundStyle(Theme.warm500)
                Spacer()
                Button("开始翻译") {
                    store.settings.translateTo = language
                    store.settings.translateStyle = style
                    store.translate(recording.id, to: language, style: style)
                    done()
                }
                .buttonStyle(.borderedProminent).disabled(!store.analysisAvailable)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { language = store.settings.translateTo; style = store.settings.translateStyle }
    }
}

// MARK: - 剪贴板里的链接

/// 剪贴板里有一条视频链接时，窗口顶上出一条提示：导入还是忽略。同一条只问一次，已经导入过的不问。
@Observable
final class ClipboardWatch {
    var offer: (url: String, platform: String)?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var asked: Set<String> = []

    /// 豆仓回到前台、或者每隔几秒在前台时看一眼。只在剪贴板变了的时候才读。
    func check(_ store: BeanStore) {
        guard store.settings.watchClipboard else { offer = nil; return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard let text = pb.string(forType: .string), text.count < 2000 else { return }
        // 只认能识别出平台的视频链接；普通网页链接不打扰
        guard let url = LinkTools.urls(in: text).first(where: { LinkTools.platform(of: $0) != "网页视频" }),
              !asked.contains(url),
              store.importedRecording(for: url) == nil,
              !store.linkJobs.contains(where: { $0.url == url }) else { return }
        asked.insert(url)
        offer = (url, LinkTools.platform(of: url))
    }
}

struct ClipboardOffer: View {
    @Environment(BeanStore.self) private var store
    @Environment(ClipboardWatch.self) private var watch
    @Environment(Navigator.self) private var nav

    var body: some View {
        if let offer = watch.offer {
            HStack(spacing: 12) {
                Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28).background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: 1) {
                    Text("剪贴板里有一条\(offer.platform)链接").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warm900)
                    Text(offer.url.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression))
                        .font(.system(size: 11)).foregroundStyle(Theme.warm500).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 260, alignment: .leading)
                Button("导入") {
                    store.importLinks(offer.url)
                    watch.offer = nil
                    nav.route = .materials
                }
                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Button("忽略") { watch.offer = nil }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.warm500)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.warm200, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .task(id: offer.url) {
                // 不理它的话，二十秒后自己收起来
                try? await Task.sleep(for: .seconds(20))
                if watch.offer?.url == offer.url { watch.offer = nil }
            }
        }
    }
}

/// 录音来源的小胶囊：图标 + 两三个字（录音豆 / Mac / 导入…），悬停说明是怎么来的。设计稿 design/ui/ui_source.png。
/// detailed：详情页顶上用，Mac 录的会带上录了哪一路（「Mac · 麦克风」）。
struct SourceBadge: View {
    let recording: Recording
    var detailed = false

    var body: some View {
        let s = recording.recordedOn
        let text = detailed ? ([s.name] + [recording.sourceDetail].compactMap { $0 }).joined(separator: " · ") : s.name
        Label(text, systemImage: s.icon)
            .labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
            .padding(.horizontal, detailed ? 9 : 5).padding(.vertical, detailed ? 4 : 1.5)
            .foregroundStyle(Theme.warm600)
            .background(Theme.warm100, in: .rect(cornerRadius: detailed ? 8 : 4))
            .help(s.help)
            .accessibilityLabel("来源：\(text)")
    }
}
