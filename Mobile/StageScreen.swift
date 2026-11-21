import SwiftUI

/// 录音舞台：录音时盖住整屏，深色。只留四样东西——时间、声音、刚说的那句话、三个按钮。
struct StageScreen: View {
    @Environment(BeanStore.self) private var store
    @Binding var isOpen: Bool

    var body: some View {
        let paused = store.recState == .paused
        ZStack {
            Theme.graphite.ignoresSafeArea()
            RadialGradient(colors: [Theme.rec.opacity(paused ? 0.04 : 0.14), .clear], center: .init(x: 0.85, y: 0.3), startRadius: 0, endRadius: 380)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { isOpen = false } label: {
                        Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 40, height: 40).background(.white.opacity(0.08), in: .circle)
                    }
                    .accessibilityLabel("收起，录音继续")
                    Spacer()
                    HStack(spacing: 8) {
                        Circle().fill(paused ? Color.white.opacity(0.4) : Theme.rec).frame(width: 9, height: 9)
                        Text((paused ? "已暂停 · " : "正在录音 · ") + (store.recordingOnMac ? "这台 iPhone" : store.displayDeviceName))
                            .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer(minLength: 12)
                DevicePhotoView()
                    .frame(width: 230, height: 230)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(store.elapsed(at: context.date)))
                        .font(.system(size: 76, weight: .thin, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(paused ? 0.5 : 1))
                        .contentTransition(.numericText())
                }
                LevelBars(levels: store.liveLevels, paused: paused)
                    .frame(height: 54).padding(.horizontal, 24).padding(.top, 6)
                Text(caption)
                    .font(.title3).foregroundStyle(.white.opacity(store.liveSegments.isEmpty ? 0.45 : 0.92))
                    .multilineTextAlignment(.center).lineLimit(3)
                    .padding(.horizontal, 28).padding(.top, 18)
                    .frame(minHeight: 84, alignment: .top)
                Spacer(minLength: 12)

                HStack(spacing: 44) {
                    round("标重点" + (store.liveMarks.isEmpty ? "" : " · \(store.liveMarks.count)"), icon: "bookmark.fill", tint: Theme.amber) { store.markNow() }
                        .disabled(paused)
                    round(paused ? "继续" : "暂停", icon: paused ? "play.fill" : "pause.fill", tint: .white.opacity(0.7)) {
                        if paused { store.resumeRecording() } else { store.pauseRecording() }
                    }
                    round("结束", icon: "stop.fill", tint: Theme.rec, filled: true) { store.finishRecording() }
                }
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 实时出字要靠本机模型，手机上没有；所以这里说清楚录完会发生什么，而不是空着。
    private var caption: String {
        if let last = store.liveSegments.last { return last.clean ?? last.text }
        return store.settings.autoProcess ? "录完会自动转成文字、整理成纪要。" : "正在录。"
    }

    private func round(_ title: String, icon: String, tint: Color, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                    .foregroundStyle(filled ? .white : tint)
                    .frame(width: 66, height: 66)
                    .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16)), in: .circle)
                Text(title).font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }
}

/// 声波：一排细竖线，最新的在右边、是红色的。
struct LevelBars: View {
    var levels: [Float]
    var paused: Bool

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 5, width: CGFloat = 2.4
            let count = Int(size.width / pitch)
            let shown = Array(levels.suffix(count))
            let pad = count - shown.count
            for i in 0..<count {
                let level = i >= pad ? CGFloat(shown[i - pad]) : 0.02
                let h = max(3, min(1, level) * size.height)
                let rect = CGRect(x: CGFloat(i) * pitch, y: (size.height - h) / 2, width: width, height: h)
                let recent = i >= count - 4 && !paused
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                             with: .color(recent ? Theme.rec : Color.white.opacity(i >= pad ? 0.85 : 0.18)))
            }
        }
        .accessibilityHidden(true)
    }
}
