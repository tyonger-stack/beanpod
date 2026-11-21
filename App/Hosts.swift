import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「做成视频」用的主播：用户自己上传的人像照片，存在用户自己的 Renoise 账号里，豆仓只记素材编号和一张缩略图。
/// 另外内置两位示例主播（AI 生成的虚构人物，图片在 App 包里），第一次用来做视频时才传到用户自己的 Renoise 账号。
struct Host: Codable, Identifiable, Hashable {
    var id: String { sample.map { "sample-\($0)" } ?? material }
    var material: String          // Renoise 素材编号；示例主播还没上传时为空
    var sample: String?           // 示例主播在 App 包里的图片名，比如 sample_office
    var name: String
    var ratio: String             // 照片是竖图就 9:16，横图 16:9
    var face: String?             // Renoise 的人脸审核状态：active 通过；其他值见 faceText
    var faceNote: String?
    var added = Date()

    /// 审核没过时给卡片上显示的一句话；通过了或者查不到就是 nil。
    var faceText: String? {
        switch face {
        case nil, "active": nil
        case "pending", "processing", "reviewing": String(localized: "人脸审核中")
        default: faceNote.map { String(localized: "审核没通过：\($0)") } ?? String(localized: "人脸审核没通过")
        }
    }
    var usable: Bool { face == nil || face == "active" }
    var isSample: Bool { sample != nil }
}

