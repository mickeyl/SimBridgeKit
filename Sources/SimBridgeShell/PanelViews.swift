import AppKit
import SwiftUI

public final class ControlPanel: NSPanel {
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }
}

public final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override public var isOpaque: Bool { false }
}

/// Rounded, bordered backdrop for the borderless control panel. Drawn manually
/// because a borderless `NSPanel` brings no chrome of its own.
public final class MenuPanelContentView: NSView {
    private let hostingView: NSView
    private let cornerRadius: CGFloat

    override public var isOpaque: Bool { false }

    public init<Content: View>(rootView: Content, contentSize: NSSize, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        hostingView = TransparentHostingView(rootView: rootView)
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
