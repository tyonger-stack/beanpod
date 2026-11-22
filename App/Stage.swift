import SwiftUI

/// 录音舞台：录音时盖住整个窗口。只留四样东西——时间、声音、刚说的那句话、三个按钮。
struct RecordStage: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 舞台有两种看法：平时只看时间和刚说的那一句；点「全部文字」换成从头到尾的字幕，适合投到屏幕上给大家看。
    @State private var reading = false

    private var paused: Bool { store.recState == .paused }
    private var level: Float { paused ? 0 : (store.liveLevels.suffix(3).max() ?? 0) }

    var body: some View {
        ZStack {
            Theme.graphite.ignoresSafeArea()
            // 一团跟着音量亮暗的暖光，垫在波形后面
            RadialGradient(colors: [(paused ? Theme.paper : Theme.rec).opacity(0.10 + 0.16 * Double(level)), .clear],
                           center: .init(x: 0.82, y: 0.55), startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: level)

            VStack(spacing: 0) {
                top
                if reading {
                    // 全文模式：时间和波形缩成一行，地方让给字
                    HStack(spacing: 18) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(store.elapsed(at: context.date)))
                                .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                                .opacity(paused ? 0.55 : 1)
                        }
                        FlowWave(levels: store.liveLevels, total: store.liveLevelTotal, marks: store.liveMarks,
                                 elapsed: { store.elapsed(at: $0) }, paused: paused, still: reduceMotion)
                            .frame(height: 44)
                    }
                    .padding(.top, 14)
                    transcript
                } else {
                    Spacer(minLength: 12)
                    timer
                    FlowWave(levels: store.liveLevels, total: store.liveLevelTotal, marks: store.liveMarks,
                             elapsed: { store.elapsed(at: $0) }, paused: paused, still: reduceMotion)
                        .frame(height: 120)
                        .padding(.top, 4)
                    caption
                    Spacer(minLength: 12)
                }
                controls
            }
            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 30)
            .animation(.spring(response: 0.45, dampingFraction: 1), value: reading)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.paper)
    }

    private var top: some View {
        HStack(spacing: 10) {
            Circle().fill(paused ? Theme.amber : Theme.rec).frame(width: 9, height: 9)
                .opacity(paused ? 1 : 0.55 + 0.45 * Double(level))
                .animation(.easeOut(duration: 0.25), value: level)
            Text(paused ? "已暂停" : "正在录音").font(.callout.weight(.semibold)).tracking(1.5)
            Text(store.sourceName + (!store.recordingOnMac && !store.xiaomiRecording ? (store.info.map { " · \($0.micBattery)%" } ?? "") : ""))
                .font(.callout).foregroundStyle(Theme.paper.opacity(0.45))
            Spacer()
            Button { nav.stageOpen = false } label: {
                Label("收起", systemImage: "chevron.down").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .help("收起舞台，回到密盒助手。录音不会停（Esc）")
        }
    }

    private var timer: some View {
        HStack(alignment: .center, spacing: 22) {
            if store.xiaomiRecording {
                Image(systemName: "appletvremote.gen4.fill")
                    .font(.system(size: 100, weight: .light)).foregroundStyle(Theme.paper.opacity(0.65))
                    .frame(width: 230, height: 230).accessibilityHidden(true)
            } else {
                DevicePhotoView()
                    .frame(width: 230, height: 230)
                    .accessibilityHidden(true)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let t = store.elapsed(at: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(clock(t.rounded(.down)))
                        .font(.system(size: 132, weight: .ultraLight, design: .rounded)).monospacedDigit()
                    Text(String(format: ".%d", Int(t * 10) % 10))
                        .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.paper.opacity(0.4))
                }
                .opacity(paused ? 0.55 : 1)
                .accessibilityElement().accessibilityLabel("已录时长").accessibilityValue(spokenDuration(t))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var caption: some View {
        Group {
            if let last = store.liveSegments.last {
                VStack(spacing: 8) {
                    Text(store.settings.liveTidy ? stripFillers(last.text) : last.text)
                        .font(.system(size: 26, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        .id(last.id).transition(.opacity.combined(with: .offset(y: 8)))
                    if store.xiaomiRecording {
                        Text(store.xiaomiLiveStatus).font(.callout).foregroundStyle(Theme.paper.opacity(0.55))
                    } else if store.recordingOnMac, let note = store.liveNote {
                        Text(note).font(.callout).foregroundStyle(Theme.paper.opacity(0.55))
                    }
                }
            } else if store.xiaomiRecording {
                Text(store.xiaomiLiveStatus).font(.title3).foregroundStyle(Theme.paper.opacity(0.65))
            } else if let note = store.liveNote {
                Text(note).font(.title3).foregroundStyle(Theme.amber)
            } else if store.recordingOnMac {
                Text("录音结束后会完整转写、整理成纪要。").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            } else if !store.liveActive {
                Text("没开实时转写，这里不出字，声音也画不出来。录音照常在录。").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            } else {
                Text(store.liveLevelTotal == 0 ? "等密盒把声音传过来…" : "在听…").font(.title3).foregroundStyle(Theme.paper.opacity(0.45))
            }
        }
        .frame(maxWidth: 760, minHeight: 64, alignment: .top).frame(maxWidth: .infinity)
        .padding(.top, 20)
        .animation(.easeOut(duration: 0.3), value: store.liveSegments.last?.id)
    }

    /// 从头到尾的字幕：新的一句出现在最下面，自动跟着往下滚。
    private var transcript: some View {
        let size = store.settings.liveFontSize
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: size * 0.7) {
                    ForEach(store.liveSegments) { seg in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(clock(seg.start)).font(.callout.monospacedDigit()).foregroundStyle(Theme.paper.opacity(0.35))
                                .frame(width: 48, alignment: .trailing)
                            Text(store.settings.liveTidy ? stripFillers(seg.text) : seg.text)
                                .font(.system(size: size, weight: .medium)).lineSpacing(size * 0.35)
                                .textSelection(.enabled)
                                .foregroundStyle(seg.id == store.liveSegments.last?.id ? Theme.paper : Theme.paper.opacity(0.6))
                        }
                        .id(seg.id)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    Text(paused ? String(localized: "已暂停") : (store.xiaomiRecording ? store.xiaomiLiveStatus : (store.liveNote ?? String(localized: "在听…")))).font(.title3).foregroundStyle(Theme.paper.opacity(0.4))
                        .padding(.leading, 64).id("tail")
                }
                .padding(.vertical, 22)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.25), value: store.liveSegments.count)
            }
            .onChange(of: store.liveSegments.count) { withAnimation { proxy.scrollTo("tail", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { store.markNow() } label: {
                Label(store.liveMarks.isEmpty ? "标重点" : "标重点 · \(store.liveMarks.count)", systemImage: "flag.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.glass).tint(Theme.amber).controlSize(.extraLarge)
            .disabled(paused)
            .help(store.xiaomiRecording ? "打个重点标记，方便回听（⌘D）" : "这句话很重要：打个标记，回听时一点就到（⌘D）。在密盒上按标记键也一样")

            if !store.xiaomiRecording {
                Button { paused ? store.resumeRecording() : store.pauseRecording() } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill").padding(.horizontal, 10)
                }
                .buttonStyle(.glass).controlSize(.extraLarge)
                .help(paused ? "接着录进同一条（⌘R）" : "先停一下，稍后接着录进同一条（⌘R）")
            }

            Spacer()

            if reading {
                // 全文模式下才用得上的三样：去语气词、字号、拷贝
                Toggle(isOn: Bindable(store.settings).liveTidy) { Label("去语气词", systemImage: "wand.and.stars") }
                    .toggleStyle(.button).buttonStyle(.glass).controlSize(.extraLarge)
                    .help("在字幕里去掉「呃」「嗯」和结巴重复")
                Button { store.settings.liveFontSize = max(14, store.settings.liveFontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    .buttonStyle(.glass).controlSize(.extraLarge).help("字小一点").accessibilityLabel("字小一点")
                Button { store.settings.liveFontSize = min(48, store.settings.liveFontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    .buttonStyle(.glass).controlSize(.extraLarge).help("字大一点").accessibilityLabel("字大一点")
                Button {
                    copy(store.liveSegments.map { store.settings.liveTidy ? stripFillers($0.text) : $0.text }.joined(separator: "\n"))
                    store.toast("doc.on.doc", String(localized: "已拷贝"))
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.glass).controlSize(.extraLarge).help("拷贝到现在为止的全部文字").accessibilityLabel("拷贝全部文字")
            }
            Button { reading.toggle() } label: {
                Label(reading ? "只看当前" : "全部文字", systemImage: reading ? "rectangle.compress.vertical" : "text.alignleft")
            }
            .buttonStyle(.glass).controlSize(.extraLarge)
            .disabled(store.liveSegments.isEmpty && !reading)
            .help(reading ? "回到只看时间和刚说的那一句" : "从头到尾看这次录音出的字，适合投到屏幕上")

            Button { store.finishRecording() } label: {
                Label("结束", systemImage: "stop.fill").padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent).tint(Theme.rec).controlSize(.extraLarge)
            .help(store.xiaomiRecording ? "结束遥控器录音并保存（⌘.），也可松开语音键结束" : "结束这条录音（⌘.）。结束后会自动下载并整理成纪要")
        }
    }
}

/// 流动的声音：细密的竖线从右边长出来，匀速往左流走。
/// 音量每 0.2 秒才到一批，这里自己按时间匀速往前走，所以看上去是连续的，不会一顿一顿。
struct FlowWave: View {
    let levels: [Float]
    let total: Int
    let marks: [TimeInterval]
    let elapsed: (Date) -> TimeInterval
    let paused: Bool
    var still = false
    var color: Color = Theme.paper
    var head: Color = Theme.rec

    /// 画到哪了。放在引用类型里，每一帧接着上一帧往前走。
    private final class Playhead { var position: Double = 0; var last: Date? }
    @State private var playhead = Playhead()

    private let perLevel = 2.0          // 每个音量值画两根线
    private let pitch: CGFloat = 4      // 线和线的间距

    var body: some View {
        TimelineView(.animation(minimumInterval: still ? 0.5 : 1 / 60, paused: false)) { context in
            Canvas { ctx, size in
                let p = advance(to: context.date)
                let mid = size.height / 2
                let right = size.width - 14
                let count = Int(right / pitch) + 2
                let firstIndex = total - levels.count
                let lead = p * perLevel                       // 最右边那根线对应的位置
                let whole = lead.rounded(.down)
                let shift = CGFloat(lead - whole) * pitch     // 不足一根线的那一点位移，流动感就靠它

                for i in 0..<count {
                    let k = whole - Double(i)                 // 这根线在整条声音里是第几根
                    let x = right - CGFloat(i) * pitch - shift
                    guard x > -2 else { break }
                    let at = k / perLevel
                    var amp = CGFloat(level(at, firstIndex))
                    if total == 0 { amp = 0.05 + 0.035 * CGFloat(sin(context.date.timeIntervalSinceReferenceDate * 2 + k * 0.22)) }
                    let h = max(2, amp * size.height * 0.92)
                    let fade = min(1, x / (size.width * 0.35))          // 越往左越淡
                    let fresh = max(0, 1 - CGFloat(i) / 10)             // 刚长出来的几根带一点红
                    let rect = CGRect(x: x - 1, y: mid - h / 2, width: 2, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(Double(fade) * (paused ? 0.35 : 0.9))))
                    if fresh > 0, !paused, total > 0 {
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(head.opacity(Double(fresh) * 0.85)))
                    }
                }

                // 重点标记：一根琥珀色的细线，跟着声音一起往左流
                let now = elapsed(context.date)
                let pxPerSecond = pitch * CGFloat(perLevel) * 10
                for m in marks {
                    let x = right - CGFloat(now - m) * pxPerSecond
                    guard x > 0, x <= right else { continue }
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 6, width: 1.5, height: size.height - 12)), with: .color(Theme.amber))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 2, width: 8, height: 8)), with: .color(Theme.amber))
                }

                // 最右边的一点：声音从这里进来
                let dot = CGRect(x: right + 4, y: mid - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dot), with: .color((paused ? color.opacity(0.4) : head)))
            }
        }
        .accessibilityLabel(paused ? "录音已暂停" : "正在录音的声音波形")
    }

    /// 匀速往前走，每秒 10 个音量值；落后多了就稍微加快追上，永远不超过已经到手的数据。
    private func advance(to date: Date) -> Double {
        let dt = playhead.last.map { min(0.25, max(0, date.timeIntervalSince($0))) } ?? 0
        playhead.last = date
        let target = Double(total)
        if playhead.position > target || target - playhead.position > 40 { playhead.position = max(0, target - 3) }
        guard !paused else { return playhead.position }
        let lag = target - playhead.position
        let rate = 10 * (lag > 5 ? 1 + min(1.5, (lag - 5) / 6) : (lag < 1.5 ? max(0.25, lag / 1.5) : 1))
        playhead.position = min(target, playhead.position + dt * rate)
        return playhead.position
    }

    /// 第 at 个音量值（可以是小数：在相邻两个之间平滑过渡）。
    private func level(_ at: Double, _ firstIndex: Int) -> Float {
        let i = Int(at.rounded(.down)) - firstIndex
        guard i >= 0, i < levels.count else { return 0.02 }
        let a = levels[i], b = i + 1 < levels.count ? levels[i + 1] : a
        let f = Float(at - at.rounded(.down))
        let s = f * f * (3 - 2 * f)
        return max(0.02, a + (b - a) * s)
    }
}
