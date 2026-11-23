import AppKit
import Observation
import SwiftUI

enum RemoteFocusScope {
    case window, sidebar, mainContent, recordingStage

    var isSplitPane: Bool { self == .sidebar || self == .mainContent }
}

private struct RemoteFocusScopeKey: EnvironmentKey {
    static let defaultValue = RemoteFocusScope.window
}

extension EnvironmentValues {
    var remoteFocusScope: RemoteFocusScope {
        get { self[RemoteFocusScopeKey.self] }
        set { self[RemoteFocusScopeKey.self] = newValue }
    }
}

@MainActor
final class RemoteFocusNavigation {
    private typealias Target = (RemoteFocusTargetView, NSRect)
    private weak var selected: RemoteFocusTargetView?
    private weak var activeWindow: NSWindow?
    private weak var scrollArea: NSScrollView?

    var hasSelection: Bool { selected?.visibleFrame != nil }

    static func isEditing(in window: NSWindow) -> Bool {
        if let text = window.firstResponder as? NSTextView { return text.isEditable }
        return window.firstResponder is NSTextField
    }

    func clear() {
        selected?.indicator?.isHighlighted = false
        selected = nil
        activeWindow = nil
        scrollArea = nil
    }

    func handle(_ key: RemoteKeyInput.Key, in window: NSWindow, scope: RemoteFocusScope = .window) -> Bool {
        guard !Self.isEditing(in: window) else { clear(); return false }
        if activeWindow !== window { clear() }
        let targets = visibleTargets(in: window, scope: scope)
        if key == .confirm {
            guard let selected, targets.contains(where: { $0.0 === selected }) else { clear(); return false }
            selected.action?()
            return true
        }
        let direction: CGVector
        switch key {
        case .left: direction = CGVector(dx: -1, dy: 0)
        case .right: direction = CGVector(dx: 1, dy: 0)
        case .up: direction = CGVector(dx: 0, dy: 1)
        case .down: direction = CGVector(dx: 0, dy: -1)
        default: return false
        }
        guard !targets.isEmpty else { clear(); return false }
        let next: Target?
        if let selected, let index = targets.firstIndex(where: { $0.0 === selected }) {
            let current = targets[index]
            if scope.isSplitPane {
                let adjacent = index + (key == .up ? -1 : 1)
                next = targets.indices.contains(adjacent) ? targets[adjacent] : nil
                if let scroll = selected.enclosingScrollView,
                   next?.0.isDescendant(of: scroll) != true,
                   let revealed = revealAdjacent(to: selected, in: scroll, movingUp: key == .up) {
                    return highlight(revealed.0, in: window)
                }
            } else {
                next = targets.filter { $0.0 !== selected }.compactMap { candidate -> (Target, CGFloat)? in
                    let dx = candidate.1.midX - current.1.midX
                    let dy = candidate.1.midY - current.1.midY
                    let forward = dx * direction.dx + dy * direction.dy
                    guard forward > 1 else { return nil }
                    let lateral = abs(dx * direction.dy - dy * direction.dx)
                    return (candidate, forward + lateral * 3)
                }.min(by: { $0.1 < $1.1 })?.0
            }
            if next == nil {
                guard let scroll = selected.enclosingScrollView, scrollInDirection(direction, in: scroll) else {
                    if scope.isSplitPane { return true }
                    clear()
                    return false
                }
                clear()
                activeWindow = window
                scrollArea = scroll
                return true
            }
        } else {
            let scrolledTargets = scrollArea.map { area in targets.filter { $0.0.enclosingScrollView === area } } ?? []
            let candidates = scrolledTargets.isEmpty ? targets : scrolledTargets
            next = direction.dy > 0 ? candidates.last : candidates.first
        }
        guard let next else { return false }
        return highlight(next.0, in: window)
    }

    func enter(_ scope: RemoteFocusScope, in window: NSWindow) -> Bool {
        let targets = visibleTargets(in: window, scope: scope)
        guard let first = targets.first else { return false }
        let current = targets.first { $0.0 === selected }
        return highlight((current ?? first).0, in: window)
    }

    private func visibleTargets(in window: NSWindow, scope: RemoteFocusScope) -> [Target] {
        RemoteFocusTargetView.targets.allObjects.compactMap { view -> Target? in
            guard view.window === window, view.scope == scope, view.enabled, let frame = view.visibleFrame else { return nil }
            return (view, frame)
        }.sorted { Self.precedes($0.1, $1.1) }
    }

