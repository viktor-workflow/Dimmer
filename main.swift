import Cocoa
import ColorSync
import Carbon

// Gamma is owned by the WindowServer client; macOS normally restores the
// original table when the process exits, even after a crash.
final class DisplayGamma {
    let id: CGDirectDisplayID
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    var changed = false

    init?(id: CGDirectDisplayID) {
        self.id = id
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 1, capacity <= 65536 else { return nil }
        var r = [Float](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success,
              count > 1, count <= capacity else { return nil }
        red = Array(r.prefix(Int(count)))
        green = Array(g.prefix(Int(count)))
        blue = Array(b.prefix(Int(count)))
        guard (red + green + blue).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0) > 0 else { return nil }
    }

    func apply(dim: Double) -> Bool {
        let multiplier = Float(1 - min(max(dim, 0), 0.92))
        // Always scale the original table, never the previously dimmed table.
        changed = true
        return CGSetDisplayTransferByTable(id, UInt32(red.count),
            red.map { $0 * multiplier }, green.map { $0 * multiplier }, blue.map { $0 * multiplier }) == .success
    }

    @discardableResult func restore() -> Bool {
        guard changed else { return true }
        guard CGDisplayIsOnline(id) != 0 else { changed = false; return true }
        let success = CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue) == .success
        if success { changed = false }
        return success
    }
}

// Each connected display owns a click-through overlay and a persisted dim level.
final class DisplayState {
    let screen: NSScreen
    let key: String
    let displayID: CGDirectDisplayID
    var gamma: DisplayGamma?
    var gammaUnavailable = false
    let window: NSWindow
    var level: Double
    var slider: NSSlider?
    var label: NSTextField?

