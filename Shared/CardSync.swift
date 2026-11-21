import BeanKit
import Foundation
import Observation

/// 得到 AI 录音卡：连上之后列出卡里的录音、按需下载，下载好的进豆仓的录音库，照常转写整理。
///
/// 和录音豆分开管（录音豆那套状态和流程一行不动）：卡里还没下载的录音只在设备页列出来，
/// 不放进录音库；下载好了才变成一条普通录音（来源写「得到录音卡」）。
///
/// 录音卡不能远程开始/停止录音（协议里还没找到这条命令），只能在卡上按键录。
/// 豆仓**从不发 0x0041**（官方 App 一连上就发，会永久删除卡里已经传过的录音）；
/// 删除只用按文件名删的 0x0044，而且界面上先问一句。
@Observable
final class CardSync {
    static let origin = "得到录音卡"

    var link: BLEClient.Link = .idle
    var found: [FoundCard] = []
    var name = String(localized: "得到录音卡")
    /// 标准电量服务报的电量（这张卡有没有这个服务还要实机确认，没有就是 nil）。
    var battery: Int?
    var freeKB: UInt32?
    var files: [GetSeedFile] = []
    var listing = false
    /// 这次连接列过一次了（区分「还没列」和「卡里是空的」）。
    var listed = false
    var progress: (name: String, fraction: Double)?
    var queue: [String] = []
    /// 下载过的文件名 → 录音编号。删掉本地那条之后也记着，不会被自动再下载一遍。
    var imported: [String: UInt32] = (UserDefaults.standard.dictionary(forKey: "cardImported") as? [String: NSNumber] ?? [:])
        .mapValues(\.uint32Value) {
        didSet { UserDefaults.standard.set(imported.mapValues { NSNumber(value: $0) }, forKey: "cardImported") }
    }

    @ObservationIgnored weak var store: BeanStore?
    @ObservationIgnored private let client = CardClient()
    @ObservationIgnored private var job: GetSeedDownload?
    @ObservationIgnored private var jobFile: GetSeedFile?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var listPage: UInt32 = 1
    @ObservationIgnored private var listToken = 0
    @ObservationIgnored private var syncOnConnect = false
    @ObservationIgnored private var pendingDelete: String?
    @ObservationIgnored var autoConnectAllowed = true
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?

    var displayName: String { name }
    var hasRememberedCard: Bool { client.hasRememberedCard }
    /// 卡里还没下载过的录音。
    var waiting: [GetSeedFile] { files.filter { !isImported($0) } }

    func isImported(_ file: GetSeedFile) -> Bool { importedID(file) != nil }
    func importedID(_ file: GetSeedFile) -> UInt32? { imported[file.name] ?? previewImported[file.name] }

    // MARK: 示例（预览菜单「看看：得到录音卡」）：没有实机时看界面用，点下载、删除都不发命令

    @ObservationIgnored private var previewImported: [String: UInt32] = [:]
    private(set) var previewing = false

    func showPreview() {
        let tz = TimeZone.current
        let text = "1,2026-11-16-09-12-04.ogg,2026-11-16 09:35:10,6100000;2,2026-11-15-16-30-00.ogg,2026-11-15 16:48:12,4800000;"
            + "3,2026-11-15-10-05-30.ogg,2026-11-15 10:37:41,8500000;4,2026-11-14-14-20-00.ogg,2026-11-14 14:35:02,4000000;"
            + "5,2026-11-14-09-30-00.ogg,2026-11-14 10:11:20,10900000;6,2026-11-13-15-45-00.ogg,2026-11-13 16:11:09,6900000;"
        previewing = true
        files = GetSeedFile.parseList(text, timeZone: tz)
        previewImported = [files[0].name: 1, files[1].name: 2]
        name = "Get-A78A67"; battery = 82; freeKB = 61_111_424
        listed = true; listing = false; queue = []
        progress = (files[2].name, 0.42)
        link = .ready
    }

    func endPreview() {
        guard previewing else { return }
        previewing = false
        previewImported = [:]
        files = []; listed = false; progress = nil; battery = nil; freeKB = nil; name = String(localized: "得到录音卡")
        link = client.link
    }

    func attach(_ store: BeanStore) {
        self.store = store
        client.onLink = { [weak self] in self?.linkChanged($0) }
        client.onFound = { [weak self] in self?.found = $0; self?.autoConnectIfObvious() }
        client.onFrame = { [weak self] in self?.handle($0) }
        client.onBattery = { [weak self] in self?.battery = $0 }
        client.onLog = { [weak store] in store?.addLog($0) }
        client.start()
    }

    // MARK: 连接

    func scan() { client.scan() }
    func stopScan() { client.stopScan() }

