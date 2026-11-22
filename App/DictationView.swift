import AppKit
import SwiftUI

/// 侧栏「语音输入」（设计稿 design/ui/ui_dictation.png）：按住键说过的话，像输入法的历史。
/// 按天分组，每条：时间、说的那句话、打进了哪个软件、几秒；能播放原声、拷贝，「⋯」里转成录音或删除。
struct DictationView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""

    private var items: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = store.dictations.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard !q.isEmpty else { return all }
        return all.filter { ($0.transcript ?? "").localizedCaseInsensitiveContains(q) || ($0.typedInto ?? "").localizedCaseInsensitiveContains(q) }
    }

    /// 按天分组：今天、昨天、其它日期。
    private var groups: [(title: String, items: [Recording])] {
        let cal = Calendar.current
        var out: [(String, [Recording])] = []
        for r in items {
            let d = r.date ?? .distantPast
            let title = cal.isDateInToday(d) ? String(localized: "今天") : cal.isDateInYesterday(d) ? String(localized: "昨天") : d.formatted(.dateTime.month().day().weekday(.abbreviated))
            if out.last?.0 == title { out[out.count - 1].1.append(r) } else { out.append((title, [r])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("语音输入").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.warm900)
                        Text("按住\(Dictation.name(of: store.settings.dictationKey).components(separatedBy: " ").prefix(2).joined(separator: " "))录下所选来源的声音，松开后文字打进当前的软件，同时记在这里。不进录音列表，也不做 AI 整理。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜说过的话", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).accessibilityLabel("清空搜索")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(width: 240)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.warm200, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("声音来源：\(store.sourceName)", systemImage: store.sourceIcon)
                        .font(.callout.weight(.medium))
                    Text("在侧栏的「声音来源」中切换。使用这台 Mac 无需连接密盒；选「电脑里的声音」可转写正在播放的人声。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "keyboard").font(.system(size: 30)).foregroundStyle(Theme.warm400)
                        Text(query.isEmpty ? "还没有语音输入" : "没找到「\(query)」").font(.headline).foregroundStyle(Theme.warm700)
                        Text(query.isEmpty ? (store.settings.dictationEnabled ? "按住快捷键录下所选来源的声音，松开后文字会打进当前的软件，也会记在这里。" : "语音输入还没打开，可以在 设置 → 语音输入 里打开。") : "换个词试试。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.title3.bold()).foregroundStyle(Theme.warm900)
                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { i, r in
                                    if i > 0 { Divider().padding(.leading, 84) }
                                    DictationRow(recording: r)
                                }
                            }
                            .padding(.vertical, 4)
                            .panel(radius: Theme.Radius.panel)
                        }
                    }
                }

                if store.settings.dictationAudioDays > 0, !store.dictations.isEmpty {
                    Text("原声保留 \(store.settings.dictationAudioDays) 天，文字一直留着。可以在设置里改。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("语音输入")
    }
}

private struct DictationRow: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    let recording: Recording

    private var playing: Bool { store.playingID == recording.id && store.isPlaying }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text((recording.date ?? .now).formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Rectangle().fill(Theme.warm200).frame(width: 1, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.transcript ?? "").font(.body).foregroundStyle(Theme.warm900)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if !recording.textOnly {
                    Button { store.togglePlay(recording.id) } label: { Image(systemName: playing ? "pause" : "play") }
                        .help(playing ? "暂停" : "播放原声").accessibilityLabel(playing ? "暂停" : "播放原声")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recording.transcript ?? "", forType: .string)
                    store.toast("doc.on.doc", String(localized: "已拷贝"))
                } label: { Image(systemName: "doc.on.doc") }
                    .help("拷贝这句话").accessibilityLabel("拷贝")
                Menu {
                    Button("转成录音") {
                        store.convertDictationToRecording(recording.id)
                        nav.route = .all; nav.selection = recording.id
                    }
                    .help("挪进录音列表，照常整理成纪要")
                    Divider()
                    Button("删除", role: .destructive) { store.trashWithUndo([recording.id]) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("更多操作")
            }
            .buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.warm500)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var meta: String {
        var parts: [String] = []
        if let app = recording.typedInto, !app.isEmpty { parts.append(String(localized: "打进了 \(app)")) }
        if recording.textOnly { parts.append(String(localized: "原声已清理")) }
        else if recording.duration > 0 { parts.append(String(localized: "\(max(1, Int(recording.duration.rounded()))) 秒")) }
        return parts.isEmpty ? String(localized: "语音输入") : parts.joined(separator: " · ")
    }
}
