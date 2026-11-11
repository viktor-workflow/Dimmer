import Cocoa

// Dimmer: dims the built-in screen below macOS's minimum using a
// click-through black overlay (same idea as Lunar's Sub-zero overlay).
final class App: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var overlays: [NSWindow] = []
    let maxDim: CGFloat = 0.92
    var dim: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "dim")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "dim") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(named: "menubar")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 26, height: 16)
        item.button?.imageScaling = .scaleNone
        item.button?.image = icon
        let menu = NSMenu()
        let label = NSMenuItem(title: "Extra dim", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        let slider = NSSlider(value: Double(dim), minValue: 0, maxValue: Double(maxDim),
                              target: self, action: #selector(changed(_:)))
        slider.frame = NSRect(x: 16, y: 4, width: 200, height: 24)
        slider.isContinuous = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 32))
        view.addSubview(slider)
        let sItem = NSMenuItem(); sItem.view = view
        menu.addItem(sItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Off", action: #selector(off), keyEquivalent: "0"))
        menu.addItem(NSMenuItem(title: "Quit Dimmer", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        buildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(buildOverlays),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.backgroundColor = .black
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            return w
        }
        apply()
    }

    func apply() {
        for w in overlays {
            w.alphaValue = dim
            if dim > 0.001 { w.orderFrontRegardless() } else { w.orderOut(nil) }
        }
    }

    @objc func changed(_ s: NSSlider) { dim = CGFloat(s.doubleValue); apply() }
    @objc func off() {
        dim = 0; apply()
        if let v = item.menu?.item(at: 1)?.view?.subviews.first as? NSSlider { v.doubleValue = 0 }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
