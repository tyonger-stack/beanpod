import SwiftUI

/// 知识库：一个向所有录音提问的入口。问了就答，答案后面跟着出处；不问的时候，下面是最近整理好的录音。
struct KnowledgeScreen: View {
    @Environment(BeanStore.self) private var store
    var open: (UInt32) -> Void
    @State private var question = ""
    @FocusState private var typing: Bool

    private let suggestions = ["最近这几天我都聊了什么？", "我还有哪些答应了别人的事？", "有哪些还没定下来的事？"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问问你的录音").font(.largeTitle.weight(.bold))
                    Text("答案只来自你录过的内容，后面会标出是哪几条。").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                HStack(alignment: .bottom, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).padding(.bottom, 4)
                    TextField("比如：上周和王总谈的价格是多少", text: $question, axis: .vertical)
                        .lineLimit(1...4).focused($typing).submitLabel(.send)
                        .onSubmit(ask)
                    Button(action: ask) {
                        Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(canAsk ? Theme.accent : Color.secondary.opacity(0.4), in: .circle)
                    }
                    .disabled(!canAsk)
                }
                .card(radius: 22, padding: 14)

                if !store.analysisAvailable {
                    Text("提问需要先设置云端模型。到「设备」页右上角的设置里填一下。").font(.footnote).foregroundStyle(.secondary)
                }

                if store.answer == nil, !store.asking {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { question = s; ask() } label: {
                                Text(s).font(.subheadline).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Theme.accent.opacity(0.12), in: .capsule)
                            }
                            .buttonStyle(.plain).disabled(!store.analysisAvailable)
                        }
                    }
                }

                if store.asking {
                    HStack(spacing: 10) { ProgressView(); Text("正在查询你的录音…").foregroundStyle(.secondary) }.card()
                } else if let answer = store.answer {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("已整理好", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.accent)
                        MarkdownView(text: answer)
                        if !store.answerSources.isEmpty {
                            Divider()
                            Text("依据这几条录音").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(store.answerSources.enumerated()), id: \.offset) { n, id in
                                if let rec = store.recordings.first(where: { $0.id == id }) {
                                    Button { open(id) } label: {
                                        HStack(spacing: 8) {
                                            Text("\(n + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                                .frame(width: 20, height: 20).background(Theme.accent, in: .circle)
                                            Text(rec.displayTitle).font(.subheadline).lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        HStack {
                            Button("拷贝", systemImage: "doc.on.doc") { UIPasteboard.general.string = answer }
                            Spacer()
                            Button("清掉", systemImage: "xmark") { store.answer = nil; store.answerSources = []; question = "" }
                        }
                        .font(.subheadline)
                    }
                    .card()
                }

                recent
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .paper()
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private var recent: some View {
        let done = store.recordings.filter(\.isAnalyzed).prefix(6)
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("最近整理好的")
                ForEach(Array(done)) { rec in
                    Button { open(rec.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rec.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                            if let s = rec.summary { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if rec.id != done.last?.id { Divider() }
                }
            }
            .card()
        }
    }

    private var canAsk: Bool {
        store.analysisAvailable && !store.asking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        guard canAsk else { return }
        typing = false
        store.ask(question)
    }
}
