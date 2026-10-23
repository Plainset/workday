import AppKit
import SwiftUI
import WorkdayCore

/// The persistent menu bar item: a small orange "glass" showing today's goal progress, plus today's
/// cumulative time. Clicking opens the popover; nothing is started or stopped by opening it.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var lastRendered = ""

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView().environment(model))
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.setAccessibilityTitle("Workday")
        }
        update()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = item.button {
            model.tick()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Re-renders only when the visible minute, state or progress changes (once per minute at most
    /// while running), keeping the menu bar quiet.
    func update() {
        guard let button = item.button else { return }
        let total = model.todayTotal
        let text = DurationFormat.clock(total)
        let progress = min(1, model.goalProgress)
        let pending = model.ledger.hasPendingRecovery
        let running = model.isRunning
        let key = "\(text)|\(Int(progress * 20))|\(pending)|\(running)"
        guard key != lastRendered else { return }
        lastRendered = key

        button.image = Self.icon(progress: progress, running: running, pending: pending)
        button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: running ? .semibold : .regular),
        ])
        let state = running ? "Timer running" : "Timer stopped"
        let pendingText = pending ? ". Interrupted session needs review" : ""
        button.setAccessibilityLabel("Workday. \(state). Today \(DurationFormat.spoken(total))\(pendingText).")
        button.toolTip = "Workday — today \(DurationFormat.short(total)) · \(running ? "Running" : "Stopped")\(pending ? " · Needs review" : "")"
    }

    /// Draws the menu bar glyph: a rounded glass filled with orange liquid to today's goal progress.
    static func icon(progress: Double, running: Bool, pending: Bool) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let glass = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            let orange = NSColor(red: 1.0, green: 0.55, blue: 0.08, alpha: 1)
            NSGraphicsContext.saveGraphicsState()
            glass.addClip()
            NSColor(red: 1.0, green: 0.55, blue: 0.08, alpha: 0.18).setFill()
            rect.fill()
            let level = max(running ? 2 : 0, (rect.height - 3) * progress)
            if level > 0 {
                let liquid = NSBezierPath()
                liquid.move(to: NSPoint(x: 0, y: 0))
                liquid.line(to: NSPoint(x: 0, y: 1.5 + level))
                liquid.curve(to: NSPoint(x: rect.width, y: 1.5 + level),
                             controlPoint1: NSPoint(x: rect.width * 0.35, y: 1.5 + level + 1.4),
                             controlPoint2: NSPoint(x: rect.width * 0.65, y: 1.5 + level - 1.4))
                liquid.line(to: NSPoint(x: rect.width, y: 0))
                liquid.close()
                orange.setFill()
                liquid.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            orange.withAlphaComponent(running ? 1 : 0.75).setStroke()
            glass.lineWidth = running ? 1.6 : 1.1
            glass.stroke()
            if pending {
                let badge = NSBezierPath(ovalIn: NSRect(x: rect.width - 7, y: rect.height - 7, width: 7, height: 7))
                NSColor.systemRed.setFill()
                badge.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    func popoverDidShow(_ notification: Notification) { model.tick() }
}
