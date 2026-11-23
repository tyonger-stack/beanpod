import BeanKit
import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    private var week: [Recording] {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        return store.ownRecordings.filter { ($0.date ?? .distantPast) >= from }
    }

    private struct Day: Identifiable { let date: Date; let minutes: Double; var id: Date { date } }

    private var days: [Day] {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        return (0..<14).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let total = store.ownRecordings.filter { $0.date.map { cal.isDate($0, inSameDayAs: day) } ?? false }.reduce(0) { $0 + $1.duration }
            return Day(date: day, minutes: total / 60)
        }
    }

    private var sceneCounts: [(scene: Scene, count: Int, duration: TimeInterval)] {
        Scene.allCases.compactMap { s in
            let items = store.ownRecordings.filter { $0.scene == s }
            return items.isEmpty ? nil : (s, items.count, items.reduce(0) { $0 + $1.duration })
        }.sorted { $0.count > $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Hero()
                Divider().padding(.horizontal, 4)

                pending

                recentAndTodos

                LinkModule()

                // 数字和图表收在最下面，想看再展开：首页先回答「现在该做什么」
                if !store.ownRecordings.isEmpty {
                    RemoteButton { withAnimation(.spring(response: 0.35, dampingFraction: 1)) { showStats.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(showStats ? 90 : 0))
                            Text("\(store.ownRecordings.count) 条录音 · \(hours(store.ownRecordings.reduce(0) { $0 + $1.duration })) · 近 7 天 \(week.count) 条")
                                .monospacedDigit()
                        }
                        .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help(showStats ? "收起统计" : "展开统计")
                }

                if showStats {
                HStack(alignment: .top, spacing: 12) {
                    Card(title: String(localized: "近 14 天录音时长")) {
                        if store.ownRecordings.isEmpty {
                            Text("有了录音之后，这里会显示每天录了多久。").font(.callout).foregroundStyle(.secondary).frame(height: 150)
                        } else {
                            Chart(days) { d in
                                BarMark(x: .value("日期", d.date, unit: .day), y: .value("分钟", d.minutes))
                                    .foregroundStyle(Theme.accent.gradient).cornerRadius(3)
                            }
                            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()); AxisGridLine() } }
                            .chartYAxis { AxisMarks { v in AxisValueLabel { if let m = v.as(Double.self) { Text(m < 10 && m != m.rounded() ? String(format: String(localized: "%.1f 分"), m) : String(localized: "\(Int(m)) 分")) } }; AxisGridLine() } }
                            .frame(height: 150)
                        }
                    }
                    Card(title: String(localized: "场景分布")) {
                        if sceneCounts.isEmpty {
                            Text("录音整理之后会自动归类到会议、访谈、销售等场景。").font(.callout).foregroundStyle(.secondary).frame(height: 150, alignment: .top)
                        } else {
                            VStack(spacing: 8) {
                                let top = sceneCounts.map(\.count).max() ?? 1
                                ForEach(sceneCounts, id: \.scene) { item in
                                    RemoteButton { nav.route = .scene(item.scene) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: item.scene.icon).foregroundStyle(.secondary).frame(width: 18)
                                            Text(item.scene.name).frame(width: 44, alignment: .leading)
                                            GeometryReader { geo in
                                                Capsule().fill(Theme.accent.gradient)
                                                    .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                                                    .frame(maxHeight: .infinity, alignment: .center)
                                            }
                                            .frame(height: 10)
                                            Text("\(item.count) 条 · \(spokenDuration(item.duration))").font(.caption).foregroundStyle(.secondary)
                                                .monospacedDigit().frame(width: 110, alignment: .trailing)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(minHeight: 150, alignment: .top)
                        }
                    }
                }
                }

                if showStats, !store.allTags.isEmpty {
                    Card(title: String(localized: "常出现的话题")) {
                        FlowLayout(spacing: 6) {
                            ForEach(store.allTags.prefix(24), id: \.tag) { item in
                                Text("\(item.tag)  \(item.count)").font(.callout)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("总览")
        .navigationSubtitle("职业：\(store.settings.profession.name)")
    }

    @AppStorage("dashShowStats") private var showStats = false

    private var recentAndTodos: some View {
        HStack(alignment: .top, spacing: 36) {
            // 接下来要做的：最多五件，剩下的去录音页的「有待办」里看
            VStack(alignment: .leading, spacing: 4) {
                Text("接下来要做的").font(.system(size: 20, weight: .semibold, design: .rounded)).padding(.bottom, 8)
                let todos = store.openTodos
                if todos.isEmpty {
                    Text("都做完了。").foregroundStyle(.secondary).padding(.vertical, 10)
                }
                ForEach(Array(todos.prefix(5).enumerated()), id: \.element.todo.id) { n, item in
                    if n > 0 { Divider() }
                    HStack(alignment: .top, spacing: 12) {
                        RemoteButton { store.toggleTodo(item.recording.id, item.todo.id) } label: {
                            Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 20, height: 20).contentShape(Circle())
                        }
                        .buttonStyle(.plain).help("做完了，勾掉").accessibilityLabel("勾掉：\(item.todo.text)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.todo.text).font(.body.weight(.medium)).lineLimit(2)
                            RemoteButton("来自「\(item.recording.displayTitle)」") { nav.open(item.recording.id) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 9)
                }
                if todos.count > 5 {
                    Text("还有 \(todos.count - 5) 件，在录音页的「有待办」里。").font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("最近的录音").font(.system(size: 20, weight: .semibold, design: .rounded)).padding(.bottom, 2)
                if store.ownRecordings.isEmpty {
                    Text("录一段试试，录完会出现在这里。").foregroundStyle(.secondary).padding(.vertical, 10)
                }
                ForEach(store.ownRecordings.prefix(4)) { r in
                    RemoteButton { nav.open(r.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: (r.scene ?? .other).icon).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                                if let s = r.summary { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 6)
                            Text(spokenDuration(r.duration)).font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .panel(radius: Theme.Radius.panel)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 6)
    }

    /// 还有事情没做完时才出现的一栏。
    @ViewBuilder private var pending: some View {
        let toDownload = store.recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.count
        let toProcess = store.recordings.filter { $0.downloaded && !$0.isAnalyzed && !$0.isDictation && store.stages[$0.id] == nil }.count
        let working = store.stages.count
        let rough = store.roughCount
        if toDownload > 0 || toProcess > 0 || working > 0 || !store.analysisAvailable || rough > 0 {
            Card {
                if toDownload > 0 {
                    HStack {
                        Label("密盒里有 \(toDownload) 条录音还没下载", systemImage: "icloud.and.arrow.down")
                        Spacer()
                        if store.wifiSyncWorthOffering { RemoteButton("Wi‑Fi 快传…") { nav.confirmWiFiSync = true } }
                        RemoteButton("全部下载") { store.downloadAll() }.disabled(store.pull != nil || !store.encryptionReady)
                    }
                }
                if toProcess > 0 {
                    HStack {
                        Label("\(toProcess) 条录音还没转写整理", systemImage: "sparkles")
                        Spacer()
                        RemoteButton("全部处理") { store.processAllPending() }
                    }
                }
                if rough > 0, store.analysisAvailable, working == 0 {
                    HStack {
                        Label("\(rough) 条录音只有粗略分类，还没出完整纪要", systemImage: "sparkles")
                        Spacer()
                        RemoteButton("全部整理") { store.upgradeRoughNotes() }
                    }
                }
                if working > 0 {
                    // 每条在哪一步、用了多久、还要多久（ProcessingView.swift）
                    ProcessingList()
                }
                if !store.analysisAvailable {
                    HStack {
                        Label("还没设置分析模型，暂时只能按关键词粗略分类，出不了完整纪要", systemImage: "exclamationmark.circle")
                        Spacer()
                        ModelSettingsLink()
                    }
                }
            }
        }
    }

    private func hours(_ t: TimeInterval) -> String {
        t >= 3600 ? String(format: String(localized: "%.1f 小时"), t / 3600) : String(localized: "\(Int(t / 60)) 分钟")
    }
}

struct Stat: View {
    let title: String, value: String, unit: String, icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// 一行放不下就换行的标签排布。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = fitted(v, bounds.width)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowHeight = max(rowHeight, s.height)
        }
    }

    /// 一个标签自己就比整行还宽时，最多占满一行（文字省略），不撑出边界。
    private func fitted(_ v: LayoutSubview, _ width: CGFloat) -> CGSize {
        let natural = v.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(y: CGFloat, height: CGFloat, width: CGFloat)] {
        var rows: [(y: CGFloat, height: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for v in subviews {
            let s = fitted(v, width)
            if x + s.width > width, x > 0 { rows.append((y, h, x)); y += h + spacing; x = 0; h = 0 }
            x += s.width + spacing; h = max(h, s.height)
        }
        rows.append((y, h, x))
        return rows
    }
}

/// 首页设备照片与当前状态。
struct Hero: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: String(localized: "早上好")
        case 11..<13: String(localized: "中午好")
        case 13..<18: String(localized: "下午好")
        default: String(localized: "晚上好")
        }
    }

    private var line: String {
        if store.isRecording { return store.recordingOnMac ? String(localized: "在听，录的是这台 Mac 的\(store.macSource.name)。") : String(localized: "在听，你说。") }
        // Wi‑Fi 快传时蓝牙是自己主动断开的，别说「没连上」
        if store.wifi != nil { return String(localized: "正在用 Wi‑Fi 把录音搬回来，这一分钟电脑上不了网，马上就好。") }
        if store.link != .ready, store.stages.isEmpty, store.recState == .idle { return String(localized: "密盒未连接。想现在就录，也可以使用这台 Mac。") }
        if store.recState == .paused { return String(localized: "先歇一下。想接着录就点继续，录完了点结束。") }
        if let stage = store.stages.values.first {
            switch stage {
            case .transcribing: return String(localized: "正在把录音变成文字…")
            case .analyzing: return String(localized: "正在想这是什么场合、该记哪些重点…")
            case .queued: return String(localized: "马上就来。")
            }
        }
        if store.pull != nil { return String(localized: "正在从密盒里往外搬录音…") }
        if let info = store.info, store.link == .ready {
            if info.micCharging {
                return info.micBattery >= 95 ? String(localized: "充满了，可以开始录音。") : String(localized: "正在充电，现在 \(info.micBattery)%。")
            }
            if info.micBattery > 0, info.micBattery < 20 { return String(localized: "密盒快没电了，请先充电。") }
        }
        let todos = store.openTodos.count
        if todos > 0 { return String(localized: "有 \(todos) 件事等你处理") }
        return store.recordings.isEmpty ? String(localized: "录一段试试？我来帮你整理。") : String(localized: "随时可以开始，我都记着。")
    }

    var body: some View {
        HStack(spacing: 18) {
            DevicePhotoView()
                .frame(width: 210, height: 210)
                .accessibilityElement().accessibilityLabel("密盒").accessibilityValue(line)
            VStack(alignment: .leading, spacing: 8) {
                Text(greeting).font(.system(size: 44, weight: .bold, design: .rounded))
                Text(line).font(.title2).foregroundStyle(.secondary)
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: line)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if store.link != .ready, store.wifi == nil {
                        RemoteButton { nav.route = .device } label: { Label("连接密盒", systemImage: "antenna.radiowaves.left.and.right").fixedSize() }
                    }
                    RemoteButton { store.chooseFilesToImport() } label: { Label("导入录音", systemImage: "square.and.arrow.down").fixedSize() }
                    if store.recordings.contains(where: \.isAnalyzed) {
                        RemoteButton { nav.route = .knowledge } label: { Label("问问知识库", systemImage: "sparkles").fixedSize() }
                    }
                }
                .buttonStyle(.glass).controlSize(.large)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)

    }
}

/// 首页的「从链接导入」：贴一条视频链接就开始下载、转成文字稿；下面是最近导入的三条素材。
struct LinkModule: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var text = ""

    private var ready: Bool { !LinkTools.urls(in: text).isEmpty }

    var body: some View {
        let recent = Array(store.recordings.filter(\.isMaterial).prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("从链接导入").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.warm900)
                Spacer()
                RemoteButton("查看全部素材") { nav.route = .materials }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warm500)
            }
            HStack(spacing: 8) {
                TextField("粘贴视频链接或分享口令，下载声音、转成文字稿", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit(go)
                RemoteButton(action: go) {
                    Text("导入").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(ready ? Theme.accent : Theme.warm400, in: .rect(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(.plain).disabled(!ready)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(Theme.warm100.opacity(0.7), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))
            Text("支持抖音、B 站、YouTube、TikTok、X 等公开内容。导入后和录音放在一起，可以拆解写法、照结构仿写。")
                .font(.system(size: 11)).foregroundStyle(Theme.warm500)
            if !recent.isEmpty {
                HStack(spacing: 10) {
                    ForEach(recent) { r in
                        RemoteButton { nav.route = .materials; nav.selection = r.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.amber)
                                    .frame(width: 26, height: 26).background(Theme.amber.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.chip))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm900).lineLimit(1)
                                    Text("\(RecordingsView.platform(of: r)) • \(clock(r.duration))").font(.system(size: 11)).foregroundStyle(Theme.warm500)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200.opacity(0.6), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(0..<(3 - recent.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
        .padding(20)
        .background(Theme.warm50, in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.warm200.opacity(0.8), lineWidth: 1))
    }

    private func go() {
        guard ready else { return }
        store.importLinks(text)
        text = ""
    }
}
