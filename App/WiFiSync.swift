import BeanKit
import Foundation
import Network

/// Wi‑Fi 快传：让录音豆开一个热点，这台 Mac 连上去，把录音一口气拉下来，比蓝牙快十倍左右。
/// 代价是 Mac 要离开原来的 Wi‑Fi 大约一分钟，所以只在用户点了之后才走这条路。
///
/// 流程（协议见 docs/PROTOCOL.md 第 6 节）：蓝牙发 1A 05 → 录音豆回地址 → 断开蓝牙 →
/// 加入热点 → wss 连接 → 逐条要文件 → FINISH → 回到原来的 Wi‑Fi → 蓝牙连回。
/// 中间任何一步失败，都要把 Wi‑Fi 和蓝牙恢复回来，没传完的交给蓝牙接着下。
extension BeanStore {
    /// 现在能用快传去拉的录音：在录音豆里、还没下载、不是正在录的那条。
    var wifiCandidates: [Recording] {
        let open = sessionOpen ? currentDeviceFile : 0
        return recordings.filter { $0.onDevice && !$0.downloaded && !$0.inProgress && $0.id != open }
    }

    var canWiFiSync: Bool {
        link == .ready && encryptionReady && wifi == nil && recState == .idle && macRec == .off && !wifiCandidates.isEmpty
    }

    /// 值不值得把快传摆到用户面前：切网络有四十秒左右的固定开销，攒够五分钟的录音（蓝牙要一分二十秒以上）才划算。
    var wifiSyncWorthOffering: Bool {
        canWiFiSync && wifiCandidates.reduce(0) { $0 + $1.duration } >= 300
    }

    /// 给确认框用的两句话：一共多少、两种方式各要多久。
    var wifiSyncEstimate: String {
        let list = wifiCandidates
        let seconds = list.reduce(0) { $0 + $1.duration }
        let ble = seconds / 3.7, wifi = 40 + seconds / 50
        func about(_ t: Double) -> String { t < 90 ? String(localized: "\(max(1, Int((t / 10).rounded())) * 10) 秒左右") : String(localized: "\(Int((t / 60).rounded())) 分钟左右") }
        return String(localized: "\(list.count) 条录音，一共 \(clock(seconds))。蓝牙要 \(about(ble))，Wi‑Fi 快传 \(about(wifi))。")
    }

