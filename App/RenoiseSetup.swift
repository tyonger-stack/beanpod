import AppKit
import CryptoKit
import SwiftUI

/// Renoise 是豆仓用来做视频的那一环。这里管三件事：命令行工具装没装、账户登没登、要不要给 AI 助手也装上 Renoise 插件。
/// 安装走 Renoise 官方公开的发布清单，下载后先核对校验值再放进 ~/.local/bin；每一步都要用户自己点。
@Observable
final class RenoiseSetup {
    var installed = false
    var version = ""
    var latest = ""
    var loggedIn = false
    var account = ""
    var balance: Double?
    var claudePlugin: Bool?
    var openclawPlugin: Bool?
    var hasClaude = false
    var hasOpenClaw = false
    var hasCodex = false

    var busy: String?                 // 正在做哪一步，显示在卡片上
    var note: (ok: Bool, text: String)?
    var checking = false

    var ready: Bool { installed && loggedIn }
    var updatable: Bool { installed && !latest.isEmpty && !version.isEmpty && latest != version }

    private static let index = URL(string: "https://download.renoise.ai/cli/latest.json")!
    private static let root = "https://download.renoise.ai/cli"
    private static var target: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/renoise") }
    static let codexCommand = "codex plugin marketplace add ArcoCodes/renoise-plugins-official"

    private static func shell(_ command: String) async -> (ok: Bool, output: String) { await VideoMaker.shell(command) }

    /// 看一遍现状。只读。
    func refresh() async {
        checking = true
        defer { checking = false }
        let v = await Self.shell("command -v renoise >/dev/null 2>&1 && renoise version")
        installed = v.ok
        version = v.output.firstMatch(of: /(\d+\.\d+\.\d+)/).map { String($0.1) } ?? ""
        if installed {
            let s = await Self.shell("renoise auth status --json")
            let obj = VideoMaker.object(s.output)
            loggedIn = obj?["authenticated"] as? Bool ?? false
            let acct = obj?["account"] as? [String: Any]
            account = (acct?["user"] as? [String: Any])?["name"] as? String ?? ""
            balance = (acct?["credit"] as? [String: Any])?["balance"] as? Double
        } else {
            loggedIn = false; account = ""; balance = nil
        }
        let tools = await Self.shell("for c in claude codex openclaw; do command -v $c >/dev/null 2>&1 && echo $c; done").output
        hasClaude = tools.contains("claude"); hasCodex = tools.contains("codex"); hasOpenClaw = tools.contains("openclaw")
        if hasClaude { claudePlugin = (await Self.shell("claude plugin list 2>/dev/null")).output.contains("renoise@") }
        if hasOpenClaw { openclawPlugin = (await Self.shell("openclaw plugins list 2>/dev/null")).output.lowercased().contains("renoise") }
        // 官方最新是哪一版
        if let (data, _) = try? await URLSession.shared.data(from: Self.index),
           let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = m["version"] as? String {
            latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }
    }

    /// 安装或更新命令行工具：读官方清单 → 下对应这台 Mac 的包 → 核对校验值 → 解开 → 放进 ~/.local/bin。
    func install() async {
        busy = String(localized: "正在安装 Renoise…"); note = nil
        defer { busy = nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.index)
            guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any], m["schemaVersion"] as? Int == 1,
                  let tag = m["version"] as? String, tag.wholeMatch(of: /v\d+\.\d+\.\d+/) != nil,
                  let assets = m["assets"] as? [String], let sums = m["checksums"] as? String,
                  ([sums] + assets).allSatisfy({ $0.wholeMatch(of: /[\w.-]+/) != nil }) else { throw Failure(String(localized: "官方的发布清单读不懂。")) }
            var uts = utsname(); uname(&uts)
            let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let arch = machine.contains("arm64") ? ["arm64", "aarch64"] : ["amd64", "x86_64"]
            let picks = assets.filter { n in n.hasSuffix(".tar.gz") && (n.contains("darwin") || n.contains("macos")) && arch.contains { n.contains($0) } }
            guard picks.count == 1, let name = picks.first else { throw Failure(String(localized: "清单里没有适合这台 Mac 的安装包。")) }

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("beanpod-renoise-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let (archive, _) = try await URLSession.shared.data(from: URL(string: "\(Self.root)/\(tag)/\(name)")!)
            let (sumData, _) = try await URLSession.shared.data(from: URL(string: "\(Self.root)/\(tag)/\(sums)")!)
            // 校验值对不上就停：包在路上被改过或者没下全
            let expected = String(decoding: sumData, as: UTF8.self).split(separator: "\n")
                .first { $0.hasSuffix("  \(name)") || $0.hasSuffix(" *\(name)") }?.split(separator: " ").first.map { $0.lowercased() }
            let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected.count == 64, expected == actual else { throw Failure(String(localized: "安装包的校验值对不上，没有安装。换个网络再试。")) }

            let file = work.appendingPathComponent(name)
            try archive.write(to: file)
            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            guard (await Self.shell("/usr/bin/tar -xf '\(file.path)' -C '\(out.path)'")).ok,
                  let binary = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "renoise" }) else { throw Failure(String(localized: "安装包解不开。")) }
            let target = Self.target
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: binary) }
            else { try FileManager.default.moveItem(at: binary, to: target) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            guard (await Self.shell("'\(target.path)' version")).ok else { throw Failure(String(localized: "装上了但运行不起来。")) }
            note = (true, String(localized: "Renoise \(tag) 装好了，在 ~/.local/bin/renoise。下一步是登录。"))
        } catch let f as Failure {
            note = (false, f.text)
        } catch {
            note = (false, String(localized: "没装成：\(error.localizedDescription)"))
        }
        await refresh()
    }

    /// 登录：让 Renoise 自己打开浏览器，用户在网页上点「允许并连接」。豆仓不经手密码和密钥。
    func login() async {
        busy = String(localized: "正在等你在浏览器里登录…"); note = nil
        defer { busy = nil }
        let r = await Self.shell("'\(Self.target.path)' auth login --web --json 2>&1 || renoise auth login --web --json")
        await refresh()
        note = loggedIn ? (true, String(localized: "登录好了。")) : (false, String(localized: "还没登录上：\(VideoMaker.tail(r.output))"))
    }

    func installClaudePlugin() async {
        busy = String(localized: "正在给 Claude Code 装 Renoise 插件…"); note = nil
        defer { busy = nil }
        _ = await Self.shell("claude plugin marketplace add ArcoCodes/renoise-plugins-official")
        let r = await Self.shell("claude plugin install renoise@renoise-plugins-official")
        note = r.ok ? (true, String(localized: "Claude Code 里装好了。新开一个会话，说「用 Renoise 做一条视频」就行。")) : (false, String(localized: "没装成：\(VideoMaker.tail(r.output))"))
        await refresh()
    }

    func installOpenClawPlugin() async {
        busy = String(localized: "正在给 OpenClaw 装 Renoise 插件…"); note = nil
        defer { busy = nil }
        let r = await Self.shell("openclaw plugins install @renoise/plugin")
        note = r.ok ? (true, String(localized: "OpenClaw 里装好了。")) : (false, String(localized: "没装成：\(VideoMaker.tail(r.output))"))
        await refresh()
    }

    private struct Failure: Error { var text: String; init(_ t: String) { text = t } }
}

