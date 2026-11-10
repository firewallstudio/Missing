import AppKit
import Carbon

// MARK: - Mouse: eylemler
//
// Tuşlara bağlanan eylemlerin hepsi burada. Sistem eylemleri Dock'a bildirimle (Mission Control,
// uygulama pencereleri, masaüstü, Launchpad) ya da kullanıcının kendi sistem kısayoluyla
// (Space değiştirme) yapılır; kısayol eylemleri geçerli klavye düzenine göre tuşa çevrilir.

/// Klavye düzenine bağlı tuş kodları (ana thread'de hesaplanır, olay thread'i okur)
enum MouseKeys {
    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue
    private static var lock = os_unfair_lock()
    nonisolated(unsafe) private static var codes: [String: Int] = [:]

    @MainActor static func refresh() {
        var c: [String: Int] = [:]
        for ch in ["[", "]", "=", "+", "-", "w", "m", "h", "q", "f", "`", "c", "v", "x", "z", "a", " "] {
            if let k = KeyNames.keyCode(for: ch) { c[ch] = k }
        }
        os_unfair_lock_lock(&lock); codes = c; os_unfair_lock_unlock(&lock)
    }

    /// ABD düzenindeki karşılıkları (düzende bulunamazsa)
    private static let us: [String: Int] = ["[": 33, "]": 30, "=": 24, "+": 24, "-": 27, "w": 13, "m": 46, "h": 4,
                                            "q": 12, "f": 3, "`": 50, "c": 8, "v": 9, "x": 7, "z": 6, "a": 0, " ": 49]

    static func code(_ ch: String) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return codes[ch] ?? us[ch] ?? 0
    }
}

enum MouseActions {
    /// AppDelegate bağlar: Missing'in kendi araçları
    @MainActor static var screenshot: () -> Void = {}
    @MainActor static var screenshotArea: () -> Void = {}
    @MainActor static var record: () -> Void = {}
    @MainActor static var scrollingCapture: () -> Void = {}
    @MainActor static var tile: () -> Void = {}

    // MARK: Çalıştır