@Observable
final class HostLibrary {
    var hosts: [Host] = []
    var busy = false
    var error: String?

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BeanPod/Hosts", isDirectory: true)
    }
    private static var index: URL { root.appendingPathComponent("hosts.json") }
    static func thumb(_ material: String) -> URL { root.appendingPathComponent("\(material).jpg") }

    /// 内置的两位示例主播（虚构人物）。只在第一次打开时放进主播列表；用户移除后不再回来。
    static let samples = [
        Host(material: "", sample: "sample_office", name: String(localized: "示例 · 职业装"), ratio: "9:16"),
        Host(material: "", sample: "sample_home", name: String(localized: "示例 · 居家"), ratio: "16:9"),
    ]
    static func sampleURL(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: "jpg") }

    /// 卡片上用的图：示例主播读 App 包里的，自己加的读本机缩略图。
    static func image(for host: Host) -> NSImage? {
        if let s = host.sample, let url = sampleURL(s) { return NSImage(contentsOf: url) }
        return NSImage(contentsOf: thumb(host.material))
    }

    init() { load() }

    func load() {
        if let data = try? Data(contentsOf: Self.index) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            hosts = (try? d.decode([Host].self, from: data)) ?? []
        } else {
            hosts = []
        }
        let key = "hostSamplesSeeded"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let missing = Self.samples.filter { s in !hosts.contains { $0.sample == s.sample } }
            hosts.insert(contentsOf: missing, at: 0)
            save()
        }
    }

    /// 示例主播第一次用来做视频时，把 App 包里的图传到用户自己的 Renoise 账号，换成素材编号。不花积分。
    func ensureUploaded(_ host: Host) async -> Host? {
        guard host.material.isEmpty else { return host }
        guard let s = host.sample, let url = Self.sampleURL(s) else { error = String(localized: "示例主播的图片不见了。"); return nil }
        busy = true; error = nil
        defer { busy = false }
        let r = await VideoMaker.shell("renoise upload '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))' --type image --json")
        guard r.ok, let id = Self.materialID(r.output) else {
            error = Self.explain(r.output, fallback: String(localized: "示例主播没传上去"))
            return nil
        }
        var h = host
        h.material = id
        await fillFace(&h)
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = h }
        save()
        return h
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(hosts).write(to: Self.index)
    }

    static func ratio(of image: NSImage) -> String {
        let rep = image.representations.first
        let w = CGFloat(rep?.pixelsWide ?? Int(image.size.width)), h = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
        return w > h ? "16:9" : "9:16"
    }

    /// 存一张最长边 600 的缩略图，卡片上用。
    private static func writeThumb(_ image: NSImage, material: String) {
        let maxSide: CGFloat = 600
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        let out = NSImage(size: size)
        out.lockFocus(); image.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? jpg.write(to: thumb(material))
    }

    /// 上传一张照片到用户的 Renoise 账号，存成主播。不花积分。
    func add(photo: URL, name: String) async -> Bool {
        guard let image = NSImage(contentsOf: photo) else { error = String(localized: "这张图片打不开。"); return false }
        busy = true; error = nil
        defer { busy = false }
        let r = await VideoMaker.shell("renoise upload '\(photo.path.replacingOccurrences(of: "'", with: "'\\''"))' --type image --json")
        guard r.ok, let id = Self.materialID(r.output) else {
            error = Self.explain(r.output, fallback: String(localized: "上传没成功"))
            return false
        }
        Self.writeThumb(image, material: id)
        var host = Host(material: id, name: name, ratio: Self.ratio(of: image))
        await fillFace(&host)
        hosts.removeAll { $0.material == id }
        hosts.append(host)
        save()
        return true
    }

    /// 已经在 Renoise 上传过的人像：填素材编号加进来，缩略图从 Renoise 取。
    func add(material raw: String, name: String) async -> Bool {
        let id = raw.replacingOccurrences(of: "material:", with: "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { error = String(localized: "素材编号应该是一串数字。"); return false }
        busy = true; error = nil
        defer { busy = false }
        guard let m = await Self.material(id) else { error = String(localized: "在你的 Renoise 账号里没找到编号 \(id) 的素材。"); return false }
        guard (m["type"] as? String) == "image" else { error = String(localized: "编号 \(id) 不是图片。"); return false }
        var ratio = "9:16"
        if let meta = (m["metadata"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }),
           let w = VideoMaker.number(meta["width"]), let h = VideoMaker.number(meta["height"]) { ratio = w > h ? "16:9" : "9:16" }
        if let s = m["url"] as? String, let url = URL(string: s),
           let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
            Self.writeThumb(image, material: id)
        }
        var host = Host(material: id, name: name.isEmpty ? (m["name"] as? String ?? String(localized: "主播")) : name, ratio: ratio)
        Self.applyFace(m, to: &host)
        hosts.removeAll { $0.material == id }
        hosts.append(host)
        save()
        return true
    }

    func rename(_ host: Host, to name: String) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }), !name.isEmpty else { return }
        hosts[i].name = name
        save()
    }

    /// 只从豆仓里去掉；Renoise 账号里的素材不动。
    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        if !host.isSample { try? FileManager.default.removeItem(at: Self.thumb(host.material)) }
        save()
    }

    /// 审核还没结果的，重新问一次。
    func refreshFaces() async {
        for i in hosts.indices where !hosts[i].material.isEmpty && (!hosts[i].usable || hosts[i].face == nil) {
            var h = hosts[i]
            await fillFace(&h)
            hosts[i] = h
        }
        save()
    }

    private func fillFace(_ host: inout Host) async {
        if let m = await Self.material(host.material) { Self.applyFace(m, to: &host) }
    }

    private static func applyFace(_ m: [String: Any], to host: inout Host) {
        guard let pass = m["facePass"] as? [String: Any] else { return }
        host.face = pass["status"] as? String
        host.faceNote = pass["errorMessage"] as? String
    }

    private static func material(_ id: String) async -> [String: Any]? {
        let r = await VideoMaker.shell("renoise material --ids \(id) --json")
        guard r.ok, let obj = VideoMaker.object(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (obj["materials"] as? [[String: Any]])?.first
    }

    /// upload 的输出里找素材编号：顶层 id，或者包在 material / materials / data 里。
    nonisolated static func materialID(_ output: String) -> String? {
        let line = output.split(separator: "\n").map(String.init).last { $0.hasPrefix("{") } ?? ""
        guard let obj = VideoMaker.object(line) else { return nil }
        func id(_ d: [String: Any]?) -> String? {
            guard let d else { return nil }
            if let n = VideoMaker.number(d["id"]) { return String(Int(n)) }
            return nil
        }
        return id(obj) ?? id(obj["material"] as? [String: Any]) ?? id((obj["materials"] as? [[String: Any]])?.first)
            ?? id(obj["data"] as? [String: Any])
    }

    private static func explain(_ output: String, fallback: String) -> String {
        let o = output.lowercased()
        if o.contains("command not found") || o.contains("not found: renoise") { return String(localized: "这台 Mac 上还没装 Renoise 命令行。到「连接 AI 助手 → 创作工具」里装上并登录。") }
        if o.contains("auth") || o.contains("401") || o.contains("login") { return String(localized: "Renoise 还没登录。到「连接 AI 助手 → 创作工具」里登录。") }
        return String(localized: "\(fallback)：\(VideoMaker.tail(output))")
    }
}

// MARK: - 界面

