import SwiftUI

/// 知识库：所有录音里整理出来的要点汇在一起，可以搜、可以按话题看、可以直接提问。
struct KnowledgeView: View {
    @Environment(BeanStore.self) private var store
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var question = ""
    @State private var filter = BeanStore.SearchFilter()

    /// 上一个问的是什么，显示在回答上面。
    @State private var asked = ""

    private var searching: Bool { !query.isEmpty || !filter.isEmpty }

    /// 几个现成的问题：按这个人自己的录音来出，点一下就问。
    private var suggestions: [String] {
        var out = [String(localized: "最近这几天我都聊了什么？"), String(localized: "我还有哪些答应了别人、还没做的事？")]
        if let tag = store.allTags.first?.tag { out.append(String(localized: "关于「\(tag)」都说过什么？")) }
        if let person = store.allPeople.first { out.append(String(localized: "和\(person)聊过哪些事？")) }
        out.append(String(localized: "有哪些想法还没落实？"))
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                askBox

                if store.recordings.contains(where: \.isAnalyzed) {
                    // 找东西的两条路：按条件收窄，或者点一个话题
                    VStack(alignment: .leading, spacing: 10) {
                        searchFilters
                        if !searching {
                            FlowLayout(spacing: 6) {
                                ForEach(store.allTags.prefix(18), id: \.tag) { item in
                                    chip("# \(item.tag)  \(item.count)", selected: false) { query = item.tag }
                                }
                            }
                        }
                    }
                    if searching { results } else { digest }
                } else {
                    ContentUnavailableView("知识库还是空的", systemImage: "books.vertical",
                                           description: Text("录音转写整理之后会自动进到这里，不用手动添加。到时候直接问就行。"))
                        .padding(.top, 40)
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("知识库")
        .navigationSubtitle(store.recordings.contains(where: \.isAnalyzed) ? "来自 \(store.recordings.filter(\.isAnalyzed).count) 条录音" : "")
        .searchable(text: $query, prompt: "找原话：搜标题、要点和文字稿")
        .toolbar {
            RemoteButton("导出 Markdown", systemImage: "square.and.arrow.up") { store.exportMarkdown(store.recordings.filter(\.isAnalyzed)) }
                .disabled(!store.recordings.contains(where: \.isAnalyzed))
                .help("每条录音导出成一个 Markdown 文件，可以放进 Obsidian 等笔记库")
        }
    }

    private func submit(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, store.analysisAvailable, !store.asking else { return }
        asked = q
        question = ""
        store.ask(q)
    }

    /// 页面的主角：一个提问框。问了之后，回答和依据就出在它下面。
    @ViewBuilder private var askBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                DevicePhotoView().frame(width: 110, height: 110).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("问问你的录音").font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("聊过的事，都有迹可循").font(.title3).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(Theme.accent)
                TextField("比如「上周和王总谈的价格是多少」", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.title3).lineLimit(1...4)
                    .onSubmit { submit(question) }
                    .disabled(!store.analysisAvailable)
                if store.asking { ProgressView().controlSize(.small) }
                RemoteButton { submit(question) } label: { Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 18, height: 18) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || !store.analysisAvailable || store.asking)
                    .help("提问（回车）").accessibilityLabel("提问")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .panel(radius: Theme.Radius.panel)

