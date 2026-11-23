import AppKit
import IOKit.hid
import Observation

@MainActor @Observable
final class XiaomiRemoteBackButton {
    enum Status: Equatable {
        case needsPermission, waitingForDevice, multipleDevices, unavailable, listening
    }

    @ObservationIgnored var onPress: () -> Void = {}
    private(set) var status: Status = .needsPermission
    var isListening: Bool { status == .listening }

    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var devices = Set<UInt64>()
    @ObservationIgnored private var presses = PressState()

    func start() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            stop()
            status = .needsPermission
            return
        }
        if let manager {
            devices = Set(((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).compactMap(Self.supportedID))
            refreshStatus()
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x2717,
            kIOHIDProductIDKey: 0x32B8,
            kIOHIDTransportKey: "Bluetooth Low Energy",
            kIOHIDPrimaryUsagePageKey: 1,
            kIOHIDPrimaryUsageKey: 6,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, type, reportID, report, length in
            guard result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
                  let context, let sender, length == 6 || length == 7 else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<XiaomiRemoteBackButton>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                guard let id = XiaomiRemoteBackButton.supportedID(device) else { return }
                monitor.receive(deviceID: id, reportID: reportID,
                                bytes: Array(UnsafeBufferPointer(start: report, count: length)))
            }
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<XiaomiRemoteBackButton>.fromOpaque(context).takeUnretainedValue()
                guard let id = XiaomiRemoteBackButton.supportedID(device) else { return }
                monitor.devices.insert(id)
                monitor.refreshStatus()
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<XiaomiRemoteBackButton>.fromOpaque(context).takeUnretainedValue()
                guard let id = XiaomiRemoteBackButton.registryID(device) else { return }
                monitor.devices.remove(id)
                monitor.presses.remove(deviceID: id)
                monitor.refreshStatus()
            }
        }, context)
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            stop()
            status = .unavailable
            return
        }
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            if let id = Self.supportedID(device) { devices.insert(id) }
        }
        refreshStatus()
    }

    func stop() {
        status = .waitingForDevice
        devices.removeAll()
        presses = PressState()
        guard let manager else { return }
        self.manager = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    @discardableResult
    func requestPermission() -> String? {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted {
            start()
            return nil
        }
        if access == kIOHIDAccessTypeUnknown,
           IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            start()
            return nil
        }
        stop()
        status = .needsPermission
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        guard NSWorkspace.shared.open(url) else {
            return String(localized: "无法打开系统设置。请前往「系统设置 → 隐私与安全性 → 输入监控」，允许密盒助手。")
        }
        return nil
    }

    isolated deinit { stop() }

    private func refreshStatus() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            status = .needsPermission
            return
        }
        guard manager != nil else {
            status = .waitingForDevice
            return
        }
        switch devices.count {
        case 0: status = .waitingForDevice
        case 1: status = .listening
        default: status = .multipleDevices
        }
    }

    private func receive(deviceID: UInt64, reportID: UInt32, bytes: [UInt8]) {
        guard let manager, devices.contains(deviceID),
              presses.receive(deviceID: deviceID, reportID: reportID, bytes: bytes,
                              canNavigate: isListening && NSApp?.isActive == true),
              let connected = IOHIDManagerCopyDevices(manager), CFSetGetCount(connected) == 1 else { return }
        Task { @MainActor [weak self] in
            guard let self, self.manager === manager, self.isListening,
                  self.devices.contains(deviceID), NSApp?.isActive == true,
                  let connected = IOHIDManagerCopyDevices(manager), CFSetGetCount(connected) == 1 else { return }
            self.onPress()
        }
    }

    private static func supportedID(_ device: IOHIDDevice) -> UInt64? {
        guard IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int == 0x2717,
              IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int == 0x32B8,
              IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String == "Bluetooth Low Energy",
              IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int == 1,
              IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int == 6 else { return nil }
        return registryID(device)
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == kIOReturnSuccess else { return nil }
        return id
    }

    struct PressState {
        private var heldDevices = Set<UInt64>()

        mutating func receive(deviceID: UInt64, reportID: UInt32, bytes: [UInt8], canNavigate: Bool) -> Bool {
            guard reportID == 1 else { return false }
            let offset: Int
            switch bytes.count {
            case 6: offset = 0
            case 7 where bytes[0] == 1: offset = 1
            default: return false
            }
            var back = false
            for index in stride(from: offset, to: bytes.count, by: 2) {
                let usage = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                guard usage == 0 || (4...0xFE).contains(usage) else { return false }
                if usage == 0xF1 { back = true }
            }
            if back { return heldDevices.insert(deviceID).inserted && canNavigate }
            heldDevices.remove(deviceID)
            return false
        }

        mutating func remove(deviceID: UInt64) {
            heldDevices.remove(deviceID)
        }
    }
}
