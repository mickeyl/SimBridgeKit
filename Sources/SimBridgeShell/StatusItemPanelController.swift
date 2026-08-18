import AppKit
import Combine
import SwiftUI

/// The reusable core of a provider's menu bar presence: the status item, its
/// click handling, and the borderless control panel that opens beneath it.
///
/// The product supplies the panel content and the icon; window management for
/// auxiliary editors stays with the product too.
@MainActor
public final class StatusItemPanelController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let title: String
    private let contentSize: NSSize
    private let cornerRadius: CGFloat
    private let makeContent: () -> AnyView
    private var controlWindow: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var statusButtonClickMonitor: Any?

    /// - Parameters:
    ///   - makeContent: builds the panel's SwiftUI content lazily on first
    ///     open. The content should size itself to `contentSize`.
    public init(
        title: String,
        toolTip: String,
        contentSize: NSSize,
        cornerRadius: CGFloat = 10,
        makeContent: @escaping () -> AnyView
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.title = title
        self.contentSize = contentSize
        self.cornerRadius = cornerRadius
        self.makeContent = makeContent
        super.init()
        configureStatusItem(toolTip: toolTip)
        observePanelBehavior()
    }

    deinit {
        if let statusButtonClickMonitor {
            NSEvent.removeMonitor(statusButtonClickMonitor)
        }
    }

    /// The status item's button, for icon updates.
    public var statusButton: NSStatusBarButton? { statusItem.button }

    public func setIcon(_ image: NSImage?) {
        guard let button = statusItem.button, button.image !== image else { return }
        button.image = image
    }

    private func configureStatusItem(toolTip: String) {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        // Command-held clicks must pass through untouched: AppKit's built-in
        // Command-drag repositioning of status items never sees the event if
        // the monitor swallows it.
        statusButtonClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak button] event in
            guard let self, let button, event.window === button.window else { return event }
            guard !event.modifierFlags.contains(.command) else { return event }
            let location = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(location) else { return event }
            self.togglePanel()
            return nil
        }
    }

    private func observePanelBehavior() {
        NotificationCenter.default.publisher(for: ShellPreferences.controlWindowBehaviorDidChange)
            .sink { [weak self] _ in self?.applyPanelBehavior() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.hidePanelAfterDeactivationIfNeeded() }
            .store(in: &cancellables)
    }

    // MARK: - Panel

    @objc public func togglePanel() {
        if controlWindow?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    public func showPanel() {
        let window = controlWindow ?? makePanel()
        applyPanelBehavior()
        positionPanel(window)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func hidePanel() {
        controlWindow?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let root = makeContent()
            .frame(width: contentSize.width, height: contentSize.height)

        let contentRect = NSRect(origin: .zero, size: contentSize)
        let window = ControlPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = MenuPanelContentView(
            rootView: root,
            contentSize: contentSize,
            cornerRadius: cornerRadius
        )
        window.delegate = self
        window.title = title
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.invalidateShadow()
        controlWindow = window
        return window
    }

    private func applyPanelBehavior() {
        controlWindow?.hidesOnDeactivate = false
    }

    private func hidePanelAfterDeactivationIfNeeded() {
        guard ShellPreferences.dismissControlWindowOnDeactivate else { return }
        hidePanel()
    }

    private func positionPanel(_ window: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            window.center()
            return
        }

        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let centeredX = buttonFrame.midX - frameSize.width / 2
        let x = min(
            max(centeredX, visibleFrame.minX + 8),
            visibleFrame.maxX - frameSize.width - 8
        )
        let y = max(visibleFrame.minY + 8, buttonFrame.minY - frameSize.height - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - NSWindowDelegate

    public nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard ShellPreferences.dismissControlWindowOnDeactivate,
                  let window = notification.object as? NSWindow,
                  window === self.controlWindow
            else { return }
            self.hidePanel()
        }
    }
}