/// 连接页面上 Renoise 的那张卡：三步，装、登录、（可选）给 AI 助手也装上。
struct RenoiseCard: View {
    @Environment(BeanStore.self) private var store
    @Environment(RenoiseSetup.self) private var renoise

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Renoise · 做视频").font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(renoise.ready ? Theme.ok : Theme.accent).frame(width: 7, height: 7)
                        Text(renoise.ready ? "可以用了" : renoise.installed ? "装好了，还没登录" : "还没安装").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if renoise.busy != nil || renoise.checking { ProgressView().controlSize(.small) }
            }
            Text("密盒助手里「改写」下面的「做成视频」靠它生成数字人口播。它是按积分收费的服务，每次生成前密盒助手都会先报价。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            step(1, String(localized: "安装命令行工具"), renoise.installed ? String(localized: "已安装 \(renoise.version)") + (renoise.updatable ? String(localized: "，官方最新是 \(renoise.latest)") : "") : String(localized: "从 Renoise 官方下载，核对校验值后放进 ~/.local/bin。"),
                 done: renoise.installed) {
                if !renoise.installed { Button("安装") { Task { await renoise.install() } }.buttonStyle(.glassProminent) }
                else if renoise.updatable { Button("更新") { Task { await renoise.install() } } }
            }
            step(2, String(localized: "登录账户"), renoise.loggedIn ? String(localized: "已登录") + (renoise.account.isEmpty ? "" : "：\(renoise.account)") + (renoise.balance.map { String(localized: " · 余额 \(Int($0)) 积分") } ?? "")
                    : String(localized: "会打开浏览器，在网页上点「允许并连接」。密盒助手不经手你的密码。"),
                 done: renoise.loggedIn) {
                if renoise.installed, !renoise.loggedIn { Button("登录") { Task { await renoise.login() } }.buttonStyle(.glassProminent) }
            }
            step(3, String(localized: "给 AI 助手也装上（可选）"), String(localized: "装了之后，在助手里也能直接说「用 Renoise 做一条视频」。"), done: renoise.claudePlugin == true || renoise.openclawPlugin == true) {
                EmptyView()
            }
            HStack(spacing: 8) {
                if renoise.hasClaude {
                    if renoise.claudePlugin == true { Label("Claude Code 已装", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                    else { Button("装到 Claude Code") { Task { await renoise.installClaudePlugin() } } }
                }
                if renoise.hasOpenClaw {
                    if renoise.openclawPlugin == true { Label("OpenClaw 已装", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                    else { Button("装到 OpenClaw") { Task { await renoise.installOpenClawPlugin() } } }
                }
                if renoise.hasCodex {
                    Button("Codex：拷贝安装命令") { copy(RenoiseSetup.codexCommand); renoise.note = (true, String(localized: "命令已拷贝。在终端里运行它，然后重开 Codex，到 Plugins 里装 renoise。")) }
                }
            }
            .font(.callout).padding(.leading, 44)
            .disabled(renoise.busy != nil)

            if let busy = renoise.busy { Text(busy).font(.callout).foregroundStyle(.secondary) }
            if let note = renoise.note {
                Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(note.ok ? Theme.ok : Theme.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .disabled(renoise.busy != nil)
        .task { await renoise.refresh() }
    }

    private func step<Trailing: View>(_ n: Int, _ title: String, _ detail: String, done: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 6)
    }
}