    @MainActor static func perform(_ a: MouseAction, pid: pid_t) {
        let cmd = CGEventFlags.maskCommand
        switch a.kind {
        case .none: break
        case .missionControl: dock("com.apple.expose.awake", fallback: "Mission Control")
        case .appExpose: dock("com.apple.expose.front.awake", fallback: nil)
        case .showDesktop: dock("com.apple.showdesktop.awake", fallback: nil)
        case .launchpad: dock("com.apple.launchpad.toggle", fallback: "Launchpad")
        case .spaceLeft: symbolicHotkey(79, fallbackKey: 123)
        case .spaceRight: symbolicHotkey(81, fallbackKey: 124)
        case .spotlight: key(MouseKeys.code(" "), cmd)
        case .lockScreen: key(MouseKeys.code("q"), [.maskCommand, .maskControl])
        case .screenshot: screenshot()
        case .screenshotArea: screenshotArea()
        case .record: record()
        case .scrollingCapture: scrollingCapture()
        case .tile: tile()
        case .back: navigate(back: true, pid: pid)
        case .forward: navigate(back: false, pid: pid)
        case .closeWindow: key(MouseKeys.code("w"), cmd)
        case .minimizeWindow: key(MouseKeys.code("m"), cmd)
        case .hideApp: key(MouseKeys.code("h"), cmd)
        case .quitApp: key(MouseKeys.code("q"), cmd)
        case .fullScreen: key(MouseKeys.code("f"), [.maskCommand, .maskControl])
        case .nextWindow: key(MouseKeys.code("`"), cmd)
        case .leftClick: click(button: 0, at: cursor)
        case .rightClick: click(button: 1, at: cursor)
        case .middleClick: click(button: 2, at: cursor)
        case .doubleClick: click(button: 0, at: cursor, count: 2)
        case .scrollUp: lineScroll(dy: 3, dx: 0)
        case .scrollDown: lineScroll(dy: -3, dx: 0)
        case .scrollLeft: lineScroll(dy: 0, dx: 3)
        case .scrollRight: lineScroll(dy: 0, dx: -3)
        case .playPause: media(16)
        case .nextTrack: media(17)
        case .previousTrack: media(18)
        case .volumeUp: media(0)
        case .volumeDown: media(1)
        case .mute: media(7)
        case .brightnessUp: media(2)
        case .brightnessDown: media(3)
        case .copy: key(MouseKeys.code("c"), cmd)
        case .paste: key(MouseKeys.code("v"), cmd)
        case .cut: key(MouseKeys.code("x"), cmd)
        case .undo: key(MouseKeys.code("z"), cmd)
        case .redo: key(MouseKeys.code("z"), [.maskCommand, .maskShift])
        case .selectAll: key(MouseKeys.code("a"), cmd)
        case .shortcut:
            if let k = a.keyCode { key(k, CGEventFlags(rawValue: a.modifiers ?? 0)) }
        case .openApp:
            guard let t = a.target, !t.isEmpty else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: t), configuration: NSWorkspace.OpenConfiguration())
        case .openFile:
            guard let t = a.target, !t.isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: t))
        case .runScript:
            guard let t = a.target, !t.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", t]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
            }
        }
    }

    @MainActor private static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // MARK: Sistem

    private typealias DockNotify = @convention(c) (CFString, Int32) -> Void
    private static let dockNotify: DockNotify? = {
        guard let s = dlsym(dlopen(nil, RTLD_NOW), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(s, to: DockNotify.self)
    }()

    @MainActor private static func dock(_ name: String, fallback app: String?) {
        if let f = dockNotify { f(name as CFString, 0); return }
        if let app { NSWorkspace.shared.launchApplication(app) }
    }

    /// Kullanıcının sistemde tanımlı kısayolunu kullan (Sistem Ayarları › Klavye › Kısayollar)
    @MainActor private static func symbolicHotkey(_ id: Int, fallbackKey: Int) {
        let d = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        if let entry = d?["\(id)"] as? [String: Any],
           (entry["enabled"] as? Bool) ?? true,
           let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [Int], params.count == 3 {
            key(params[1], CGEventFlags(rawValue: UInt64(params[2])))
            return
        }
        key(fallbackKey, [.maskControl, .maskSecondaryFn, .maskNumericPad])
    }

    static func key(_ code: Int, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticTag)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Medya ve parlaklık tuşları (NX_KEYTYPE_*)
    @MainActor private static func media(_ k: Int) {
        for down in [true, false] {
            let data1 = (k << 16) | ((down ? 0xA : 0xB) << 8)
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    @MainActor static func zoom(in zoomIn: Bool) {
        key(MouseKeys.code(zoomIn ? "=" : "-"), .maskCommand)
    }

    // MARK: Fare

    /// Yutulan tuşun asıl tıklamasını geri ver (hareket / kaydırma olmadıysa)
    static func click(button: Int, at p: CGPoint, count: Int = 1) {
        let types: (CGEventType, CGEventType) = button == 0 ? (.leftMouseDown, .leftMouseUp)
            : button == 1 ? (.rightMouseDown, .rightMouseUp) : (.otherMouseDown, .otherMouseUp)
        let src = CGEventSource(stateID: .hidSystemState)
        for n in 1...count {
            for t in [types.0, types.1] {
                guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p,
                                      mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center) else { continue }
                e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticTag)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    static func postPixelScroll(dy: Double, dx: Double, pid: pid_t) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticTag)
        if pid > 1 { e.postToPid(pid) } else { e.post(tap: .cgSessionEventTap) }
    }

    @MainActor private static func lineScroll(dy: Int32, dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticTag)
        e.post(tap: .cgSessionEventTap)
    }

    /// İmlecin altında bağlantı / düğme var mı (orta tık otomatik kaydırma yerine normal çalışsın)
    static func isClickable(at p: CGPoint) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.08)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, var cur = el else { return false }
        let clickable: Set<String> = ["AXLink", "AXButton", "AXTab", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
                                      "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle"]
        for _ in 0..<4 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, clickable.contains(r) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let pr = parent, CFGetTypeID(pr) == AXUIElementGetTypeID() else { break }
            cur = pr as! AXUIElement
        }
        return false
    }

    // MARK: Geri / ileri

    /// Fare yan tuşlarını kendisi anlayan uygulamalar: olaya dokunulmaz
    static func handlesNavButtonsNatively(_ bundle: String) -> Bool {
        let prefixes = ["com.google.Chrome", "org.mozilla.", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.",
                        "com.operasoftware.", "com.vivaldi.", "com.microsoft.VSCode", "com.todesktop.", "com.jetbrains."]
        return prefixes.contains { bundle.hasPrefix($0) }
    }

    @MainActor static func navigate(back: Bool, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.bundleIdentifier == "com.apple.finder", FinderMouseNav.press(back: back, pid: pid) { return }
        key(MouseKeys.code(back ? "[" : "]"), .maskCommand)
    }
}

// MARK: - Göstergeler

@MainActor enum MouseIndicator {
    private static var pointerWindow: NSWindow?
    private static var autoWindow: NSWindow?

    private static func overlay(size: CGFloat, at p: CGPoint) -> NSWindow {
        // CG koordinatı (sol üst) → AppKit (sol alt)
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let r = NSRect(x: p.x - size / 2, y: h - p.y - size / 2, width: size, height: size)
        let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.hasShadow = false
        return w
    }

    /// ⌃'ye iki kez dokununca imlecin etrafında daralan halka
    static func showPointer() {
        pointerWindow?.close()
        let p = CGEvent(source: nil)?.location ?? .zero
        let w = overlay(size: 220, at: p)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 10, y: 10, width: 200, height: 200), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor(Brand.red).cgColor
        ring.lineWidth = 5
        ring.frame = v.bounds
        v.layer?.addSublayer(ring)
        w.contentView = v
        w.orderFrontRegardless()
        pointerWindow = w
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 0.12
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0.2
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 0.55
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: 110, y: 110)
        ring.bounds = v.bounds
        ring.add(g, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pointerWindow === w { w.close(); pointerWindow = nil }
        }
    }

    /// Otomatik kaydırmanın başladığı nokta
    static func showAutoScroll(at p: CGPoint) {
        autoWindow?.close()
        let w = overlay(size: 34, at: p)
        let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        v.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        v.contentTintColor = .white
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        v.layer?.cornerRadius = 17
        w.contentView = v
        w.orderFrontRegardless()
        autoWindow = w
    }

    static func hideAutoScroll() {
        autoWindow?.close(); autoWindow = nil
    }
}
