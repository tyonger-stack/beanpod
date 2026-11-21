import SwiftUI

/// 总览：设备照片与当前状态、待办和最近的录音。
struct HomeView: View {
    @Environment(BeanStore.self) private var store
    var open: (UInt32) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                status
                todos
                recent
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .paper()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 6) {
            DevicePhotoView().frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(.system(size: 38, weight: .bold, design: .rounded))
                Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    /// 有事要人处理的时候才出现：没下载的、没整理的、还没配云端的。
    @ViewBuilder private var status: some View {
        let toDownload = store.recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress }.count
        let toProcess = store.recordings.filter { $0.downloaded && !$0.isAnalyzed && store.stages[$0.id] == nil }.count
        if toDownload > 0 || toProcess > 0 || !store.analysisAvailable || !store.stages.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !store.stages.isEmpty {
                    Label("正在处理 \(store.stages.count) 条录音", systemImage: "gearshape.2").foregroundStyle(.secondary)
                }
                if toDownload > 0 {
                    HStack {
                        Label("密盒里有 \(toDownload) 条还没下载", systemImage: "arrow.down.circle")
                        Spacer()
                        Button("全部下载") { store.downloadAll() }.disabled(store.pull != nil || !store.encryptionReady)
                    }
                }
                if toProcess > 0, store.stages.isEmpty {
                    HStack {
                        Label("\(toProcess) 条还没转写整理", systemImage: "sparkles")
                        Spacer()
                        Button("开始") { store.processAllPending() }
                    }
                }
                if !store.analysisAvailable {
                    Label("还没设置云端模型，出不了纪要。到「设备」页右上角的设置里填一下。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .card()
        }
    }

    @ViewBuilder private var todos: some View {
        let open = store.openTodos
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("接下来要做的")
                ForEach(Array(open.prefix(5)), id: \.todo.id) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Button { store.toggleTodo(item.recording.id, item.todo.id) } label: {
                            Image(systemName: "circle").font(.title3).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        Button { self.open(item.recording.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.todo.text).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                                Text("来自「\(item.recording.displayTitle)」").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    if item.todo.id != open.prefix(5).last?.todo.id { Divider().padding(.leading, 36) }
                }
                if open.count > 5 { Text("还有 \(open.count - 5) 件，在各条录音的纪要里。").font(.caption).foregroundStyle(.tertiary) }
            }
            .card()
        }
    }

    @ViewBuilder private var recent: some View {
        let list = store.recordings.filter { $0.downloaded || $0.onDevice }.prefix(4)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("最近的录音")
            if list.isEmpty {
                Text("还没有录音。点底部中间的红色按钮开始录第一条。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(list)) { rec in
                Button { open(rec.id) } label: { RecordingRow(recording: rec).contentShape(.rect) }
                    .buttonStyle(.plain)
                if rec.id != list.last?.id { Divider().padding(.leading, 52) }
            }
        }
        .card()
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        default: "晚上好"
        }
    }

    private var line: String {
        if store.isRecording { return store.recordingOnMac ? "在听，用的是这台 iPhone 的麦克风。" : "在听，你说。" }
        if let stage = store.stages.values.first {
            switch stage {
            case .transcribing: return "正在把录音变成文字…"
            case .analyzing: return "正在想这是什么场合、该记哪些重点…"
            case .queued: return "马上就来。"
            }
        }
        if store.pull != nil { return "正在从密盒里往外搬录音…" }
        let todo = store.openTodos.count
        if todo > 0 { return "有 \(todo) 件事等你处理" }
        if store.link != .ready { return "密盒没连上。想现在就录，用这台 iPhone 也行。" }
        return "密盒连着，随时可以开始。"
    }
}
