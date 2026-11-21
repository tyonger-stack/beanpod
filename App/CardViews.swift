import BeanKit
import SwiftUI

/// 设备页里的「得到录音卡」（设计稿 design/ui/ui_card_device.png）。
/// 卡里的录音在这里列出来：已经在录音库的、正在下载的、还没下载的；可以单条下载、全部下载、从卡上删除。
struct CardPanel: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var deleting: GetSeedFile?

    var body: some View {
        content
            // 打开设备页就找录音卡（不管录音豆连没连着），离开时停下
            .onAppear { store.card.scanBriefly(seconds: 120) }
            .onDisappear { if store.card.link == .scanning { store.card.stopScan() } }
    }

    @ViewBuilder private var content: some View {
        let card = store.card
        switch card.link {
        case .ready: connected(card)
        case .connecting:
            Card {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(card.waitingForKnownCard ? "正在等「\(card.name)」出现" : "正在连接得到录音卡…").font(.callout)
                    Spacer()
                    Button("取消") { card.disconnect() }
                }
            }
        case .off, .unauthorized:
            EmptyView()
        case .idle, .scanning:
            if card.found.isEmpty {
                Text("也支持得到 AI 录音卡：打开卡片，手机上的得到 App 连着的话先关掉手机蓝牙，它会出现在这里。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("附近的得到录音卡").font(.headline)
                        ForEach(card.found) { found in
                            Button { card.connect(found) } label: {
                                HStack {
                                    CardGlyph(size: 28)
                                    Text(found.name).fontWeight(.medium)
                                    Spacer()
                                    Text("连接").foregroundStyle(Theme.accent)
                                }
                                .padding(10).glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.card)).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func connected(_ card: CardSync) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    CardGlyph(size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("得到录音卡").font(.title3.bold())
                        HStack(spacing: 6) {
                            Circle().fill(Theme.ok).frame(width: 7, height: 7)
                            Text("已连接 · \(card.name)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("刷新") { card.refresh() }.disabled(card.listing || card.progress != nil)
                    Button("断开") { card.disconnect() }
                }
                .controlSize(.regular)

                // 三个数，中间用细竖线隔开，各占三分之一
                HStack(spacing: 0) {
                    fact(String(localized: "电量"), card.battery.map { "\($0)%" } ?? "—")
                    Divider().frame(height: 34).padding(.horizontal, 16)
                    fact(String(localized: "剩余空间"), card.freeKB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1024, countStyle: .file) } ?? "—")
                    Divider().frame(height: 34).padding(.horizontal, 16)
                    fact(String(localized: "卡里"), card.listed ? String(localized: "\(card.files.count) 条") + " · " + (card.waiting.isEmpty ? String(localized: "都已下载") : String(localized: "\(card.waiting.count) 条没下载")) : "—")
                }

                Divider()

                if card.files.isEmpty {
                    Group {
                        if card.listing { ProgressView("正在读卡里的录音…").controlSize(.small) }
                        else { Text("卡里没有录音。用得到 App 同步过的录音会被它清掉，所以这里常常是空的。").foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(card.files.enumerated()), id: \.element.name) { i, file in
                            if i > 0 { Divider().opacity(0.5) }
                            row(file, card)
                        }
                    }
                    if !card.waiting.isEmpty {
                        HStack {
                            Spacer()
                            Button("全部下载（\(card.waiting.count) 条）") { card.downloadAll() }
                                .buttonStyle(.glassProminent).controlSize(.large)
                                // 正在下的那条之外，剩下的都已经排上队了才变灰
                                .disabled(card.waiting.allSatisfy { card.isQueued($0) || card.progress?.name == $0.name })
                        }
                    }
                }

                Text("录音卡不能远程开始录音，在卡上按键录，录完连上就会同步过来。从卡上删除不能恢复。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("从录音卡上删掉这条录音？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { file in
            Button("从录音卡删除", role: .destructive) { card.deleteFromCard(file); deleting = nil }
        } message: { file in
            Text(String(localized: "「\(title(file))」会从卡上永久删除，不能恢复。") + (card.isImported(file) ? String(localized: "密盒助手录音库里的那份不受影响。") : String(localized: "它还没下载到密盒助手，删了就没有了。")))
        }
    }

    private func row(_ file: GetSeedFile, _ card: CardSync) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(file)).font(.callout.weight(.medium))
                Text("约 \(minutes(file.estimatedDuration)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = card.progress, p.name == file.name {
                ProgressView(value: p.fraction).tint(Theme.accent).frame(width: 90)
                Text("\(Int(p.fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            } else if card.isQueued(file) {
                Text("排队中").font(.caption).foregroundStyle(.secondary)
            } else if let id = card.importedID(file) {
                Button("已在录音库") { nav.route = .all; nav.selection = id }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("打开这条录音")
            } else {
                Button("下载") { card.download(file) }.controlSize(.small)
            }
            Menu {
                if card.isImported(file) {
                    Button("重新下载") { card.download(file) }.disabled(card.progress != nil)
                }
                Button("从录音卡删除…", role: .destructive) { deleting = file }
                    .disabled(card.progress != nil)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .accessibilityLabel("更多操作：\(title(file))")
        }
        .padding(.vertical, 9)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ file: GetSeedFile) -> String {
        guard let d = file.start ?? file.end else { return file.name }
        return d.formatted(.dateTime.month().day().hour().minute())
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(localized: "\(max(1, Int(seconds.rounded()))) 秒") : String(localized: "\(Int((seconds / 60).rounded())) 分钟")
    }
}

/// 录音卡的小图标：一张横放的扁平卡片（不用任何品牌标志）。
struct CardGlyph: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "rectangle.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Theme.warm500)
            .frame(width: size, height: size)
            .background(Theme.warm400.opacity(0.16), in: .rect(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}
