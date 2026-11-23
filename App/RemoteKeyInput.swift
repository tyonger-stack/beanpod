import AppKit
import Carbon
import SwiftUI

struct RemoteKeyInput: NSViewRepresentable {
    enum Key {
        case up, down, left, right, confirm, back, voice

        init?(code: UInt16) {
            switch Int(code) {
            case kVK_UpArrow: self = .up
            case kVK_DownArrow: self = .down
            case kVK_LeftArrow: self = .left
            case kVK_RightArrow: self = .right
            case kVK_Return, kVK_ANSI_KeypadEnter: self = .confirm
            case kVK_Escape: self = .back
            case kVK_F5: self = .voice
            default: return nil
            }
        }
    }

    var whileEditing = false
    var pointerInput: () -> Void = {}
    var handle: (Key) -> Bool

    static func sendBack() {
        guard NSApp.isActive, let window = NSApp.keyWindow,
              window.sheetParent == nil, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        for view in KeyView.mounted.allObjects where view.window === window {
            if (view.whileEditing || !RemoteFocusNavigation.isEditing(in: window)), view.handle(.back) { return }
        }
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.handle = handle
        nsView.whileEditing = whileEditing
        nsView.pointerInput = pointerInput
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class KeyView: NSView {
        static let mounted = NSHashTable<KeyView>.weakObjects()
        private static var consumedKeys: Set<UInt16> = []
        var handle: (Key) -> Bool = { _ in false }
        var whileEditing = false
        var pointerInput: () -> Void = {}
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            Self.mounted.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .scrollWheel]) { [weak self] event in
                if event.type == .keyUp { return Self.consumedKeys.remove(event.keyCode) == nil ? event : nil }
                if event.type == .keyDown {
                    let code = event.keyCode
                    let key = Key(code: code)
                    if event.isARepeat, key == .confirm || key == .back {
                        return Self.consumedKeys.contains(code) ? nil : event
                    }
                    if !event.isARepeat { Self.consumedKeys.remove(code) }
                }
                guard let self, let window = self.window, window.isKeyWindow, NSApp.isActive,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      event.window == nil || event.window === window else { return event }

                if event.type == .leftMouseDown || event.type == .scrollWheel {
                    self.pointerInput()
                    return event
                }
                let code = event.keyCode
                guard let key = Key(code: code) else { return event }
                let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(modifiers).isEmpty,
                      self.whileEditing || (window.firstResponder as? NSTextView)?.isEditable != true,
                      self.handle(key) else { return event }
                Self.consumedKeys.insert(code)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            Self.mounted.remove(self)
        }
    }
}

struct RemoteWindowNavigation: ViewModifier {
    var back: () -> Void
    var keepCardVisible = false
    var stageVisible = false
    var hasSplitPanes = false
    var voiceStage = false
    var finishVoice: () -> Void = {}
    var moveBetweenPanes: ((RemoteKeyInput.Key) -> Void)?
    @State private var focus = RemoteFocusNavigation()
    @State private var pane = RemoteFocusScope.mainContent

    func body(content: Content) -> some View {
        content.background {
            RemoteKeyInput(whileEditing: keepCardVisible, pointerInput: focus.clear) { key in
                if key == .back {
                    focus.clear()
                    pane = .mainContent
                    back()
                    return true
                }
                guard !keepCardVisible, let window = NSApp.keyWindow else { return false }
                if key == .voice { return voiceStage }
                if let moveBetweenPanes, !focus.hasSelection, key == .left || key == .right {
                    moveBetweenPanes(key)
                    return true
                }
                if hasSplitPanes, !stageVisible, key == .left || key == .right {
                    let destination: RemoteFocusScope = key == .left ? .sidebar : .mainContent
                    guard focus.enter(destination, in: window) else { return false }
                    pane = destination
                    return true
                }
                let scope = stageVisible ? RemoteFocusScope.recordingStage : (hasSplitPanes ? pane : .window)
                if focus.handle(key, in: window, scope: scope) { return true }
                guard voiceStage, key == .confirm else { return false }
                finishVoice()
                return true
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: keepCardVisible) { focus.clear() }
        .onChange(of: stageVisible) { focus.clear() }
        .onDisappear { focus.clear() }
    }
}