    /// 找一会儿就停：没有录音卡的人不用一直开着蓝牙扫描。上次连过的卡不走这里，蓝牙一就绪就自己等它回来。
    func scanBriefly(seconds: Double = 30) {
        guard link == .idle, !previewing else { return }
        scan()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self, self.link == .scanning, self.found.isEmpty { self.stopScan() }
        }
    }
    func connect(_ card: FoundCard) { name = card.name; autoConnectAllowed = true; client.connect(card.id) }
    func disconnect(forget: Bool = true) {
        if previewing { endPreview(); return }
        autoConnectAllowed = false; client.disconnect(forget: forget)
    }
    var waitingForKnownCard: Bool { link == .connecting && client.hasRememberedCard }

    /// 附近只有一张卡、以前也没连过别的卡：直接连，不用再点一下。
    private func autoConnectIfObvious() {
        guard autoConnectAllowed, link == .scanning, autoConnectTask == nil, found.count == 1 else { return }
        autoConnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self else { return }
            self.autoConnectTask = nil
            if self.link == .scanning, self.found.count == 1, let only = self.found.first { self.connect(only) }
        }
    }

    private func linkChanged(_ new: BLEClient.Link) {
        if previewing { endPreview() }
        let old = link
        link = new
        guard new == .ready else {
            if old == .ready {
                store?.toast("wave.3.right", String(localized: "得到录音卡已断开"))
                if let f = jobFile { failJob(f, String(localized: "连接断开，下载中断。录音还在卡里。")) }
            }
            queue.removeAll(); files = []; listed = false; listing = false; battery = nil; freeKB = nil
            return
        }
        if let n = client.connectedName, !n.isEmpty { name = n }
        store?.toast("checkmark.circle.fill", String(localized: "得到录音卡已连接"))
        syncOnConnect = store?.settings.autoDownload ?? false
        Task {
            // 先对时（卡里的文件名就是按它的时钟起的），再问剩余空间，最后要列表
            send(GetSeed.syncTime())
            try? await Task.sleep(for: .milliseconds(400))
            send(GetSeed.frame(.storage))
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }

    private func send(_ frame: Data) { client.send(frame) }

    // MARK: 列表

    func refresh() {
        guard !previewing, link == .ready, job == nil else { return }
        listing = true
        listPage = 1
        files = []
        requestPage()
    }

    private func requestPage() {
        listToken += 1
        let token = listToken
        send(GetSeed.frame(.status))
        send(GetSeed.list(page: listPage))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if let self, token == self.listToken, self.listing { self.finishList() }
        }
    }

    private func gotList(_ text: String) {
        guard listing else { return }
        let page = GetSeedFile.parseList(text)
        let known = Set(files.map(\.name))
        let fresh = page.filter { !known.contains($0.name) }
        files += fresh
        // 官方 App 要列表时带的是「第 1 页、5 条」。正好回满 5 条就再要下一页，
        // 回来的全是已经有的（说明它不分页），或者不满 5 条，就算列完了
        if page.count == 5, !fresh.isEmpty, listPage < 200 {
            listPage += 1
            requestPage()
        } else {
            finishList()
        }
    }

    private func finishList() {
        listToken += 1
        listing = false
        listed = true
        files.sort { ($0.start ?? .distantPast, $0.name) > ($1.start ?? .distantPast, $1.name) }
        store?.addLog("录音卡里有 \(files.count) 条录音，\(waiting.count) 条还没下载")
        if syncOnConnect {
            syncOnConnect = false
            if !waiting.isEmpty {
                store?.toast("arrow.down.circle.fill", String(localized: "得到录音卡里有 \(waiting.count) 条新录音，开始同步"))
                downloadAll()
            }
        }
    }

    // MARK: 下载

    func download(_ file: GetSeedFile) {
        guard !previewing, link == .ready, !queue.contains(file.name), jobFile?.name != file.name else { return }
        queue.append(file.name)
        startNext()
    }

    func downloadAll() { waiting.forEach(download) }

    func isQueued(_ file: GetSeedFile) -> Bool { queue.contains(file.name) }

    private func startNext() {
        guard job == nil, link == .ready, !queue.isEmpty else { return }
        let name = queue.removeFirst()
        guard let file = files.first(where: { $0.name == name }) else { return startNext() }
        job = GetSeedDownload(name: name)
        jobFile = file
        lastActivity = .now
        progress = (name, 0)
        send(GetSeed.download(name))
        Task { [weak self] in
            // 20 秒没有任何数据就算失败；数据收齐了 2 秒还没等到「传完了」也收尾
            while let self, let j = self.job, j.name == name {
                let idle = Date.now.timeIntervalSince(self.lastActivity)
                if j.complete, idle > 2 { self.finishJob(); return }
                if idle > 20 {
                    self.failJob(file, j.received == 0 ? String(localized: "录音卡没有回传数据。把卡靠近电脑再试一次。") : String(localized: "传输中途停了，请重试。录音还在卡里。"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishJob() {
        guard let j = job, let file = jobFile else { return }
        job = nil; jobFile = nil; progress = nil
        defer { if !queue.isEmpty { Task { try? await Task.sleep(for: .seconds(1)); startNext() } } }
        if j.notFound {
            store?.problem = BeanStore.Problem(title: String(localized: "卡里已经没有这条录音了"), detail: String(localized: "「\(file.name)」可能已经被得到 App 同步后清掉了。"))
            files.removeAll { $0.name == file.name }
            return
        }
        guard j.complete else {
            store?.problem = BeanStore.Problem(title: String(localized: "这条录音没传完整"), detail: String(localized: "只收到 \(Int(j.fraction * 100))%。录音还在卡里，没有丢，可以再下载一次。"))
            return
        }
        store?.addLog("录音卡下载完：\(file.name)，\(j.chunks) 块，\(j.data.count) 字节")
        if let id = store?.storeCardFile(file, ogg: j.data.prefix(j.expected)) { imported[file.name] = id }
    }

    private func failJob(_ file: GetSeedFile, _ message: String) {
        guard jobFile?.name == file.name else { return }
        job = nil; jobFile = nil; progress = nil
        store?.problem = BeanStore.Problem(title: String(localized: "这条录音没下载下来"), detail: message, action: .device)
        startNext()
    }

    // MARK: 删除

    /// 从卡上永久删掉一条（不能恢复）。界面上要先问过用户。
    func deleteFromCard(_ file: GetSeedFile) {
        guard !previewing, link == .ready, job == nil else { return }
        pendingDelete = file.name
        send(GetSeed.delete(file.name))
    }

    // MARK: 收包

    private func handle(_ f: GetSeedFrame) {
        let isData = f.command == .data
        if !isData { store?.addLog("录音卡 ← \(String(format: "%04X", f.cmd)) \(f.body.prefix(48).hex)") }
        switch f.command {
        case .list:
            gotList(String(decoding: f.body, as: UTF8.self))
        case .storage:
            // 4 字节 + 可用空间 KB（u32 LE）+ 4 字节
            if f.body.count >= 8 { freeKB = f.body.u32le(4) }
        case .fileSize, .data, .done, .error:
            guard var j = job else { return }
            j.add(f)
            job = j
            lastActivity = .now
            progress = (j.name, j.fraction)
            if f.command == .done || f.command == .error { finishJob() }
        case .delete:
            let ok = f.body.first == 1
            if let name = pendingDelete {
                pendingDelete = nil
                if ok {
                    files.removeAll { $0.name == name }
                    store?.toast("trash", String(localized: "已从录音卡删掉一条录音"))
                } else {
                    store?.problem = BeanStore.Problem(title: String(localized: "录音卡没有删掉这条录音"), detail: String(localized: "它可能正在录音或传文件。等一会儿再试。"))
                }
            }
        default:
            break
        }
    }
}

extension BeanStore {
    /// 把从录音卡下载的 Ogg 文件存进录音库：原样存 .ogg，再解成 16 kHz 的 WAV 给播放和转写用。
    /// 返回这条录音的编号；存不下来返回 nil。
    func storeCardFile(_ file: GetSeedFile, ogg: Data) -> UInt32? {
        var id = file.recordingID
        // 同一秒已经有一条别的录音（比如录音豆的）：往后挪一个编号
        while let r = recordings.first(where: { $0.id == id }), r.origin != CardSync.origin { id &+= 1 }
        do {
            let packets = OggOpus.packets(fromOgg: ogg)
            guard let first = packets.first, let perPacket = OggOpus.samplesPerPacket(first) else { throw AudioError.noAudio }
            try ogg.write(to: oggURL(id), options: .atomic)
            let seconds = try OpusDecoder.writeWAV(packets: packets, to: wavURL(id), framesPerPacket: UInt32(perPacket))
            var rec = recordings.first(where: { $0.id == id }) ?? Recording(id: id, size: UInt32(ogg.count), date: file.start ?? file.end, duration: seconds)
            rec.downloaded = true
            rec.duration = seconds
            rec.size = UInt32(ogg.count)
            rec.origin = CardSync.origin
            if let i = recordings.firstIndex(where: { $0.id == id }) { recordings[i] = rec } else { recordings.append(rec) }
            recordings.sort { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
            saveLibrary()
            addLog("得到录音卡的录音存好了：\(file.name) → \(id)（\(Int(seconds)) 秒）")
            if settings.autoProcess { process(id) }
            return id
        } catch {
            try? FileManager.default.removeItem(at: oggURL(id))
            try? FileManager.default.removeItem(at: wavURL(id))
            addLog("录音卡的录音没存下来 \(file.name)：\(error.localizedDescription)")
            problem = BeanStore.Problem(title: String(localized: "录音没能存到这台设备"), detail: String(localized: "\(error.localizedDescription)\n录音还在卡里，可以再下载一次。"))
            return nil
        }
    }
}
