import AppKit
import SwiftUI

/// The menu bar item: the Discette mark only (no song title unless the user turns it on).
/// Click for the mini player, right-click (or Control-click) for the full menu.
@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    var menuProvider: () -> NSMenu = { NSMenu() }

    init(root: AnyView) {
        super.init()
        if let button = item.button {
            button.image = DiscetteMark.menuBarImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Discette")
            button.setAccessibilityHelp("Click for the mini player. Right-click for the menu.")
        }
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    func setTitle(_ title: String?) {
        item.button?.title = title.map { " " + $0 } ?? ""
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    private func showMenu() {
        popover.performClose(nil)
        item.menu = menuProvider()
        item.button?.performClick(nil)
        item.menu = nil
    }
}

/// A menu item that runs a closure, so menus can be built inline.
final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, checked: Bool = false, key: String = "", enabled: Bool = true,
                     _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.handler = handler
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @objc private func fire() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ item: NSMenuItem) -> NSMenuItem {
        addItem(item)
        return item
    }

    func addLabel(_ title: String) {
        let label = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        label.isEnabled = false
        addItem(label)
    }

    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        build(sub)
        parent.submenu = sub
        addItem(parent)
    }
}