    func startWiFiSync() {
        guard canWiFiSync else { return }
        let ids = wifiCandidates.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }.map(\.id)
        wifi = WiFiSync(total: ids.count, waiting: ids)
        Task { await runWiFiSync(ids) }
    }

    private func runWiFiSync(_ ids: [UInt32]) async {
        let started = Date.now
        func note(_ s: String) { addLog("[Wi‑Fi 快传] \(String(format: "%5.1f", Date.now.timeIntervalSince(started)))  \(s)") }
        var stored: [UInt32] = []
        var failure: String?

        // 蓝牙正在传的先停下，让录音豆缓一缓
        if haltBLEDownloads() { try? await Task.sleep(for: .seconds(1.5)) }

        // 1. 蓝牙：让录音豆开热点
        let dev = await Self.wifiDevice()
        let routerBefore = await Self.router(dev)
        let ms = Int(Date.now.timeIntervalSince1970 * 1000)
        let ssid = "WiFi-\(ms)", password = "\(ms)"
        wifiReply = nil
        send(Command.wifiConfig(ssid: ssid, password: password))
        note("开始：\(ids.count) 条，接口 \(dev)，原来的网关 \(routerBefore.isEmpty ? "读不到" : routerBefore)")
        var waited = 0.0
        while wifiReply == nil, waited < 15, link == .ready { try? await Task.sleep(for: .milliseconds(100)); waited += 0.1 }
        guard let r = wifiReply?.raw, r[4] & 0x0F == 1, r.count >= 15 else {
            note("密盒没有打开 Wi‑Fi：\(wifiReply.map { $0.raw.hex } ?? "没有回包")")
            wifi = nil
            problem = Problem(title: String(localized: "密盒没能打开 Wi‑Fi"), detail: String(localized: "这次改用蓝牙下载。可以把密盒放在电脑旁边，确认连接后再试。"))
            ids.forEach { download($0) }
            return
        }
        let ip = "\(r[12]).\(r[11]).\(r[10]).\(r[9])"
        let port = Int(r[13]) | (Int(r[14]) << 8)
        note("密盒的地址 \(ip):\(port)")

        // 从这里开始动了网络：后面无论如何都要走到「恢复」
        let session = sessionCrypto
        dropBLEForWiFi()
        wifi?.phase = .joining
        try? await Task.sleep(for: .seconds(6))

        // 2. 加入热点
        var joined = false
        for attempt in 1...8 {
            let (code, out) = await Self.run("/usr/sbin/networksetup", ["-setairportnetwork", dev, ssid, password], timeout: 25)
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            note("第 \(attempt) 次加入热点：\(code == 0 && text.isEmpty ? "成功" : "退出码 \(code) \(text)")")
            if code == 0, text.isEmpty { joined = true; break }
            try? await Task.sleep(for: .seconds(3))
        }
        if joined {
            for _ in 0..<20 {
                let addr = await Self.run("/usr/sbin/ipconfig", ["getifaddr", dev]).1.trimmingCharacters(in: .whitespacesAndNewlines)
                let gw = await Self.router(dev)
                if !addr.isEmpty, gw != routerBefore || routerBefore.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // 3. 逐条拉
            wifi?.phase = .connecting
            (failure, stored) = await pullAll(ids, ip: ip, port: port, session: session, note: note)
        } else {
            failure = String(localized: "这台 Mac 没能连上密盒的 Wi‑Fi")
        }

        // 4. 恢复 Wi‑Fi 和蓝牙
        wifi?.phase = .closing
        pull = nil
        let back = await restoreWiFi(dev: dev, routerBefore: routerBefore, note: note)
        _ = await Self.run("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", dev, ssid])
        let left = ids.filter { !stored.contains($0) }
        wifiFallback = !left.isEmpty
        wifi = nil
        // 蓝牙这会儿还没连回来：和平时断开一样，先把「在录音豆里」的状态收掉，连上后会重新列出来
        for i in recordings.indices { recordings[i].onDevice = false }
        recordings.removeAll { !$0.downloaded }
        resumeBLEAfterWiFi()
        let seconds = Int(Date.now.timeIntervalSince(started))
        note("结束：存下 \(stored.count) / \(ids.count) 条，全程 \(seconds) 秒，\(back ? "已连回原来的 Wi‑Fi" : "没能确认连回原来的 Wi‑Fi")\(failure.map { "，\($0)" } ?? "")")

        // 网络回来了，再去转写整理（云端模型这时才连得上）
        if settings.autoProcess { stored.forEach { process($0) } }

        if !back {
            problem = Problem(title: String(localized: "没能自动连回原来的 Wi‑Fi"), detail: String(localized: "请在菜单栏的 Wi‑Fi 图标里手动选一下原来的网络。") + (stored.isEmpty ? "" : "\n" + String(localized: "录音已经传回来 \(stored.count) 条。")))
        } else if let failure, !left.isEmpty {
            problem = Problem(title: String(localized: "Wi‑Fi 快传没有全部传完"), detail: String(localized: "\(failure)。传回来 \(stored.count) 条，剩下的 \(left.count) 条等蓝牙连上后接着下。"))
        } else {
            toast("checkmark.circle.fill", String(localized: "Wi‑Fi 快传完成：\(stored.count) 条，用了 \(seconds) 秒"))
        }
    }

    /// 在已经连上的热点里把这几条逐个拉下来。返回（没全部成功时的原因，存下来的那几条）。
    private func pullAll(_ ids: [UInt32], ip: String, port: Int, session: CryptoSession,
                         note: (String) -> Void) async -> (String?, [UInt32]) {
        var stored: [UInt32] = []
        var socket: WiFiSocket?
        let pinger = WiFiPinger(host: ip)
        pinger.start()
        defer { pinger.stop() }
        /// 收尾：告诉录音豆传完了，给它半秒把话收下，再关连接。
        func finish(_ reason: String?) async -> (String?, [UInt32]) {
            socket?.sendText("FINISH")
            try? await Task.sleep(for: .milliseconds(500))
            socket?.close()
            return (reason, stored)
        }
        func connect() async -> String? {
            socket?.close()
            socket = nil
            // 实测录音豆只接受 wss。刚加入热点、或者刚断开上一条连接时，它的服务可能要过几秒才肯接，所以短超时多试几次
            var err: String?
            for attempt in 1...5 {
                let t = Date.now
                let s = WiFiSocket()
                err = await s.connect(host: ip, port: port, tls: true, timeout: 4)
                note("第 \(attempt) 次连接：\(err ?? "连上了")，用了 \(String(format: "%.1f", Date.now.timeIntervalSince(t))) 秒")
                if err == nil { socket = s; return nil }
                s.close()
                try? await Task.sleep(for: .milliseconds(500))
            }
            return err
        }
        if let err = await connect() { return (String(localized: "连不上密盒（\(err)）"), stored) }
        // 只用于自测断线续传：收到这么多个切片后故意把连接掐断一次
        var testCut = UserDefaults.standard.integer(forKey: "wifiDebugCutAfterSlices")

        // 只用于自测长时间会话：要下一条之前先干等这么多秒
        let testPause = UserDefaults.standard.integer(forKey: "wifiDebugPauseBeforeNext")

        for (n, id) in ids.enumerated() {
            if n > 0, testPause > 0 {
                note("（自测）等 \(testPause) 秒再要下一条")
                try? await Task.sleep(for: .seconds(testPause))
            }
            wifi?.phase = .transferring
            wifi?.index = n + 1
            wifi?.waiting = Array(ids[(n + 1)...])
            let expectedGuess = recordings.first { $0.id == id }.map { Int($0.size) } ?? 0
            pull = PullProgress(id: id, received: 0, expected: expectedGuess)

            var data = Data()
            var marks: Set<UInt32> = []
            var expected = 0
            var lastShown = Date.distantPast
            var reconnects = 0
            var done = false
            var skip = false
            let t0 = Date.now

            attempt: while !done, !skip {
                guard let s = socket else { return (String(localized: "连接断了"), stored) }
                var decryptor: FileDecryptor?
                var buffer: [UInt8] = []
                var cut: String?
                var headSeen = false
                let asked = Date.now
                let frames = data.count / OggOpus.frameSize
                s.setIdleLimit(10)
                s.sendText(Command.wifiPullText(id, offset: UInt32(frames * 166)))
                receive: while true {
                    switch await s.next() {
                    case .text(let t): note("\(id)：收到文本 \(t.prefix(60))")
                    case .closed(let why): cut = why; break receive
                    case .binary(let chunk):
                        buffer.append(contentsOf: chunk)
                        for p in WiFiFrame.split(&buffer) {
                            switch (p.type, p.id) {
                            case (0x1A, 0x07):
                                let code = p.raw.count > 95 ? p.raw[95] : 0xFF
                                let headID = p.raw.count >= 13 ? p.raw.u32le(9) : 0
                                note("\(id)：文件头到了（等了 \(String(format: "%.1f", Date.now.timeIntervalSince(asked))) 秒），长 \(p.raw.count)，结果码 \(code)，文件编号\(headID == id ? "对得上" : "是 \(headID)，不是这一条")")
                                guard headID == id else { continue }
                                headSeen = true
                                if code == 1 || code == 2 { note("\(id)：密盒说这个文件不在了或读不了（\(code)）"); skip = true; break receive }
                                if let head = FileHead(packet: p) {
                                    expected = head.audioBytes ?? expected
                                    decryptor = session.fileDecryptor(head: head)
                                }
                                if decryptor == nil { note("\(id)：文件密钥没解开"); skip = true; break receive }
                            case (0x1A, 0x08), (0x1A, 0x12):
                                guard headSeen else { continue }   // 上一条留下的尾巴
                                for slice in Slice.parse(p) {
                                    if slice.marked { marks.insert(slice.sequence) }
                                    let plain = decryptor?.decrypt(slice.data, sequence: slice.sequence) ?? slice.data
                                    guard slice.offset < 512 * 1024 * 1024 else { continue }
                                    if slice.offset > data.count { data.append(Data(count: slice.offset - data.count)) }
                                    if slice.offset == data.count { data.append(contentsOf: plain) }
                                    else { data.replaceSubrange(slice.offset..<min(slice.offset + plain.count, data.count), with: plain.prefix(data.count - slice.offset)) }
                                }
                                // 进度一秒最多刷四次：每刷一次整个窗口要重画，逐条消息刷会把接收拖慢十倍（实测 6 秒变 40 秒）
                                if Date.now.timeIntervalSince(lastShown) > 0.25 {
                                    lastShown = .now
                                    pull = PullProgress(id: id, received: data.count, expected: expected)
                                }
                                if testCut > 0, data.count / OggOpus.frameSize >= testCut {
                                    testCut = 0
                                    note("（自测）故意掐断连接，已收 \(data.count / OggOpus.frameSize) 个切片")
                                    cut = "自测掐断"; break receive
                                }
                            case (0x1A, 0x0A):
                                // 「传完」里带着文件编号（第 14–17 字节）。不是这一条的、或者文件头还没到就来的，是上一条的回声，不理它
                                let doneID = p.raw.count >= 18 ? p.raw.u32le(14) : id
                                note("\(id)：收到「传完」：\(p.raw.hex)")
                                guard headSeen, doneID == id else { continue }
                                done = true
                                s.setIdleLimit(0)   // 存文件要花点时间，别把这段空档当成断线
                                s.sendText(Command.wifiDoneText())
                                break receive
                            case (0x1A, 0x06):
                                return await finish(String(localized: "密盒开始录音了，快传中止"))
                            default:
                                note("\(id)：其他帧 \(p.raw.prefix(20).hex)（长 \(p.raw.count)）")
                            }
                        }
                    }
                }
                if done || skip { break attempt }
                // 连接断了：重连，从已经收到的地方接着要
                reconnects += 1
                note("\(id)：连接断了（\(cut ?? "未知")），已收 \(data.count) / \(expected) 字节，第 \(reconnects) 次重连")
                guard reconnects <= 2 else { return await finish(String(localized: "连接反复中断")) }
                // 末尾可能是半截，退回到整帧
                data = data.prefix(data.count / OggOpus.frameSize * OggOpus.frameSize)
                if let err = await connect() { return (String(localized: "重连不上密盒（\(err)）"), stored) }
            }
            if skip { continue }

            let complete = expected == 0 || Double(data.count) >= Double(expected) * 0.98
            note("\(id)：\(data.count) / \(expected) 字节，\(String(format: "%.1f", Date.now.timeIntervalSince(t0))) 秒，重连 \(reconnects) 次\(complete ? "" : "，不完整")")
            if complete, storeAudio(id: id, data: data, sliceMarks: marks, processNow: false) { stored.append(id) }
            pull = nil
            // 官方客户端在两条之间停 0.6 秒
            try? await Task.sleep(for: .milliseconds(600))
        }
        return await finish(stored.count == ids.count ? nil : String(localized: "有 \(ids.count - stored.count) 条没传下来"))
    }

    /// 回到原来的 Wi‑Fi。先等系统自己连回去；不行就把 Wi‑Fi 关了再开，让系统重新选网络。
    private func restoreWiFi(dev: String, routerBefore: String, note: (String) -> Void) async -> Bool {
        func isBack() async -> Bool {
            let gw = await Self.router(dev)
            return !gw.isEmpty && (routerBefore.isEmpty || gw == routerBefore)
        }
        for _ in 0..<14 {
            if await isBack() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        note("14 秒没连回去，把 Wi‑Fi 关了再开")
        _ = await Self.run("/usr/sbin/networksetup", ["-setairportpower", dev, "off"])
        try? await Task.sleep(for: .seconds(2))
        _ = await Self.run("/usr/sbin/networksetup", ["-setairportpower", dev, "on"])
        for _ in 0..<40 {
            if await isBack() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: 小工具

    nonisolated static func run(_ path: String, _ args: [String], timeout: Double = 15) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            return (p.terminationStatus, String(decoding: out, as: UTF8.self))
        }.value
    }

    nonisolated static func wifiDevice() async -> String {
        let out = await run("/usr/sbin/networksetup", ["-listallhardwareports"]).1
        let lines = out.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains("Hardware Port: Wi-Fi") }), i + 1 < lines.count,
           let name = lines[i + 1].components(separatedBy: ": ").last, !name.isEmpty { return name }
        return "en0"
    }

    nonisolated static func router(_ dev: String) async -> String {
        await run("/usr/sbin/ipconfig", ["getoption", dev, "router"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 一条到录音豆热点的 WebSocket。只走 Wi‑Fi 接口、不走系统代理。
nonisolated final class WiFiSocket: @unchecked Sendable {
    enum Event: Sendable { case text(String), binary(Data), closed(String) }

    private var pending: [Event] = []
    private var waiter: CheckedContinuation<Event, Never>?
    private var closedWhy: String?
    private let queue = DispatchQueue(label: "beanpod.wifi-socket")
    private var conn: NWConnection?
    private var lastActivity = Date()
    private var idleLimit: Double = 0
    private var timer: DispatchSourceTimer?
    private var answered = false

    /// 下一条消息。连接断了之后，每次都立刻返回「断了」。
    func next() async -> Event {
        await withCheckedContinuation { (k: CheckedContinuation<Event, Never>) in
            queue.async {
                if !self.pending.isEmpty { k.resume(returning: self.pending.removeFirst()) }
                else if let why = self.closedWhy { k.resume(returning: .closed(why)) }
                else { self.waiter = k }
            }
        }
    }

    /// 只在 queue 上调用。
    private func push(_ event: Event) {
        if case .closed(let why) = event, closedWhy == nil { closedWhy = why }
        if let w = waiter { waiter = nil; w.resume(returning: event) } else { pending.append(event) }
    }

    /// 连上返回 nil，连不上返回原因。
    func connect(host: String, port: Int, tls: Bool, timeout: Double) async -> String? {
        guard let url = URL(string: "\(tls ? "wss" : "ws")://\(host):\(port)/") else { return String(localized: "地址不对") }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        let params: NWParameters
        if tls {
            // 录音豆的证书是自签的，官方客户端也不校验
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, done in done(true) }, queue)
            params = NWParameters(tls: options)
        } else {
            params = .tcp
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .wifi
        params.preferNoProxies = true
        let c = NWConnection(to: .url(url), using: params)
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            queue.async {
                self.conn = c
                let answer: (String?) -> Void = { r in
                    guard !self.answered else { return }
                    self.answered = true
                    k.resume(returning: r)
                }
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.lastActivity = .now
                        answer(nil)
                        self.receive(c)
                    case .failed(let e):
                        answer(e.localizedDescription)
                        self.push(.closed(e.localizedDescription))
                    case .cancelled:
                        answer(String(localized: "已取消"))
                        self.push(.closed("已关闭"))
                    default: break
                    }
                }
                c.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { answer(String(localized: "\(Int(timeout)) 秒没连上")) }
            }
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error { self.push(.closed(error.localizedDescription)); return }
            self.lastActivity = .now
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text: self.push(.text(String(decoding: data ?? Data(), as: UTF8.self)))
                case .binary: self.push(.binary(data ?? Data()))
                case .close: self.push(.closed("密盒关了连接")); return
                default: break
                }
            }
            self.receive(c)
        }
    }

    func sendText(_ text: String) {
        queue.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            self.conn?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    /// 超过这么多秒没有任何数据，就当连接断了。
    func setIdleLimit(_ seconds: Double) {
        queue.async {
            self.idleLimit = seconds
            self.lastActivity = .now
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler {
                if self.idleLimit > 0, Date.now.timeIntervalSince(self.lastActivity) > self.idleLimit {
                    self.lastActivity = .now
                    self.push(.closed("\(Int(self.idleLimit)) 秒没有数据"))
                }
            }
            t.resume()
            self.timer = t
        }
    }

    func close() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.conn?.cancel()
        }
    }
}

/// 给录音豆发保活小包。官方客户端连上热点后每 100 毫秒往它的 32003 端口发一个 UDP 包；
/// 包的内容在官方代码里读不出来，这里按它日志里的「ping / pong」发 ping。
nonisolated final class WiFiPinger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "beanpod.wifi-ping")
    private let conn: NWConnection
    private var timer: DispatchSourceTimer?

    init(host: String) {
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        params.preferNoProxies = true
        conn = NWConnection(host: NWEndpoint.Host(host), port: 32003, using: params)
    }

    func start() {
        conn.start(queue: queue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [conn] in conn.send(content: Data("ping".utf8), completion: .idempotent) }
        t.resume()
        queue.async { self.timer = t }
    }

    func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.conn.cancel()
        }
    }
}
