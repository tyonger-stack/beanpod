import SwiftUI

/// 设备：录音豆连没连上、电量、存储。右上角进设置。
struct DeviceScreen: View {
    @Environment(BeanStore.self) private var store
    @State private var settingsOpen = UserDefaults.standard.bool(forKey: "showSettings")

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if store.link == .ready { connected } else { notConnected }
            }
            .frame(maxWidth: .infinity)     // 内容窄的时候也要铺满，不然两边会露出系统的白底
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .paper()
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $settingsOpen) { SettingsScreen().environment(store) }
    }

    @ViewBuilder private var connected: some View {
        DevicePhotoView().frame(width: 210, height: 210)
        VStack(spacing: 6) {
            Text(store.displayDeviceName).font(.title.weight(.bold))
            HStack(spacing: 6) {
                Circle().fill(Theme.ok).frame(width: 8, height: 8)
                Text(store.inCase ? "已连接 · 正在充电" : "已连接").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        if let info = store.info {
            HStack(spacing: 14) {
                ring("密盒", value: Double(info.micBattery) / 100, text: "\(info.micBattery)%")
                ring("充电盒", value: Double(info.caseBattery) / 100, text: info.caseBattery > 0 ? "\(info.caseBattery)%" : "—")
                ring("已用空间", value: info.totalKB > 0 ? Double(info.usedKB) / Double(info.totalKB) : 0,
                     text: ByteCountFormatter.string(fromByteCount: Int64(info.usedKB) * 1024, countStyle: .file))
            }
            let onDevice = store.recordings.filter(\.onDevice)
            let waiting = onDevice.filter { !$0.downloaded && !$0.inProgress }.count
            VStack(spacing: 12) {
                fact("密盒里的录音", waiting == 0 ? "\(onDevice.count) 条，都已下载" : "\(onDevice.count) 条，\(waiting) 条没下载")
                Divider()
                fact("还能录", "约 \(Int(Double(info.freeKB) / 8 / 3600)) 小时")
                Divider()
                fact("密盒固件", info.firmware)
                Divider()
                fact("充电盒固件", info.caseFirmware.isEmpty ? "—" : info.caseFirmware)
                Divider()
                fact("下载加密", store.encryptionReady ? "密钥已协商" : "还没准备好")
                Divider()
                fact("序列号", info.serial.uppercased())
            }
            .card()
            if waiting > 0 {
                Button { store.downloadAll() } label: { Text("把 \(waiting) 条都下载下来").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(.borderedProminent).disabled(store.pull != nil || !store.encryptionReady)
            }
        }
        Button("断开连接", role: .destructive) { store.disconnect() }.padding(.top, 4)
        Text("密盒同一时间只让一台设备连。手机连着的时候，Mac 上的密盒助手搜不到它，反过来也一样。")
            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }

    @ViewBuilder private var notConnected: some View {
        DevicePhotoView().frame(width: 190, height: 190)
        VStack(spacing: 6) {
            Text("密盒还没连上").font(.title2.weight(.bold))
            Text(hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        if store.link == .scanning || store.link == .connecting { ProgressView().padding(.top, 2) }
        let beans = store.found.filter(\.isBean)
        if !beans.isEmpty {
            VStack(spacing: 12) {
                ForEach(beans) { device in
                    HStack {
                        Image(systemName: "earbuds").foregroundStyle(Theme.accent)
                        Text(device.name).font(.body.weight(.medium))
                        Spacer()
                        Button("连接") { store.connect(device) }.buttonStyle(.borderedProminent)
                    }
                    if device.id != beans.last?.id { Divider() }
                }
            }
            .card()
        }
        if store.link == .idle || store.link == .scanning {
            Button { store.scan() } label: { Text(store.link == .scanning ? "正在搜索…" : "搜索密盒").frame(maxWidth: .infinity, minHeight: 30) }
                .buttonStyle(.bordered).disabled(store.link == .scanning)
        }
        Text("没有密盒也能用：点底部中间的红色按钮，直接用这台 iPhone 的麦克风录。")
            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }

    private var hint: String {
        switch store.link {
        case .off: "手机的蓝牙没有打开，或者这台设备没有蓝牙。"
        case .unauthorized: "密盒助手没有蓝牙权限。到「设置 → 密盒助手」里把蓝牙打开。"
        case .scanning: "正在找附近的密盒…"
        case .connecting: store.waitingForKnownDevice ? "正在等上次那台密盒出现…" : "正在连接…"
        default: "把密盒放在手机旁边，并确认已开机。"
        }
    }

    private func ring(_ title: String, value: Double, text: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.accent.opacity(0.16), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.001, min(1, value))).stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text).font(.subheadline.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 10)
            }
            .frame(width: 88, height: 88)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
