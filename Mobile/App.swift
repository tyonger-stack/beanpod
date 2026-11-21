import SwiftUI

/// 豆仓的 iPhone 版。
///
/// 和 Mac 版共用同一套核心（Shared 文件夹）：蓝牙协议、下载解密、录音库、整理流程、提问。
/// 不一样的只有两处：界面是给手机做的；转写和整理不在本机跑模型，走云端。
@main
struct BeanPodMobileApp: App {
    @State private var store = BeanStore()

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
                .preferredColorScheme(store.settings.appearance.scheme)
        }
    }
}

/// 四个页签，底栏正中间是红色的录音键。录音时整屏换成舞台。
struct RootView: View {
    @Environment(BeanStore.self) private var store
    // 启动参数可以指定一开始在哪一页（-startTab recordings 这样），方便截图检查和以后做快捷方式
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "startTab") ?? "") ?? .home
    @State private var stageOpen = false
    /// 从别处（待办、最近的录音）要打开的那条录音。
    @State private var opening: UInt32?

    enum Tab: String, Hashable { case home, recordings, knowledge, device }

    var body: some View {
        TabView(selection: $tab) {
            // 系统自带的底栏收起来，换成下面自己画的那一条（中间要放录音键）
            SwiftUI.Tab(value: Tab.home) {
                NavigationStack { HomeView(open: open) }.toolbar(.hidden, for: .tabBar)
            }
            SwiftUI.Tab(value: Tab.recordings) {
                RecordingsScreen(opening: $opening).toolbar(.hidden, for: .tabBar)
            }
            SwiftUI.Tab(value: Tab.knowledge) {
                NavigationStack { KnowledgeScreen(open: open) }.toolbar(.hidden, for: .tabBar)
            }
            SwiftUI.Tab(value: Tab.device) {
                NavigationStack { DeviceScreen() }.toolbar(.hidden, for: .tabBar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar(tab: $tab, stageOpen: $stageOpen) }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                if let banner = store.banner {
                    Label(banner.text, systemImage: banner.icon)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(banner.id)
                }
                if let just = store.justRecorded, !stageOpen {
                    KeepCard(just: just).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 6).padding(.horizontal, 16)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.banner)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.justRecorded?.id)
        .fullScreenCover(isPresented: $stageOpen) { StageScreen(isOpen: $stageOpen).environment(store) }
        // 一开始录就上舞台，录完自己收起来
        .onChange(of: store.recState != .idle) { _, recording in stageOpen = recording }
        .task {
            // 只在带着启动参数打开时生效：直接打开某条录音、看一眼舞台或「录好了」卡片
            let d = UserDefaults.standard
            if let id = UInt32(d.string(forKey: "openRecording") ?? "") { open(id) }
            if d.bool(forKey: "previewStage") { stageOpen = true }
            if d.bool(forKey: "previewKeep") { store.offerKeep(id: 0, seconds: 25, from: BeanStore.thisDevice, onMac: true) }
        }
        .alert(store.problem?.title ?? "", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } }),
               presenting: store.problem) { p in
            if let action = p.action {
                Button(action.label) {
                    switch action {
                    case .device: tab = .device
                    case .settings: tab = .device
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
    }

    private func open(_ id: UInt32) {
        opening = id
        tab = .recordings
    }
}

// MARK: - 到处都用的小零件

extension View {
    /// 放内容的底板：和 Mac 版一样，浅色是白纸加很轻的影子，深色是比底色亮一级的石墨。
    func card(radius: CGFloat = 16, padding: CGFloat = 18) -> some View {
        modifier(CardStyle(radius: radius, padding: padding))
    }

    /// 页面的底：暖白纸，深色时是石墨。
    func paper() -> some View { background(Backdrop().ignoresSafeArea()) }
}

private struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warm50, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.02), radius: 2, y: 1)
    }
}

struct Backdrop: View {
    var body: some View { Theme.dynamic(light: (0.976, 0.969, 0.961), dark: (0.110, 0.098, 0.090)) }
}

/// 一组内容的小标题。
struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.warm900) }
}

/// 底栏：左右各两个页签，正中间是红色的录音键——哪一页都在同一个位置，拇指一伸就到。
struct BottomBar: View {
    @Environment(BeanStore.self) private var store
    @Binding var tab: RootView.Tab
    @Binding var stageOpen: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.home, "总览", "house")
            item(.recordings, "录音", "waveform")
            record.frame(maxWidth: .infinity)
            item(.knowledge, "知识库", "square.stack.3d.up")
            item(.device, "设备", "headphones")
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
        .background(Theme.surface.opacity(0.92))
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.warm200) }
    }

    private func item(_ value: RootView.Tab, _ title: String, _ icon: String) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21, weight: tab == value ? .semibold : .regular)).frame(height: 26)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == value ? Theme.accent : Theme.warm500)
            .frame(maxWidth: .infinity).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    /// 红色的录音键。没在录的时候是一个圆；在录的时候里面走着时间，点一下回到舞台。
    private var record: some View {
        Button {
            if store.recState == .idle { store.startRecording() } else { stageOpen = true }
        } label: {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.rec, Theme.recDeep], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 60, height: 60)
                    .shadow(color: Theme.rec.opacity(0.35), radius: 10, y: 4)
                if store.recState == .idle {
                    Circle().fill(.white).frame(width: 20, height: 20)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(clock(store.elapsed(at: context.date))).font(.system(size: 13, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).opacity(store.recState == .paused ? 0.6 : 1)
                    }
                }
            }
            .offset(y: -8)      // 比两边的页签高出一点，一眼能认出来
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.recState == .idle ? "开始录音" : "正在录音，回到录音画面")
    }
}

