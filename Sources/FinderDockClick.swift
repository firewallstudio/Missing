import Cocoa

// MARK: - Dock'taki Finder simgesi Dosyalar'ı açar
//
// macOS Dock'taki Finder simgesinin yerine başka uygulama koydurmaz. Bunun yerine Dock'ta Finder'a
// yapılan sol tıklama yakalanır ve Dosyalar açılır (açık pencere varsa öne gelir).
// Bir değiştirici tuş (⌥, ⌘, ⌃, ⇧) basılıyken tıklanırsa gerçek Finder açılır; sağ tıklama menüsü dokunulmaz.

enum FinderDockSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "files.finderDockClick") }
        set { UserDefaults.standard.set(newValue, forKey: "files.finderDockClick") }
    }
}

/// Yakalayıcının iş parçacığıyla paylaşılan durum
private final class FinderDockState: @unchecked Sendable {
    var lock = os_unfair_lock()
    var swallowUp = false
    var dockPid: pid_t = 0
    var tap: CFMachPort?
}

private let gFinderDock = FinderDockState()

private func finderDockCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let s = gFinderDock
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = s.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp {
        os_unfair_lock_lock(&s.lock)
        let swallow = s.swallowUp
        s.swallowUp = false
        os_unfair_lock_unlock(&s.lock)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
    let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    guard event.flags.intersection(mods).isEmpty else { return Unmanaged.passUnretained(event) }
    let p = event.location
    guard FinderDockClick.nearScreenEdge(p), FinderDockClick.isFinderDockItem(at: p, dockPid: s.dockPid) else {
        return Unmanaged.passUnretained(event)
    }
    os_unfair_lock_lock(&s.lock)
    s.swallowUp = true
    os_unfair_lock_unlock(&s.lock)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { FilesManager.shared.open() }
    }
    return nil
}

@MainActor final class FinderDockClick {
    static let shared = FinderDockClick()
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    nonisolated private static let finderPath = "/System/Library/CoreServices/Finder.app"

    private init() {
        // Dock yeniden başlarsa (killall Dock) yeni süreç numarasını al
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            gFinderDock.dockPid = app.processIdentifier
        }
    }

    /// Ayara göre başlatır ya da durdurur
    func apply() {
        if FinderDockSettings.enabled && FilesSettings.enabled && AXIsProcessTrusted() { start() } else { stop() }
    }

    private func start() {
        gFinderDock.dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        guard thread == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: finderDockCallback, userInfo: nil) else {
            return
        }
        gFinderDock.tap = tap
        let t = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.runLoop = rl } }
            CFRunLoopRun()
        }
        t.name = "Missing.finderDock"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func stop() {
        guard thread != nil else { return }
        if let tap = gFinderDock.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        gFinderDock.tap = nil
        if let rl = runLoop { CFRunLoopStop(rl) }
        runLoop = nil
        thread = nil
    }

    /// Dock ekranın altında, solunda ya da sağında: kenara yakın olmayan tıklamalara AX sorgusu yapma
    nonisolated static func nearScreenEdge(_ p: CGPoint) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return true }
        let margin: CGFloat = 160
        for id in ids.prefix(Int(n)) {
            let b = CGDisplayBounds(id)
            guard b.contains(p) else { continue }
            return p.y > b.maxY - margin || p.x < b.minX + margin || p.x > b.maxX - margin
        }
        return false
    }

    nonisolated static func isFinderDockItem(at p: CGPoint, dockPid: pid_t) -> Bool {
        guard dockPid != 0 else { return false }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid == dockPid else { return false }
        var sub: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub) == .success,
              sub as? String == "AXApplicationDockItem" else { return false }
        var url: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &url) == .success else { return false }
        let u = (url as? URL) ?? (url as? NSURL).map { $0 as URL }
        return u?.standardizedFileURL.path.hasPrefix(finderPath) == true
    }
}