    private func revealAdjacent(to selected: RemoteFocusTargetView, in scroll: NSScrollView, movingUp: Bool) -> Target? {
        let origin = selected.convert(selected.bounds, to: nil)
        let candidates = RemoteFocusTargetView.targets.allObjects.compactMap { view -> Target? in
            guard view !== selected, view.scope == selected.scope, view.enabled,
                  view.isDescendant(of: scroll), view.visibleFrame == nil, let frame = view.unclippedFrame,
                  movingUp ? Self.precedes(frame, origin) : Self.precedes(origin, frame) else { return nil }
            return (view, frame)
        }
        let next = candidates.min { movingUp ? Self.precedes($1.1, $0.1) : Self.precedes($0.1, $1.1) }
        guard let view = next?.0 else { return nil }
        view.scrollToVisible(view.bounds)
        return view.visibleFrame.map { (view, $0) }
    }

    private static func precedes(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let lhsRow = (lhs.midY / 8).rounded(), rhsRow = (rhs.midY / 8).rounded()
        return lhsRow == rhsRow ? lhs.minX < rhs.minX : lhsRow > rhsRow
    }

    private func highlight(_ next: RemoteFocusTargetView, in window: NSWindow) -> Bool {
        if selected !== next { selected?.indicator?.isHighlighted = false }
        selected = next
        activeWindow = window
        scrollArea = nil
        next.indicator?.isHighlighted = true
        return true
    }

    private func scrollInDirection(_ direction: CGVector, in scroll: NSScrollView) -> Bool {
        let clip = scroll.contentView
        let bounds = clip.bounds
        let proposed = bounds.offsetBy(dx: direction.dx * bounds.width * 0.6,
                                       dy: direction.dy * bounds.height * (clip.isFlipped ? -0.6 : 0.6))
        let origin = clip.constrainBoundsRect(proposed).origin
        guard origin != bounds.origin else { return false }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }
}

@MainActor @Observable
private final class RemoteFocusIndicator {
    var isHighlighted = false
}

@MainActor
private final class RemoteFocusTargetView: NSView {
    static let targets = NSHashTable<RemoteFocusTargetView>.weakObjects()
    weak var indicator: RemoteFocusIndicator?
    var action: (() -> Void)?
    var enabled = true
    var scope = RemoteFocusScope.window

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.targets.add(self)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    var unclippedFrame: NSRect? {
        guard window != nil, !isHiddenOrHasHiddenAncestor, bounds.width > 1, bounds.height > 1 else { return nil }
        return convert(bounds, to: nil)
    }

    var visibleFrame: NSRect? {
        guard let window, var clipped = unclippedFrame else { return nil }
        var ancestor: NSView? = self
        while let view = ancestor {
            guard view.alphaValue > 0 else { return nil }
            clipped = clipped.intersection(view.convert(view.visibleRect, to: nil))
            ancestor = view.superview
        }
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return window.convertToScreen(clipped)
    }
}

private struct RemoteFocusTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.remoteFocusScope) private var scope
    let indicator: RemoteFocusIndicator
    let action: () -> Void
    func makeNSView(context: Context) -> RemoteFocusTargetView { RemoteFocusTargetView() }
    func updateNSView(_ view: RemoteFocusTargetView, context: Context) {
        view.indicator = indicator
        view.enabled = enabled
        view.scope = scope
        view.action = action
    }
}

private struct RemoteFocusDecoration: ViewModifier {
    @State private var indicator = RemoteFocusIndicator()
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(RemoteFocusTarget(indicator: indicator, action: action))
            .overlay {
                if indicator.isHighlighted {
                    let shape = RoundedRectangle(cornerRadius: 8)
                    shape.strokeBorder(.white, lineWidth: 5)
                        .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 3).padding(1) }
                        .padding(-2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func remoteFocusable(action: @escaping () -> Void) -> some View {
        modifier(RemoteFocusDecoration(action: action))
    }
}

struct RemoteButton<Label: View>: View {
    private let role: ButtonRole?
    private let action: () -> Void
    private let label: Label

    init(role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.role = role
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) { label }
            .remoteFocusable(action: action)
    }
}

extension RemoteButton where Label == Text {
    init(_ titleKey: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(titleKey) }
    }

    init<S: StringProtocol>(_ title: S, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}


extension RemoteButton where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }

    init<S: StringProtocol>(_ title: S, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}
