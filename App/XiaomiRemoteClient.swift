import BeanKit
@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class XiaomiRemoteClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onLink: (BLEClient.Link) -> Void = { _ in }
    var onFound: ([FoundDevice]) -> Void = { _ in }
    var onStart: () -> Void = {}
    var onSamples: ([Float]) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onLog: (String) -> Void = { _ in }

    private(set) var connectedName: String?
    private(set) var link: BLEClient.Link = .idle {
        didSet { if link != oldValue { onLink(link) } }
    }

    private enum VoiceSession {
        case idle, requested, streaming(UInt8)
    }
    private var session = VoiceSession.idle
    private var decoder = XiaomiRemoteAudio()
    private var central: CBCentralManager?
    private var active: CBPeripheral?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: FoundDevice] = [:]
    private var transmit: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var wantsScan = false
    private var capabilitiesRequested = false
    private var capabilitiesValidated = false
    private var hasSync = false
    private var discoveryRemaining = 0
    private var requestTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private static let rememberedKey = "xiaomiRemoteDeviceID"
    private static let informationID = CBUUID(string: "180A")
    private static let modelID = CBUUID(string: "2A24")

    var hasRememberedDevice: Bool { UserDefaults.standard.string(forKey: Self.rememberedKey) != nil }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        wantsScan = true
        start()
        guard let central, central.state == .poweredOn, active == nil else { return }
        found.removeAll()
        onFound([])
        central.scanForPeripherals(withServices: nil)
        link = .scanning
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
            if self.found.isEmpty { self.onLog("未找到小米遥控器，请唤醒遥控器后重新搜索；首次使用请先在系统蓝牙设置配对") }
        }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.serviceID]) {
            add(peripheral, name: peripheral.name ?? "小米蓝牙语音遥控器", rssi: 0, bound: true)
        }
    }

    func stopScan() {
        wantsScan = false
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        if link == .scanning { link = .idle }
    }

    func connect(_ id: UUID) {
        guard let central, central.state == .poweredOn, active == nil else { return }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            discoverAfterFailure("系统已无法找到上次的遥控器")
            return
        }
        stopScan()
        active = peripheral
        peripheral.delegate = self
        link = .connecting
        central.connect(peripheral)
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.link == .connecting else { return }
            self.fail("遥控器连接或协议验证超时", rediscover: true)
        }
    }

    func disconnect(forget: Bool) {
        stopScan()
        if forget { UserDefaults.standard.removeObject(forKey: Self.rememberedKey) }
        if let active { central?.cancelPeripheralConnection(active) }
        teardown()
        link = central?.state == .poweredOn ? .idle : .off
    }

    private func add(_ peripheral: CBPeripheral, name: String, rssi: Int, bound: Bool) {
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = FoundDevice(id: peripheral.identifier, name: name, rssi: rssi, mac: nil, bound: bound, isBean: false)
        onFound(found.values.sorted { $0.rssi > $1.rssi })
    }

    private func endSession() {
        let wasStreaming: Bool
        if case .streaming = session { wasStreaming = true } else { wasStreaming = false }
        session = .idle
        requestTimeout?.cancel()
        requestTimeout = nil
        hasSync = false
        decoder.reset()
        if wasStreaming { onEnd() }
    }

    private func teardown() {
        endSession()
        connectionTimeout?.cancel()
        connectionTimeout = nil
        active?.delegate = nil
        active = nil
        connectedName = nil
        transmit = nil
        audio = nil
        control = nil
        capabilitiesRequested = false
        capabilitiesValidated = false
        discoveryRemaining = 0
    }

    private func fail(_ message: String, rediscover: Bool = false) {
        let searchAgain = rediscover || link == .connecting
        onLog(message)
        if let active { central?.cancelPeripheralConnection(active) }
        teardown()
        link = central?.state == .poweredOn ? .idle : .off
        if searchAgain { discoverAfterFailure(message) }
    }

    private func discoverAfterFailure(_ message: String) {
        guard central?.state == .poweredOn else { return }
        onLog("\(message)。正在重新搜索，请唤醒遥控器后从设备列表连接")
        scan()
    }

    private func write(_ bytes: [UInt8]) {
        guard let active, let transmit else { return }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        active.writeValue(Data(bytes), for: transmit, type: type)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            scanTimeout?.cancel()
            scanTimeout = nil
            teardown()
            link = central.state == .unauthorized ? .unauthorized : .off
            return
        }
        link = .idle
        if wantsScan { scan(); return }
        if let saved = UserDefaults.standard.string(forKey: Self.rememberedKey), let id = UUID(uuidString: saved) {
            connect(id)
        } else {
            scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        var services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        services += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        services += Array((advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).keys)
        guard Self.isCandidate(name) || services.contains(Self.serviceID) else { return }
        add(peripheral, name: name.isEmpty ? "小米蓝牙语音遥控器" : name, rssi: RSSI.intValue, bound: false)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == active?.identifier else { return }
        peripheral.discoverServices([Self.serviceID, Self.informationID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        fail(error?.localizedDescription ?? "无法连接遥控器", rediscover: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        teardown()
        link = central.state == .poweredOn ? .idle : .off
        discoverAfterFailure("遥控器连接已断开")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        guard error == nil, let services = peripheral.services,
              services.contains(where: { $0.uuid == Self.serviceID }),
              services.contains(where: { $0.uuid == Self.informationID }) else {
            fail("遥控器未提供 ATVV 或设备型号服务"); return
        }
        discoveryRemaining = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        guard error == nil else { fail("无法读取遥控器通道"); return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.transmitID: transmit = characteristic
            case Self.audioID: audio = characteristic
            case Self.controlID: control = characteristic
            case Self.modelID: peripheral.readValue(for: characteristic)
            default: break
            }
        }
        discoveryRemaining -= 1
        guard discoveryRemaining == 0 else { return }
        guard let transmit, transmit.properties.contains(.write) || transmit.properties.contains(.writeWithoutResponse),
              let audio, let control,
              audio.properties.contains(.notify), control.properties.contains(.notify) else {
            fail("遥控器缺少语音通信通道"); return
        }
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法订阅遥控器语音通道"); return }
        negotiateIfPossible()
    }

    private func negotiateIfPossible() {
        guard connectedName != nil, audio?.isNotifying == true, control?.isNotifying == true,
              !capabilitiesRequested else { return }
        capabilitiesRequested = true
        write([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == active?.identifier, let error else { return }
        fail("遥控器指令失败：\(error.localizedDescription)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == active?.identifier else { return }
        guard error == nil, let value = characteristic.value else { fail("遥控器数据读取失败"); return }
        if characteristic.uuid == Self.modelID {
            let model = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).uppercased()
            guard let name = Self.canonicalName(for: model) else {
                fail("不支持的遥控器型号：\(model)"); return
            }
            connectedName = name
            negotiateIfPossible()
        } else if characteristic.uuid == Self.controlID {
            receiveControl(Array(value))
        } else if characteristic.uuid == Self.audioID, link == .ready, case .streaming = session {
            let samples = decoder.ingest(value)
            if !samples.isEmpty { onSamples(samples) }
        }
    }
}

private extension XiaomiRemoteClient {
    static let serviceID = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let transmitID = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    static let audioID = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    static let controlID = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")

    static func isCandidate(_ name: String) -> Bool {
        ["mi rc", "xiaomi bluetooth remote 2", "xiaomi bluetooth remote 2 pro",
         "小米蓝牙语音遥控器", "小米蓝牙遥控器2", "小米蓝牙遥控器2 pro", "arn9"]
            .contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func canonicalName(for rawModel: String) -> String? {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).uppercased()
        // ARN9 advertisements are hints; an ARN9 DIS variant has unverified nibble ordering.
        guard !model.contains("ARN9") else { return nil }
        if model.contains("RC001") { return "小米蓝牙语音遥控器 2" }
        if model.contains("RC003") { return "小米蓝牙语音遥控器 2 Pro" }
        return nil
    }

    func receiveControl(_ bytes: [UInt8]) {
        guard let opcode = bytes.first else { return }
        if opcode == 0x0B {
            guard capabilitiesRequested, !capabilitiesValidated else { return }
            guard bytes.count >= 7, bytes[1] == 1, bytes[2] == 0 else {
                fail("遥控器协议不是受支持的 ATVV 1.0"); return
            }
            // Firmware can swap codec and interaction bytes when the codec field is invalid.
            let codecMask = bytes[3] & 3 == 0 ? bytes[4] : bytes[3]
            guard codecMask & 2 != 0, UInt16(bytes[5]) << 8 | UInt16(bytes[6]) > 0 else {
                fail("遥控器不支持 16 kHz 语音"); return
            }
            capabilitiesValidated = true
            connectionTimeout?.cancel()
            connectionTimeout = nil
            if let active {
                UserDefaults.standard.set(active.identifier.uuidString, forKey: Self.rememberedKey)
            }
            link = .ready
            return
        }
        guard link == .ready, capabilitiesValidated else { return }
        switch opcode {
        case 0x08:
            guard case .idle = session else { return }
            decoder.reset()
            hasSync = false
            session = .requested
            write([0x0C, 0x00])
            requestTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, case .requested = self.session else { return }
                self.endSession()
                self.onLog("遥控器未开始传送语音，请重新按住语音键")
            }
        case 0x04:
            let codec: UInt8 = bytes.count > 2 ? bytes[2] : 2
            let sessionID: UInt8 = bytes.count > 3 ? bytes[3] : 0
            guard codec == 2 else { fail("遥控器选择了不支持的语音编码"); return }
            if case .streaming(let id) = session {
                if id == sessionID { return }
                endSession()
            }
            requestTimeout?.cancel()
            requestTimeout = nil
            if !hasSync { decoder.reset() }
            hasSync = false
            session = .streaming(sessionID)
            onStart()
        case 0x0A:
            guard bytes.count >= 7 else { return }
            guard bytes[1] == 2 else { fail("遥控器同步编码不是 16 kHz"); return }
            let predictor = Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
            decoder.reset(predictor: predictor, stepIndex: Int(bytes[6]))
            if case .streaming = session { hasSync = false } else { hasSync = true }
        case 0x00:
            endSession()
        case 0x0C:
            guard bytes.count >= 3 else { return }
            endSession()
            onLog("遥控器麦克风打开失败：\(UInt16(bytes[1]) << 8 | UInt16(bytes[2]))")
        default:
            break
        }
    }
}
