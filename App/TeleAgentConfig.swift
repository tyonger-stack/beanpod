import Foundation

struct TeleAgentConfig {
    let home: URL

    enum ConfigError: LocalizedError {
        case account, switching, format

        var errorDescription: String? {
            switch self {
            case .account: String(localized: "找不到 TeleAgent 当前账号。请先打开 TeleAgent 登录，再完全退出后重试。")
            case .switching: String(localized: "TeleAgent 正在切换账号。请先打开 TeleAgent 完成账号切换，再退出后重试。")
            case .format: String(localized: "TeleAgent 配置含注释或格式不兼容，密盒助手没有改动它。请在 TeleAgent 的 MCP 设置中手动添加 beanpod，命令为 ~/.local/bin/beanpod，参数为 mcp。")
            }
        }
    }

    func configURL() throws -> URL {
        let ownerURL = home.appendingPathComponent(".local/share/TeleAgent/current-owner.json")
        guard let data = try? Data(contentsOf: ownerURL),
              let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.account
        }
        if let pending = owner["pendingOwner"], !(pending is NSNull) { throw ConfigError.switching }
        guard let directory = owner["ownerDir"] as? String,
              directory.hasPrefix("v1_"),
              directory.range(of: "^[A-Za-z0-9._-]{1,131}$", options: .regularExpression) != nil else {
            throw ConfigError.account
        }
        return home.appendingPathComponent(".config/TeleAgent/users/\(directory)/TeleAgent.jsonc")
    }

    private func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["mcp"] == nil || root["mcp"] is [String: Any] else {
            throw ConfigError.format
        }
        return root
    }

    func connected(cli: String) -> Bool? {
        guard let url = try? configURL(), let root = try? read(url) else { return nil }
        guard let server = (root["mcp"] as? [String: Any])?["beanpod"] as? [String: Any] else { return false }
        return server["type"] as? String == "local"
            && server["command"] as? [String] == [cli, "mcp"]
            && server["enabled"] as? Bool != false
    }

    func setConnected(_ connected: Bool, cli: String) throws {
        let url = try configURL()
        var root = try read(url)
        var servers = root["mcp"] as? [String: Any] ?? [:]
        servers["beanpod"] = connected ? ["type": "local", "command": [cli, "mcp"], "enabled": true] : nil
        root["mcp"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let backup = url.deletingLastPathComponent().appendingPathComponent("TeleAgent.backup-by-beanpod-\(UUID().uuidString).jsonc")
        try FileManager.default.copyItem(at: url, to: backup)
        try data.write(to: url, options: .atomic)
    }
}