/// 录完一条之后浮出来的小卡片：留着还是不要。十秒不理它就默认留着；点了「不要这条」还有五秒可以反悔。
struct KeepCard: View {
    @Environment(BeanStore.self) private var store
    let just: JustRecorded

    var body: some View {
        let discarding = just.discardAt != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: discarding ? "trash" : "waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(discarding ? Theme.rec : Theme.accent)
                    .frame(width: 46, height: 46)
                    .background((discarding ? Theme.rec : Theme.accent).opacity(0.14), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(discarding ? "这条不要了" : "录好了").font(.title3.weight(.semibold))
                    Text("\(clock(just.seconds)) · 来自 \(just.from)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(discarding ? (just.onMac ? "马上从这台 iPhone 上删掉，删了找不回来。" : "马上从密盒里删掉，删了找不回来。")
                 : (store.settings.autoProcess ? "留着的话，会自动转成文字并整理成纪要。" : "留着的话，它会出现在录音列表里。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if discarding {
                Button { store.undoDiscard() } label: { Text("撤销，还是留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    Button("不要这条") { store.discardJustRecorded() }
                        .foregroundStyle(Theme.rec).fontWeight(.medium).frame(maxWidth: .infinity, minHeight: 44)
                    Button { store.keepJustRecorded() } label: { Text("留着").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 30) }
                        .buttonStyle(.borderedProminent)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let end = just.discardAt ?? just.deadline
                let total = discarding ? JustRecorded.regret : JustRecorded.patience
                let left = max(0, end.timeIntervalSince(context.date))
                VStack(alignment: .leading, spacing: 6) {
                    Text(discarding ? "\(Int(left.rounded(.up))) 秒后删除" : "\(Int(left.rounded(.up))) 秒后自动留着")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    GeometryReader { geo in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(discarding ? Theme.rec : Theme.accent).frame(width: geo.size.width * left / total)
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(18)
        .background(.thickMaterial, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}

/// 列表里的一行录音：和 Mac 版同一个样子——白色圆角卡片，标题下面一行小信息，右边灰色关键词或项目名。
struct RecordingRow: View {
    @Environment(BeanStore.self) private var store
    let recording: Recording
    var showProject = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: recording.isMaterial ? "play.fill" : (recording.scene ?? .other).icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
                Text(recording.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.warm900)
                    .lineLimit(2).multilineTextAlignment(.leading).padding(.top, 5)
                if store.retitling.contains(recording.id) { ProgressView().controlSize(.mini).padding(.top, 7) }
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    if recording.starred { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
                    let todo = recording.todos.filter { !$0.done }.count
                    if todo > 0 { Label("\(todo)", systemImage: "square").labelStyle(.titleAndIcon) }
                    status
                }
                .font(.caption).foregroundStyle(Theme.warm400).monospacedDigit().padding(.top, 7)
            }
            HStack(spacing: 6) {
                // 来源小胶囊：录音豆 / iPhone / 导入……（和 Mac 版同一套）
                if !recording.isMaterial {
                    let s = recording.recordedOn
                    Label(s.name, systemImage: s.icon).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .foregroundStyle(Theme.warm600).background(Theme.warm100, in: .rect(cornerRadius: 4))
                        .accessibilityLabel("来源：\(s.name)")
                }
                Text(meta).lineLimit(1).monospacedDigit()
                Spacer(minLength: 4)
                if showProject, let p = store.project(recording.project) {
                    Label(p.name, systemImage: "folder").labelStyle(.titleAndIcon).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Theme.warm700).background(Theme.warm200.opacity(0.7), in: .rect(cornerRadius: 4)).fixedSize()
                } else {
                    ViewThatFits(in: .horizontal) { tags(2); tags(1); EmptyView() }
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.warm500)
            .padding(.leading, 40)
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warm200.opacity(0.6), lineWidth: 1))
    }

    private var tint: Color {
        if recording.isMaterial { return Theme.accent }
        return recording.isAnalyzed ? Theme.amber : Theme.warm400
    }

    private func tags(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(shortTags.prefix(count)), id: \.self) { tag in
                Text(tag).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Theme.warm600).background(Theme.warm100, in: .rect(cornerRadius: 4))
            }
        }
    }

    private var shortTags: [String] {
        recording.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty && $0.count <= 6 }
    }

    private var meta: String {
        if recording.isMaterial { return [recording.origin ?? "素材", clock(recording.duration)].joined(separator: " • ") }
        var parts: [String] = []
        if let d = recording.date { parts.append(d.formatted(.dateTime.hour().minute())) }
        if !recording.textOnly { parts.append(clock(recording.duration)) }
        else if recording.recordedOn != .note { parts.append("文字") }
        if let scene = recording.scene { parts.append(scene.name) }
        else if !recording.downloaded { parts.append("还在密盒里") }
        else if recording.transcript == nil { parts.append("还没转成文字") }
        else if !recording.isAnalyzed { parts.append("还没整理") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder private var status: some View {
        if recording.inProgress {
            Image(systemName: "record.circle").foregroundStyle(Theme.rec)
        } else if let pull = store.pull, pull.id == recording.id {
            ProgressView(value: pull.fraction).progressViewStyle(.circular).controlSize(.small)
        } else if store.isQueued(recording.id) {
            Image(systemName: "clock").foregroundStyle(.secondary)
        } else if store.stages[recording.id] != nil {
            ProgressView().controlSize(.small)
        } else if !recording.downloaded {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }
}