/// 一张主播卡片：缩略图 + 名字 + 比例。
struct HostCard: View {
    let host: Host
    let picked: Bool
    var onPick: () -> Void
    var onRename: () -> Void
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.secondary.opacity(0.08))
                    if let img = HostLibrary.image(for: host) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.rectangle").font(.system(size: 30)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 104, height: 128).clipShape(.rect(cornerRadius: Theme.Radius.card))
                .overlay(alignment: .topLeading) {
                    if host.isSample {
                        Text("示例").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .capsule).foregroundStyle(.white).padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let t = host.faceText {
                        Text(t).font(.caption2.weight(.medium)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: .capsule).foregroundStyle(.white).padding(6)
                    }
                }
                VStack(spacing: 2) {
                    Text(host.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(host.ratio).font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 112)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(picked ? 1 : 0.6), in: .rect(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(picked ? Theme.accent : Color.secondary.opacity(0.22), lineWidth: picked ? 2 : 0.5))
            .overlay(alignment: .topTrailing) {
                if picked {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Theme.accent).padding(6)
                } else if hover {
                    menu.padding(6)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { Button("改名…", action: onRename); Button("从密盒助手移除", role: .destructive, action: onRemove) }
        .accessibilityLabel("主播 \(host.name)，\(host.ratio)\(host.isSample ? String(localized: "，示例") : "")\(picked ? String(localized: "，已选中") : "")")
        .accessibilityAction(named: "改名", onRename)
        .accessibilityAction(named: "从密盒助手移除", onRemove)
    }

    private var menu: some View {
        Menu {
            Button("改名…", action: onRename)
            Button("从密盒助手移除", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 20)
                .background(.regularMaterial, in: .capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// 虚线描边的「＋ 添加主播」卡片。
struct AddHostCard: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 26, weight: .light))
                Text("添加主播").font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(width: 124, height: 186)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加主播")
    }
}

/// 还没有主播时的大空卡片。
struct NoHostCard: View {
    var action: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("还没有主播").font(.headline)
            Text("上传一张你自己的照片，就能让「你」来讲这篇稿子").font(.callout).foregroundStyle(.secondary)
            Button("添加主播…", action: action).buttonStyle(.glassProminent).controlSize(.large).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// 「添加主播」弹出单：选照片 → 起名 → 勾授权 → 上传并保存。也可以直接填 Renoise 素材编号。
struct AddHostSheet: View {
    @Environment(HostLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    var onAdded: (Host) -> Void

    @State private var photo: URL?
    @State private var image: NSImage?
    @State private var name = String(localized: "我")
    @State private var consent = false
    @State private var byID = false
    @State private var materialID = ""
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加主播").font(.system(size: 22, weight: .bold, design: .rounded))
            Divider()
            if byID { idForm } else { photoForm }
            if let e = library.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .center) {
                Text(byID ? "只记下编号，不会重新上传。" : "照片会上传到你的 Renoise 账号，作为生成视频的参考，不花积分。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                Button("取消") { library.error = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(byID ? "添加" : "上传并保存") { Task { await save() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave || library.busy)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 600)
    }

    private var canSave: Bool {
        guard consent, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return byID ? !materialID.trimmingCharacters(in: .whitespaces).isEmpty : photo != nil
    }

    private var photoForm: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Color.secondary.opacity(0.07))
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .light))
                            Text("选一张照片\n或拖到这里").font(.callout).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 200, height: 272).clipShape(.rect(cornerRadius: Theme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(dropping ? Theme.accent : Color.secondary.opacity(image == nil ? 0.35 : 0), style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: image == nil ? [5, 4] : [])))
                .contentShape(.rect)
                .onTapGesture(perform: choose)
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in pick(url) } }
                    }
                    return true
                }
                .accessibilityAddTraits(.isButton).accessibilityLabel(image == nil ? "选一张照片" : "换一张照片")
                Button(image == nil ? "选择照片…" : "换一张", action: choose).buttonStyle(.link).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 16) {
                nameField
                HStack {
                    Text("照片方向")
                    Spacer()
                    Text(image.map { HostLibrary.ratio(of: $0) == "9:16" ? String(localized: "竖图 · 适合 9:16") : String(localized: "横图 · 适合 16:9") } ?? "—").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("怎样的照片效果好").font(.callout.weight(.semibold))
                    ForEach([String(localized: "正脸、看得清五官"), String(localized: "光线均匀、没有遮挡"), String(localized: "半身、背景简单")], id: \.self) { t in
                        Label { Text(t).font(.callout) } icon: { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).panel(radius: Theme.Radius.card)
                consentToggle
                Button("已在 Renoise 上传过？填素材编号") { byID = true; library.error = nil }
                    .buttonStyle(.link).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var idForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            nameField
            VStack(alignment: .leading, spacing: 6) {
                Text("Renoise 素材编号")
                TextField("比如 361594", text: $materialID).textFieldStyle(.roundedBorder)
                Text("在 Renoise 网站的素材库里，或者用命令 renoise material 查。必须是你自己账号里的人像图片。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            consentToggle
            Button("改用上传照片") { byID = false; library.error = nil }.buttonStyle(.link).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("名字")
            TextField("比如：我（职业装）", text: $name).textFieldStyle(.roundedBorder)
        }
    }

    private var consentToggle: some View {
        Toggle(isOn: $consent) {
            Text("这是我本人，或者我已获得照片中本人的授权").fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP]
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选一张正脸、光线均匀的半身照")
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }

    private func pick(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { library.error = String(localized: "这张图片打不开。"); return }
        photo = url; image = img; library.error = nil
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        let ok = byID ? await library.add(material: materialID, name: n) : await library.add(photo: photo!, name: n)
        if ok, let h = library.hosts.last { onAdded(h); dismiss() }
    }
}
