import SwiftUI

/// 最近删除（设计稿 design/ui/ui_trash.png）：本机删掉的录音放 7 天，能原样恢复；到期自动彻底删除。
struct TrashView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var confirmEmpty = false
    @State private var forever: TrashedRecording?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最近删除").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.warm900)
                        Text("删掉的录音在这里放 \(TrashedRecording.keepDays) 天，到期自动彻底删除。文字稿、纪要、标签都在，恢复后原样回来。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if !store.trash.isEmpty {
                        RemoteButton("全部清空") { confirmEmpty = true }
                            .buttonStyle(.glass).foregroundStyle(Theme.accent).controlSize(.large)
                    }
                }

                if store.trash.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "trash").font(.system(size: 30)).foregroundStyle(Theme.warm400)
                        Text("最近删除是空的").font(.headline).foregroundStyle(Theme.warm700)
                        Text("从这台 Mac 删除的录音会先放到这里。").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.trash.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { Divider().padding(.leading, 76) }
                            row(entry)
                        }
                    }
                    .padding(.vertical, 6)
                    .panel(radius: Theme.Radius.panel)
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("最近删除")
        .confirmationDialog("彻底删除最近删除里的 \(store.trash.count) 条？", isPresented: $confirmEmpty) {
            Button("全部彻底删除", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("音频、文字稿、纪要会一起删掉，不能恢复。")
        }
        .confirmationDialog("彻底删除这条？", isPresented: Binding(get: { forever != nil }, set: { if !$0 { forever = nil } }), presenting: forever) { entry in
            Button("彻底删除", role: .destructive) { store.deleteForever([entry.id]); forever = nil }
        } message: { entry in
            Text("「\(entry.recording.displayTitle)」的音频、文字稿、纪要会一起删掉，不能恢复。")
        }
    }

    private func row(_ entry: TrashedRecording) -> some View {
        let rec = entry.recording
        let left = entry.daysLeft()
        return HStack(spacing: 14) {
            thumb(entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.displayTitle).font(.body.weight(.semibold)).foregroundStyle(Theme.warm900).lineLimit(1)
                Text(meta(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(left == 0 ? "今天删除" : left == 1 ? "明天删除" : "还剩 \(left) 天")
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(left <= 1 ? Theme.amber : Theme.warm500)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background((left <= 1 ? Theme.amber : Theme.warm400).opacity(0.14), in: .capsule)
                .fixedSize()
            RemoteButton("恢复") {
                store.restore([entry.id])
                store.toast("arrow.uturn.backward", String(localized: "已恢复「\(rec.displayTitle)」"))
            }
            .buttonStyle(.glass).foregroundStyle(Theme.accent).fixedSize()
            Menu {
                Button("恢复并打开") {
                    store.restore([entry.id])
                    nav.route = rec.isMaterial ? .materials : .all
                    nav.selection = rec.id
                }
                Divider()
                Button("彻底删除…", role: .destructive) { forever = entry }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多操作：\(rec.displayTitle)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// 素材有画面的用画面缩略图，其它用波形图标。
    @ViewBuilder private func thumb(_ entry: TrashedRecording) -> some View {
        let jpg = entry.files.first { $0.hasSuffix(".video.jpg") }
        if let jpg, let image = NSImage(contentsOf: store.trashFolder.appendingPathComponent(entry.folder).appendingPathComponent(jpg)) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48).clipShape(.rect(cornerRadius: Theme.Radius.card))
        } else {
            Image(systemName: entry.recording.isMaterial ? "play.rectangle" : entry.recording.textOnly ? "doc.text" : "waveform")
                .font(.system(size: 18)).foregroundStyle(Theme.warm500)
                .frame(width: 48, height: 48).background(Theme.warm100, in: .rect(cornerRadius: Theme.Radius.card))
        }
    }

    private func meta(_ entry: TrashedRecording) -> String {
        let rec = entry.recording
        var parts = [rec.isMaterial ? String(localized: "素材") : rec.origin == "语音输入" ? String(localized: "语音输入") : String(localized: "kind.recording", defaultValue: "录音")]
        if rec.isMaterial { parts.append(RecordingsView.platform(of: rec)) }
        if rec.duration > 0 { parts.append(rec.duration < 60 ? String(localized: "\(Int(rec.duration)) 秒") : String(localized: "\(Int(rec.duration / 60)) 分钟")) }
        parts.append(String(localized: "\(entry.deletedAt.formatted(.dateTime.month().day()))删除"))
        return parts.joined(separator: " · ")
    }
}