            if !store.analysisAvailable {
                HStack {
                    Text("提问需要先设置分析模型。").font(.callout).foregroundStyle(.secondary)
                    ModelSettingsLink()
                }
            } else if store.answer == nil, !store.asking {
                // 还没问过：给几个现成的问题，点一下就问
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { q in
                        RemoteButton { submit(q) } label: {
                            Text(q).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.12), in: .capsule)
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if store.asking || store.answer != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if !asked.isEmpty { Text(asked).font(.headline) }
                    if store.asking {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在翻你的录音…").foregroundStyle(.secondary) }
                    } else if let answer = store.answer {
                        Label("已整理好", systemImage: "sparkles").font(.callout).foregroundStyle(Theme.accent)
                        MarkdownView(text: answer)
                        if !store.answerSources.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("依据这几条录音").font(.caption).foregroundStyle(.secondary)
                                FlowLayout(spacing: 6) {
                                    ForEach(Array(store.answerSources.enumerated()), id: \.offset) { n, id in
                                        if let r = store.recordings.first(where: { $0.id == id }) {
                                            RemoteButton { nav.open(id) } label: {
                                                // 前面的编号对应回答里的 [1] [2]
                                                (Text("\(n + 1)  ").foregroundStyle(Theme.accent).fontWeight(.semibold) + Text(r.displayTitle)).font(.callout).lineLimit(1)
                                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                                    .background(.quaternary.opacity(0.6), in: .capsule)
                                            }
                                            .buttonStyle(.plain).help("打开这条录音")
                                        }
                                    }
                                }
                            }
                        }
                        HStack {
                            Text("回答由模型根据上面的录音生成，可能有错，请点开原录音核实。").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            RemoteButton("拷贝") { copy(answer); store.toast("doc.on.doc", String(localized: "已拷贝")) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                            RemoteButton("清掉") { store.answer = nil; store.answerSources = []; asked = "" }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: Theme.Radius.panel)
            }
        }
    }

    /// 没在找东西的时候：按录音一条一条摆，每条是它的摘要，不是拆碎的要点。
    @ViewBuilder private var digest: some View {
        Text("最近整理好的").font(.system(size: 20, weight: .semibold, design: .rounded)).padding(.top, 6)
        // 三张一排的摘要卡
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(store.recordings.filter(\.isAnalyzed).prefix(9)) { r in
                RemoteButton { nav.open(r.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: (r.scene ?? .other).icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text(r.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                        }
                        Text((r.date.map { $0.formatted(.dateTime.month().day()) + " · " } ?? "") + spokenDuration(r.duration))
                            .font(.caption).foregroundStyle(.tertiary)
                        Divider()
                        Text(r.summary ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                    }
                    .padding(14).panel(radius: Theme.Radius.panel).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 一条录音一张卡：标题、时间、摘要；搜索时再带上命中的那几句原话。
    private func recordingCard(_ r: Recording, snippets: [BeanStore.SearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteButton { nav.open(r.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: (r.scene ?? .other).icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: Theme.Radius.card))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text((r.date.map { $0.formatted(.dateTime.month().day().hour().minute()) + " · " } ?? "") + clock(r.duration))
                                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        if let s = r.summary { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(snippets.prefix(3)) { hit in
                RemoteButton {
                    nav.open(hit.recordingID)
                    if let t = hit.time { store.play(hit.recordingID, at: t) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let t = hit.time { Text(clock(t)).font(.caption.monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 40, alignment: .trailing) }
                        else { Image(systemName: "text.quote").font(.caption).foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing) }
                        Text(hit.snippet).font(.callout).multilineTextAlignment(.leading).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(hit.time == nil ? "打开这条录音" : "从这一句开始听")
            }
            if snippets.count > 3 { Text("这条里还有 \(snippets.count - 3) 处").font(.caption).foregroundStyle(.tertiary).padding(.leading, 48) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: Theme.Radius.panel)
    }

    /// 搜索时的收窄条件：时间、场景、人物。
    private var searchFilters: some View {
        HStack(spacing: 10) {
            Picker("时间", selection: $filter.days) {
                Text("全部时间").tag(Int?.none)
                Text("今天").tag(Int?.some(0))
                Text("近 7 天").tag(Int?.some(7))
                Text("近 30 天").tag(Int?.some(30))
                Text("近 90 天").tag(Int?.some(90))
            }
            Picker("场景", selection: $filter.scene) {
                Text("全部场景").tag(Scene?.none)
                ForEach(Scene.allCases) { Text($0.name).tag(Scene?.some($0)) }
            }
            Picker("人物", selection: $filter.person) {
                Text("全部人物").tag(String?.none)
                ForEach(store.allPeople, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .disabled(store.allPeople.isEmpty)
            if !filter.isEmpty { RemoteButton("清除") { filter = .init() }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
            Spacer()
        }
        .labelsHidden().fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ text: String, selected: Bool, color: Color = Theme.accent, action: @escaping () -> Void) -> some View {
        RemoteButton(action: action) {
            Text(text).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? .white : .primary)
                .glassEffect(selected ? .regular.tint(color).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// 搜索结果：命中的句子按录音归到一起，一条录音一张卡。
    @ViewBuilder private var results: some View {
        let hits = store.search(query, filter: filter)
        if hits.isEmpty {
            ContentUnavailableView("没有符合条件的录音", systemImage: "magnifyingglass", description: Text("换个关键词，或者放宽时间、场景、人物的筛选。也可以直接在上面提问。"))
        } else {
            let order = hits.reduce(into: [UInt32]()) { if !$0.contains($1.recordingID) { $0.append($1.recordingID) } }
            HStack {
                Text(query.isEmpty ? "符合条件的 \(order.count) 条录音" : "「\(query)」出现在 \(order.count) 条录音里").font(.headline)
                Spacer()
                if !query.isEmpty, store.analysisAvailable {
                    RemoteButton("让 AI 总结这些") { submit(String(localized: "关于「\(query)」都说过什么？")) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                if !query.isEmpty { RemoteButton("清除") { query = "" }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.top, 4)
            LazyVStack(spacing: 10) {
                ForEach(order.prefix(30), id: \.self) { id in
                    if let r = store.recordings.first(where: { $0.id == id }) {
                        recordingCard(r, snippets: query.isEmpty ? [] : hits.filter { $0.recordingID == id })
                    }
                }
            }
        }
    }
}