    init(screen: NSScreen, key: String, level: Double) {
        self.screen = screen
        self.key = key
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        self.level = level
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
    }
}
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String
}

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var item: NSStatusItem!
    var displays: [DisplayState] = []
    let popover = NSPopover()
    var shortcutMonitor: Any?
    var scrollMonitor: Any?
    var globalScrollMonitor: Any?
    let maxDim: Double = 0.92
    let shortcutNames = ["Dim more", "Dim less", "Toggle dimming"]
    var shortcuts: [String: Shortcut] = [:]
    var hotkeys: [Int: EventHotKeyRef] = [:]
    var hotkeyHandler: EventHandlerRef?
    var recording: Int?
    var shortcutButtons: [NSButton] = []
    var shortcutHint: NSTextField?
    var toggleButton: NSButton?
    var cursorStatus: NSTextField?
    var suspended = false
    var wakeWork: DispatchWorkItem?
    var terminationSignals: [DispatchSourceSignal] = []
    var cursorDimming: Bool {
        get { UserDefaults.standard.object(forKey: "cursorDimming") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cursorDimming") }
    }
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dimmingEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dimmingEnabled") }
    }
    var linked: Bool {
        get { UserDefaults.standard.object(forKey: "linkAll") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "linkAll") }
    }
    var savedLevels: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "displayLevels") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "displayLevels") }
    }
    func bounded(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), maxDim) : 0
    }
    var linkedLevel: Double {
        bounded(UserDefaults.standard.object(forKey: "linkedLevel") as? Double
            ?? UserDefaults.standard.double(forKey: "dim"))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(named: "menubar")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 26, height: 16)
        item.button?.imageScaling = .scaleNone
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = nil
        // Menu-bar scrolling can be dispatched outside this process. Local and
        // global monitors have disjoint delivery scopes, so each event runs once.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleStatusScroll(event) == true ? nil : event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            _ = self?.handleStatusScroll(event)
        }
        configureHotkeys()
        popover.delegate = self
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.recording != nil, self.popover.isShown else { return event }
            self.recordShortcut(event)
            return nil
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspendDimming), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resumeDimming), name: name, object: nil)
        }
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
        buildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(buildOverlays),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @discardableResult
    func handleStatusScroll(_ event: NSEvent) -> Bool {
        guard let button = item.button, let window = button.window,
              window.isVisible, !button.isHidden else { return false }
        // Screen coordinates work even when event.window is nil or belongs to
        // another process. Do not depend on the event's window-local coordinates.
        let hitRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let pointer = NSEvent.mouseLocation
        guard hitRect.contains(pointer) else { return false }
        guard event.momentumPhase.isEmpty, recording == nil,
              let target = displays.first(where: { NSMouseInRect(pointer, $0.screen.frame, false) }) else { return true }
        let delta = event.scrollingDeltaY
        // Two-finger gestures often include diagonal drift. Any nonzero vertical
        // component counts; purely horizontal gestures still do nothing.
        guard delta.isFinite, delta != 0 else { return true }
        let direction = event.isDirectionInvertedFromDevice ? -delta : delta
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.0025 : 0.02
        let change = min(max(-direction * sensitivity, -0.08), 0.08)
        let level = enabled ? target.level : 0
        setLevel(level + change, for: target)
        return true
    }

    func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        let content = NSView()
        controller.view = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            content.widthAnchor.constraint(equalToConstant: 320)
        ])

        func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            return field
        }
        func section(_ title: String) {
            let separator = NSBox()
            separator.boxType = .separator
            stack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let heading = label(title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(heading)
        }
        let title = label("Dimmer", size: 17)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)
        section("Displays")
        let linkButton = NSButton(checkboxWithTitle: "Link all displays", target: self, action: #selector(linkChanged(_:)))
        linkButton.state = linked ? .on : .off
        stack.addArrangedSubview(linkButton)
        let displayStack = NSStackView()
        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 10
        displayStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = displayStack
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(max(displays.count, 1) * 64, 240))),
            displayStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            displayStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            displayStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        for (index, display) in displays.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            let name = label(display.screen.localizedName)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(name)
            row.addArrangedSubview(NSView())
            let value = label("")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(value)
            display.label = value
            displayStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: displayStack.widthAnchor).isActive = true
            let slider = NSSlider(value: display.level, minValue: 0, maxValue: maxDim,
                                  target: self, action: #selector(changed(_:)))
            slider.tag = index
            slider.isContinuous = true
            slider.setAccessibilityLabel("Dim \(display.screen.localizedName)")
            display.slider = slider
            displayStack.addArrangedSubview(slider)
            slider.widthAnchor.constraint(equalTo: displayStack.widthAnchor).isActive = true
        }
        if displays.isEmpty {
            displayStack.addArrangedSubview(label("No displays connected", secondary: true))
        }
        section("Shortcuts")
        shortcutButtons = []
        for (index, name) in shortcutNames.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.addArrangedSubview(label(name))
            row.addArrangedSubview(NSView())
            let record = NSButton(title: "Record…", target: self, action: #selector(startRecording(_:)))
            record.bezelStyle = .rounded
            record.tag = index
            record.setAccessibilityLabel("Record shortcut for \(name)")
            row.addArrangedSubview(record)
            shortcutButtons.append(record)
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.bezelStyle = .rounded
            clear.tag = index
            clear.setAccessibilityLabel("Clear shortcut for \(name)")
            row.addArrangedSubview(clear)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let hint = label("Optional: click Record, then press your keys. No shortcuts are enabled by default.", secondary: true)
        shortcutHint = hint
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateShortcutButtons()
        section("Settings")
        let cursorToggle = NSButton(checkboxWithTitle: "Dim cursor too", target: self, action: #selector(cursorDimmingChanged(_:)))
        cursorToggle.state = cursorDimming ? .on : .off
        stack.addArrangedSubview(cursorToggle)
        let status = label("", secondary: true)
        cursorStatus = status
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(label("Display levels and linking are saved automatically.", secondary: true))
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 12
        let offButton = NSButton(title: "Turn Off", target: self, action: #selector(toggleDimming))
        offButton.bezelStyle = .rounded
        toggleButton = offButton
        actions.addArrangedSubview(offButton)
        let quitButton = NSButton(title: "Quit Dimmer", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded
        actions.addArrangedSubview(quitButton)
        stack.addArrangedSubview(actions)
        popover.contentViewController = controller
        refreshControls()
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            refreshControls()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func refreshControls() {
        toggleButton?.title = enabled ? "Turn Off" : "Turn On"
        let unavailable = displays.filter { $0.gammaUnavailable }.map { $0.screen.localizedName }
        cursorStatus?.stringValue = cursorDimming
            ? (unavailable.isEmpty ? "Dims the display and pointer together." : "Screen-only dimming on: " + unavailable.joined(separator: ", "))
            : "Screen-only dimming; pointer stays unchanged."
        for display in displays {
            display.slider?.doubleValue = display.level
            display.label?.stringValue = "\(Int((display.level * 100).rounded()))%"
        }
    }

    @objc func buildOverlays() {
        finishRecording()
        let wasShown = popover.isShown
        if wasShown { popover.close() }
        restoreGamma()
        displays.forEach { $0.window.orderOut(nil) }
        let saved = savedLevels
        displays = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let key: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                key = CFUUIDCreateString(nil, uuid) as String
            } else {
                key = "display-\(id)"
            }
            let level = linked ? linkedLevel : bounded(saved[key] ?? UserDefaults.standard.double(forKey: "dim"))
            return DisplayState(screen: screen, key: key, level: level)
        }
        persistLevels()
        configurePopover()
        apply()
        if wasShown { togglePopover() }
    }

    func persistLevels() {
        // Retain disconnected displays so their settings survive reconnection.
        var saved = savedLevels
        for display in displays { saved[display.key] = display.level }
        savedLevels = saved
    }

    func restoreGamma() {
        var failed = false
        for display in displays {
            if display.gamma?.restore() == false { failed = true }
            display.gamma = nil
        }
        // Last-resort system restoration if a display rejects its original table.
        if failed { CGDisplayRestoreColorSyncSettings() }
    }

    @objc func suspendDimming() {
        wakeWork?.cancel()
        suspended = true
        restoreGamma()
        displays.forEach { $0.window.orderOut(nil) }
    }

    @objc func resumeDimming() {
        wakeWork?.cancel()
        // Let macOS re-establish display profiles before capturing fresh tables.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.suspended = false
            self.buildOverlays()
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    @objc func cursorDimmingChanged(_ button: NSButton) {
        restoreGamma()
        cursorDimming = button.state == .on
        displays.forEach { $0.gammaUnavailable = false }
        apply()
    }

    func apply() {
        if suspended || !enabled || !cursorDimming { restoreGamma() }
        for display in displays {
            let dim = enabled && !suspended ? display.level : 0
            var gammaApplied = false
            if cursorDimming && dim > 0 && !display.gammaUnavailable {
                if display.gamma == nil { display.gamma = DisplayGamma(id: display.displayID) }
                gammaApplied = display.gamma?.apply(dim: dim) == true
                if !gammaApplied {
                    if display.gamma?.restore() == false { CGDisplayRestoreColorSyncSettings() }
                    display.gamma = nil
                    display.gammaUnavailable = true
                }
            } else if dim == 0 {
                if display.gamma?.restore() == false { CGDisplayRestoreColorSyncSettings() }
                display.gamma = nil
            }
            // Never apply both dimming methods to the same screen.
            display.window.alphaValue = gammaApplied ? 0 : CGFloat(dim)
            if !gammaApplied && dim > 0.001 { display.window.orderFrontRegardless() }
            else { display.window.orderOut(nil) }
        }
        refreshControls()
    }

    func setLevel(_ level: Double, for display: DisplayState) {
        enabled = true
        let value = bounded(level)
        if linked {
            displays.forEach { $0.level = value }
            UserDefaults.standard.set(value, forKey: "linkedLevel")
        } else {
            display.level = value
        }
        persistLevels()
        apply()
    }

    @objc func linkChanged(_ button: NSButton) {
        linked = button.state == .on
        if linked, let source = displays.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) }) ?? displays.first {
            setLevel(source.level, for: source)
        }
    }

    @objc func changed(_ slider: NSSlider) {
        guard displays.indices.contains(slider.tag) else { return }
        setLevel(slider.doubleValue, for: displays[slider.tag])
    }

    @objc func toggleDimming() {
        enabled.toggle()
        apply()
    }

    func configureHotkeys() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = saved.filter { key, value in
                ["0", "1", "2"].contains(key) && value.keyCode <= 127 &&
                value.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
            }
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x44494D52 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            owner.performHotkey(Int(id.id))
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        if status == noErr { registerShortcuts() }
    }

    func unregisterShortcuts() {
        hotkeys.values.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
    }

    func registerShortcuts() {
        unregisterShortcuts()
        guard hotkeyHandler != nil else { return }
        for index in 0..<shortcutNames.count {
            guard let shortcut = shortcuts[String(index)] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: 0x44494D52, id: UInt32(index)),
                GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference = reference { hotkeys[index] = reference }
        }
        updateShortcutButtons()
    }

    func updateShortcutButtons() {
        for (index, button) in shortcutButtons.enumerated() {
            if recording == index { button.title = "Press keys…" }
            else if let shortcut = shortcuts[String(index)] {
                button.title = shortcut.title + (hotkeys[index] == nil ? " ⚠︎" : "")
            } else { button.title = "Record…" }
        }
        if recording == nil, shortcuts.keys.contains(where: { hotkeys[Int($0) ?? -1] == nil }) {
            shortcutHint?.stringValue = "A saved shortcut is unavailable. Click it to choose another combination."
        }
    }

    @objc func startRecording(_ button: NSButton) {
        guard hotkeyHandler != nil else {
            shortcutHint?.stringValue = "Shortcut registration is unavailable. Restart Dimmer to retry."
            return
        }
        unregisterShortcuts()
        recording = button.tag
        shortcutHint?.stringValue = "Press a key with ⌘, ⌃ or ⌥ (⇧ is optional). Esc cancels."
        updateShortcutButtons()
    }

    func recordShortcut(_ event: NSEvent) {
        guard let index = recording else { return }
        if event.keyCode == 53 { finishRecording(); return }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            shortcutHint?.stringValue = "Include ⌘, ⌃ or ⌥ so normal typing stays available."
            return
        }
        guard !shortcuts.contains(where: { $0.key != String(index) && $0.value.keyCode == UInt32(event.keyCode) && $0.value.modifiers == modifiers }) else {
            shortcutHint?.stringValue = "Already assigned to another Dimmer action. Choose different keys."
            return
        }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let keyName = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let title = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyName
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(event.keyCode), modifiers,
            EventHotKeyID(signature: 0x44494D52, id: UInt32(index)), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference = reference else {
            shortcutHint?.stringValue = "Those keys are unavailable. Try another combination, or Esc to cancel."
            return
        }
        UnregisterEventHotKey(reference)
        shortcuts[String(index)] = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, title: title)
        saveShortcuts()
        finishRecording()
    }

    func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: "shortcuts") }
    }

    func finishRecording() {
        guard recording != nil else { return }
        recording = nil
        shortcutHint?.stringValue = "Click a shortcut to change it. Clear disables it."
        registerShortcuts()
    }

    @objc func clearShortcut(_ button: NSButton) {
        recording = nil
        shortcuts.removeValue(forKey: String(button.tag))
        saveShortcuts()
        shortcutHint?.stringValue = "Shortcut cleared. Click Record to choose new keys."
        registerShortcuts()
    }

    func popoverDidClose(_ notification: Notification) { finishRecording() }

    var displayUnderPointer: DisplayState? {
        displays.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) })
    }

    func performHotkey(_ action: Int) {
        guard recording == nil else { return }
        if action == 2 { toggleDimming(); return }
        guard let target = displays.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) }) ?? displays.first else { return }
        setLevel(target.level + (action == 0 ? 0.05 : -0.05), for: target)
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeWork?.cancel()
        restoreGamma()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        unregisterShortcuts()
        if let handler = hotkeyHandler { RemoveEventHandler(handler) }
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalScrollMonitor { NSEvent.removeMonitor(monitor) }
    }

}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
