import SwiftUI

/// 设置。手机上没有本机模型，所以转写和整理都要填一家云端服务；密钥只存在这台手机上。
struct SettingsScreen: View {
    @Environment(BeanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var asrTesting = false
    @State private var asrResult: String?
    @State private var llmTesting = false
    @State private var llmResult: String?
    @State private var models: [String] = []

    var body: some View {
        @Bindable var settings = store.settings
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("模式", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("我的职业", selection: $settings.profession) {
                        ForEach(Profession.allCases) { Text($0.name).tag($0) }
                    }
                } header: { Text("整理方式") } footer: {
                    Text(settings.profession.focus + "\n场景（会议、访谈、销售……）是每条录音自动判断的。")
                }

                Section("录完之后") {
                    Toggle("录完先问一句留不留", isOn: $settings.askKeep)
                    Toggle("自动从密盒下载", isOn: $settings.autoDownload)
                    Toggle("自动转写并整理", isOn: $settings.autoProcess)
                }

                Section {
                    Picker("用哪种", selection: $settings.engine) {
                        ForEach(AppSettings.Engine.available) { Text($0.name).tag($0) }
                    }
                    if settings.engine == .cloud {
                        Picker("服务", selection: Binding(get: { settings.asrBaseURL }, set: { url in
                            settings.asrBaseURL = url
                            if let preset = CloudASR.presets.first(where: { $0.url == url }) { settings.asrModel = preset.model }
                            asrResult = nil
                        })) {
                            Text("未设置").tag("")
                            ForEach(CloudASR.presets, id: \.url) { Text($0.name).tag($0.url) }
                            if !settings.asrBaseURL.isEmpty, !CloudASR.presets.contains(where: { $0.url == settings.asrBaseURL }) {
                                Text("自定义").tag(settings.asrBaseURL)
                            }
                        }
                        TextField("接口地址", text: $settings.asrBaseURL, prompt: Text(verbatim: "https://api.siliconflow.cn/v1"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("模型名", text: $settings.asrModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密钥（API Key）", text: $settings.asrKey)
                        HStack {
                            Button("测试") { testASR() }.disabled(settings.asrConfig == nil || asrTesting)
                            if asrTesting { ProgressView() }
                            if let asrResult { Text(asrResult).font(.footnote).foregroundStyle(.secondary) }
                        }
                    } else {
                        Picker("语言", selection: $settings.language) {
                            ForEach(Transcriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                } header: { Text("转写：把声音变成文字") } footer: {
                    Text(settings.engine == .cloud
                         ? "云端转写更准，也能认更多语言。录音会发给你填的这家服务商；密钥只存在这台手机上。没填的时候，暂时用系统语音识别顶上。"
                         : "系统语音识别不用填任何东西，但长录音和夹杂外语时不如云端准。")
                }

                Section {
                    Picker("服务", selection: Binding(get: { settings.llmBaseURL }, set: { settings.llmBaseURL = $0; models = []; llmResult = nil })) {
                        Text("未设置").tag("")
                        ForEach(AppSettings.presets.filter { !$0.url.contains("127.0.0.1") }, id: \.url) { Text($0.name).tag($0.url) }
                        if !settings.llmBaseURL.isEmpty, !AppSettings.presets.contains(where: { $0.url == settings.llmBaseURL }) {
                            Text("自定义").tag(settings.llmBaseURL)
                        }
                    }
                    TextField("接口地址", text: $settings.llmBaseURL, prompt: Text(verbatim: "https://api.deepseek.com/v1"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        TextField("模型名", text: $settings.llmModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !models.isEmpty {
                            Menu("选择") { ForEach(models, id: \.self) { m in Button(m) { settings.llmModel = m } } }
                        }
                    }
                    SecureField("密钥（API Key）", text: $settings.llmKey)
                    HStack {
                        Button("测试") { testLLM() }.disabled(!settings.llmConfigured || llmTesting)
                        if llmTesting { ProgressView() }
                        if let llmResult { Text(llmResult).font(.footnote).foregroundStyle(.secondary) }
                    }
                } header: { Text("整理：写纪要、回答提问") } footer: {
                    Text("任何兼容 OpenAI 接口的服务都行。文字稿会发给这家服务商，录音本身不会。")
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("这台手机上的录音", value: "\(store.recordings.filter(\.downloaded).count) 条")
                } footer: {
                    Text("手机和 Mac 上的密盒助手现在各存各的，还不会互相同步。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: settings.llmBaseURL + settings.llmKey) {
                guard !settings.llmBaseURL.isEmpty else { return }
                try? await Task.sleep(for: .seconds(0.8))
                guard !Task.isCancelled else { return }
                models = await Analyzer.listModels(baseURL: settings.llmBaseURL, key: settings.llmKey)
            }
        }
        .tint(Theme.accent)
    }

    private func testASR() {
        guard let config = store.settings.asrConfig else { return }
        asrTesting = true; asrResult = nil
        Task {
            defer { asrTesting = false }
            do { try await CloudASR.test(config); asrResult = "可用" }
            catch { asrResult = error.localizedDescription }
        }
    }

    private func testLLM() {
        guard let config = store.cloudConfig else { return }
        llmTesting = true; llmResult = nil
        Task {
            defer { llmTesting = false }
            do {
                let a = try await Analyzer.analyze(
                    transcript: "王总您好，我是小李。这套系统年费三万八，含五个席位。您说预算三万以内，我申请到这个月签可以三万二，再送两个月服务。我周四把合同发您邮箱。",
                    duration: 30, profession: store.settings.profession, fixedScene: nil, config: config)
                store.upgradeRoughNotes()
                llmResult = "可用，标题：\(a.title)"
            } catch {
                llmResult = error.localizedDescription
            }
        }
    }
}
