import Cocoa
import SwiftUI
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Uyanık tut
//
// Ekranın kapanmasını ve Mac'in uyumasını engeller: süresiz, bir süre boyunca ya da bir uygulama açık kaldıkça.
// Aynı anda tek bir seçim geçerlidir.
// macOS'un kendi güç isteği (IOPMAssertion) kullanılır: yönetici izni gerekmez ve kapak kapanınca
// Mac yine uyur. Kapak kapanınca ya da Mac uyuyunca oturum da biter; uyanınca kendiliğinden sürmez.
//
// İsteğe bağlı "kapak kapalıyken de çalış": macOS'un uykusu pmset disablesleep ile kapatılır (bir kez
// yönetici izni). Çantada açık kalmasın diye kapak kapalıyken şarjdan çekilince, harici ekran çıkınca,
// süre sınırı dolunca ya da pil azalınca oturum biter ve Mac hemen uyutulur.

enum KeepAwakeSettings {
    private static let d = UserDefaults.standard
    private static func flag(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    static var enabled: Bool {
        get { flag("keepAwake.enabled", true) }
        set { d.set(newValue, forKey: "keepAwake.enabled") }
    }
    /// Ekran kapanabilsin, sadece Mac uyumasın
    static var allowDisplaySleep: Bool {
        get { flag("keepAwake.allowDisplaySleep", false) }
        set { d.set(newValue, forKey: "keepAwake.allowDisplaySleep") }
    }
    /// Kısayol ve tek tıkla açınca kullanılan süre
    static var defaultDuration: KeepAwakeDuration {
        get { KeepAwakeDuration(rawValue: d.integer(forKey: "keepAwake.defaultMinutes")) ?? .forever }
        set { d.set(newValue.rawValue, forKey: "keepAwake.defaultMinutes") }
    }
    /// ⌘⇧< kısayolu
    static var key: Bool {
        get { flag("keepAwake.key", true) }
        set { d.set(newValue, forKey: "keepAwake.key") }
    }
    static var startAtLaunch: Bool {
        get { flag("keepAwake.startAtLaunch", false) }
        set { d.set(newValue, forKey: "keepAwake.startAtLaunch") }
    }
    /// Sadece şarjdayken uyanık tut; pilde bekle
    static var onlyOnPower: Bool {
        get { flag("keepAwake.onlyOnPower", false) }
        set { d.set(newValue, forKey: "keepAwake.onlyOnPower") }
    }
    static var batteryStop: Bool {
        get { flag("keepAwake.batteryStop", true) }
        set { d.set(newValue, forKey: "keepAwake.batteryStop") }
    }
    static var batteryThreshold: Int {
        get { d.object(forKey: "keepAwake.batteryThreshold") as? Int ?? 20 }
        set { d.set(newValue, forKey: "keepAwake.batteryThreshold") }
    }
    /// Kapak kapanınca ya da Mac uyuyunca oturumu bitir
    static var lidStop: Bool {
        get { flag("keepAwake.lidStop", true) }
        set { d.set(newValue, forKey: "keepAwake.lidStop") }
    }
    /// Kapak kapalıyken de çalış (bir kez yönetici izni ister)
    static var lidAwake: Bool {
        get { flag("keepAwake.lidAwake", false) }
        set { d.set(newValue, forKey: "keepAwake.lidAwake") }
    }
    /// Kapak kapalıyken: şarjdan çekilince dur
    static var lidPowerOnly: Bool {
        get { flag("keepAwake.lidPowerOnly", true) }
        set { d.set(newValue, forKey: "keepAwake.lidPowerOnly") }
    }
    /// Kapak kapalıyken en fazla kaç dakika (0 = sınırsız)
    static var lidLimitMinutes: Int {
        get { d.object(forKey: "keepAwake.lidLimitMinutes") as? Int ?? 120 }
        set { d.set(newValue, forKey: "keepAwake.lidLimitMinutes") }
    }
    /// macOS'ta uykuyu biz kapattık (çökme sonrası açılışta geri açmak için)
    static var sleepDisabledByUs: Bool {
        get { flag("keepAwake.sleepDisabledByUs", false) }
        set { d.set(newValue, forKey: "keepAwake.sleepDisabledByUs") }
    }
    static var notch: Bool {
        get { flag("keepAwake.notch", true) }
        set { d.set(newValue, forKey: "keepAwake.notch") }
    }
}

/// Hazır süreler (ham değer: dakika; 0 = süresiz)
enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case forever = 0, m15 = 15, m30 = 30, h1 = 60, h2 = 120, h5 = 300
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forever: return L("Süresiz")
        case .m15: return L("15 dakika")
        case .m30: return L("30 dakika")
        case .h1: return L("1 saat")
        case .h2: return L("2 saat")
        case .h5: return L("5 saat")
        }
    }

    /// Menüdeki dar düğmeler için
    var short: String {
        switch self {
        case .forever: return "∞"
        case .m15, .m30: return L("%d dk", rawValue)
        case .h1, .h2, .h5: return L("%d sa", rawValue / 60)
        }
    }
}

/// Aynı anda tek bir seçim: ya bir süre ya da bir uygulama açık kaldıkça
enum KeepAwakeChoice: Equatable {
    case duration(KeepAwakeDuration)
    case app(String)   // bundle kimliği
}

@MainActor final class KeepAwake {
    static let shared = KeepAwake()

    /// Durum değişti: simge, menü paneli ve Ayarlar yenilensin
    var onChange: (() -> Void)?
    /// Kısa bildirim (metin, simge)
    var onNotice: ((String, String) -> Void)?

    static let symbol = "cup.and.saucer.fill"

    /// Geçerli seçim (nil: kapalı)
    private(set) var choice: KeepAwakeChoice?
    /// Süreli oturumun bitişi (nil: süreli oturum yok, distantFuture: süresiz)
    private var manualUntil: Date?
    /// "Bu uygulama açıkken" oturumunun uygulaması
    private var appID: String?
    private var assertion: IOPMAssertionID = 0
    private var heldType: String?
    private var timer: Timer?
    private var source: CFRunLoopSource?
    private var wired = false
    private let notch = KeepAwakeNotch()
    /// Kapak kapalı çalışma: kapağın kapandığı an ve o anda harici ekran var mıydı
    private var lidClosedSince: Date?
    private var lidHadExternal = false
    private var lastState = ""

    // MARK: Durum

    private var hasManual: Bool { choice != nil }

    private static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Bir oturum var; pilde bekliyor olabilir
    var isOn: Bool { KeepAwakeSettings.enabled && hasManual }
    /// Şu an gerçekten uyanık tutuluyor
    var isHolding: Bool { assertion != 0 }

    /// Kalan süre: "Süresiz", "42 dk", "1 sa 5 dk"; süreli oturum yoksa nil
    var remainingText: String? {
        guard let until = manualUntil else { return nil }
        if until == .distantFuture { return L("Süresiz") }
        let mins = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return mins >= 60 ? L("%d sa %d dk", mins / 60, mins % 60) : L("%d dk", mins)
    }

    /// Menü ve Ayarlar için tek satır durum
    var statusText: String {
        guard isOn else { return L("Kapalı") }
        if !isHolding { return L("Pilde bekliyor") }
        if let appID { return L("%@ açıkken", Self.appName(appID)) }
        return remainingText ?? L("Açık")
    }

    private func clear() {
        choice = nil
        manualUntil = nil
        appID = nil
    }

    // MARK: Elle kullanım

    func begin(_ duration: KeepAwakeDuration, quiet: Bool = false) {
        guard KeepAwakeSettings.enabled else { return }
        clear()
        choice = .duration(duration)
        manualUntil = duration == .forever ? .distantFuture : Date().addingTimeInterval(Double(duration.rawValue) * 60)
        evaluate()
        // Pil ya da kapak kuralı oturumu hemen bitirdiyse onun bildirimi yeter
        guard hasManual, !quiet else { return }
        onNotice?(isHolding ? L("Uyanık tut: %@", duration.title) : L("Uyanık tut: pilde bekliyor"), Self.symbol)
    }

    /// Seçilen uygulama açık kaldıkça uyanık tut; uygulama kapanınca biter
    func begin(app bundleID: String, quiet: Bool = false) {
        guard KeepAwakeSettings.enabled, Self.isRunning(bundleID) else { return }
        clear()
        choice = .app(bundleID)
        appID = bundleID
        evaluate()
        guard hasManual, !quiet else { return }
        onNotice?(isHolding ? L("Uyanık tut: %@ açıkken", Self.appName(bundleID)) : L("Uyanık tut: pilde bekliyor"), Self.symbol)
    }

    /// Menüdeki tek seçim: aynısına tekrar basınca kapanır
    func select(_ c: KeepAwakeChoice) {
        if choice == c { end(); return }
        switch c {
        case .duration(let d): begin(d)
        case .app(let id): begin(app: id)
        }
    }

    func end(quiet: Bool = false) {
        let was = hasManual
        clear()
        evaluate()
        if was, !quiet { onNotice?(L("Uyanık tut kapandı"), "moon.zzz.fill") }
    }

    func toggle() {
        guard KeepAwakeSettings.enabled else { return }
        if hasManual { end() } else { begin(KeepAwakeSettings.defaultDuration) }
    }

    // MARK: Başlat / durdur (dinleyiciler)

    func start() {
        guard !wired else { evaluate(); return }
        wired = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<KeepAwake>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.evaluate() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.evaluate() }
            }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.systemWillSleep() }
        }
        // Kapak harici ekran takılıyken kapanırsa Mac uyumaz; ekran düzeni değişince kapağa bak
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.evaluate() }
        }
        // Önceki çalışma uykuyu kapalı bırakmış olabilir (çökme, zorla kapatma): geri aç
        if KeepAwakeSettings.sleepDisabledByUs { setSleepDisabled(false, wait: false) }
        if KeepAwakeSettings.enabled, KeepAwakeSettings.startAtLaunch {
            begin(KeepAwakeSettings.defaultDuration, quiet: true)
        } else {
            evaluate()
        }
    }

    /// Uygulama kapanırken: isteği bırak
    func shutdown() {
        timer?.invalidate(); timer = nil
        release()
        setSleepDisabled(false, wait: true)
        notch.hide()
    }

    private func systemWillSleep() {
        guard KeepAwakeSettings.lidStop else { return }
        clear()
        evaluate()
    }

    // MARK: Karar

    /// Tek karar noktası: kurallara bak, isteği al ya da bırak, göstergeleri yenile
    func evaluate() {
        defer {
            schedule()
            notch.update()
            // Yoklamalarda arayüzü boşuna yenileme: sadece görünen durum değişince haber ver
            let state = "\(isOn)|\(isHolding)|\(statusText)"
            if state != lastState { lastState = state; onChange?() }
        }
        guard KeepAwakeSettings.enabled else {
            clear()
            release()
            setSleepDisabled(false, wait: false)
            return
        }
        if let until = manualUntil, until <= Date() {
            clear()
            onNotice?(L("Uyanık tut süresi doldu"), "moon.zzz.fill")
        }
        if let appID, !Self.isRunning(appID) {
            clear()
            onNotice?(L("Uyanık tut kapandı"), "moon.zzz.fill")
        }
        let onBattery = PowerProfiles.shared.onBattery
        var blocked = false
        if KeepAwakeSettings.batteryStop, onBattery, let pct = Self.batteryPercent, pct <= KeepAwakeSettings.batteryThreshold {
            if hasManual {
                clear()
                onNotice?(L("Uyanık tut kapandı · pil %%%d", pct), "battery.25percent")
            }
            blocked = true
        }
        let lid = Self.lidClosed
        let lidMode = KeepAwakeSettings.lidAwake && Self.lidReady
        if !lid {
            lidClosedSince = nil
        } else if lidMode, hasManual {
            // Kapak kapalı çalışma: önlemlerden biri tutmazsa oturum biter ve Mac uyur
            if lidClosedSince == nil {
                lidClosedSince = Date()
                lidHadExternal = Self.externalDisplays > 0
            }
            let limit = KeepAwakeSettings.lidLimitMinutes
            let unplugged = KeepAwakeSettings.lidPowerOnly && onBattery
            let undocked = lidHadExternal && Self.externalDisplays == 0
            let timeUp = limit > 0 && Date().timeIntervalSince(lidClosedSince ?? Date()) >= Double(limit) * 60
            if unplugged || undocked || timeUp {
                clear()
                blocked = true
            }
        } else if KeepAwakeSettings.lidStop || lidMode {
            clear()
            blocked = true
        }
        if KeepAwakeSettings.onlyOnPower, onBattery { blocked = true }

        let holding = !blocked && hasManual
        if holding { hold() } else { release() }
        // Uykuyu ancak tutarken ve kapak kuralları elveriyorsa kapat; pilde "şarjdan çekilince dur" açıksa hiç kapatma
        let noSleep = holding && lidMode && !(KeepAwakeSettings.lidPowerOnly && onBattery)
        let wasOurs = KeepAwakeSettings.sleepDisabledByUs
        setSleepDisabled(noSleep, wait: false)
        // Kapak kapalıyken bıraktıysak Mac hemen uyusun (çantada açık kalmasın)
        if wasOurs, !noSleep, lid, Self.externalDisplays == 0 { Self.sleepNow() }
    }

    /// Süreli oturumda: kalan süreyi dakikada bir yenile, bitince kapat
    private func schedule() {
        timer?.invalidate(); timer = nil
        var wait: TimeInterval?
        if let until = manualUntil, until != .distantFuture { wait = max(0.5, min(until.timeIntervalSinceNow, 60)) }
        // Kapak kapalı çalışma hazırken kapağı, adaptörü ve harici ekranı 5 sn'de bir yokla
        if KeepAwakeSettings.sleepDisabledByUs { wait = min(wait ?? 5, 5) }
        guard let wait else { return }
        let t = Timer(timeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.evaluate() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Güç isteği

    private func hold() {
        let type = KeepAwakeSettings.allowDisplaySleep ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep"
        if assertion != 0, heldType == type { return }
        release()
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Missing: Keep Awake" as CFString, &id)
        guard ok == kIOReturnSuccess else { return }
        assertion = id
        heldType = type
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        heldType = nil
    }

    // MARK: Kapak kapalıyken çalışma (pmset disablesleep)

    static let lidSudoersPath = "/etc/sudoers.d/missing-pmset-lid"
    /// Bir kerelik kurulum yapılmış mı
    static var lidReady: Bool { FileManager.default.fileExists(atPath: lidSudoersPath) }

    private static let pmsetQueue = DispatchQueue(label: "missing.keepawake.pmset")

    /// macOS'un uykusunu kapat / geri aç (kurulumdaki dar izinle, şifresiz)
    private func setSleepDisabled(_ on: Bool, wait: Bool) {
        guard on != KeepAwakeSettings.sleepDisabledByUs, Self.lidReady else { return }
        KeepAwakeSettings.sleepDisabledByUs = on
        let work = { _ = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]) }
        if wait { Self.pmsetQueue.sync(execute: work) } else { Self.pmsetQueue.async(execute: work) }
    }

    private static func sleepNow() {
        pmsetQueue.async { _ = run("/usr/bin/pmset", ["sleepnow"]) }
    }

    /// Bir kez: sadece bu kullanıcı için "pmset -a disablesleep 0/1" izni. macOS yönetici şifresini kendi
    /// penceresinde sorar; kural visudo ile doğrulanmadan yerleştirilmez.
    @discardableResult
    static func configureLid() -> Bool {
        let raw = NSUserName()
        let user = raw.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } && !raw.isEmpty ? raw : "%admin"
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = """
        #!/bin/sh
        set -e
        TMP=$(/usr/bin/mktemp)
        /bin/cat > "$TMP" <<'RULE'
        # Missing: kapak kapalıyken uyanık tutmak için (sadece pmset disablesleep)
        \(rule)
        RULE
        /usr/sbin/visudo -c -f "$TMP" >/dev/null
        /usr/bin/install -o root -g wheel -m 0440 "$TMP" \(lidSudoersPath)
        /bin/rm -f "$TMP"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-lid-\(UUID().uuidString).sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        let src = "do shell script \"/bin/sh '\(url.path)'\" with administrator privileges"
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil && lidReady
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Takılı harici ekran sayısı
    static var externalDisplays: Int {
        NSScreen.screens.filter { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) == 0
        }.count
    }

    // MARK: Pil ve kapak

    /// Yerleşik pilin doluluğu (%), pili olmayan Mac'te nil
    static var batteryPercent: Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let cap = d[kIOPSMaxCapacityKey] as? Int, cap > 0 else { continue }
            return cur * 100 / cap
        }
        return nil
    }

    /// MacBook'un kapağı kapalı mı (masaüstü Mac'te hep false)
    static var lidClosed: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        let v = IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    // MARK: Uygulama listesi

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - Çentik göstergesi

/// Uyanık tutulurken çentiğin hemen altında küçük bir sekme: fincan ve kalan süre.
/// Tıklamaları geçirir; tam ekran uygulamalarda görünmez.
@MainActor final class KeepAwakeNotch {
    private var panel: NSPanel?
    private var host: NSHostingView<KeepAwakeNotchView>?

    func update() {
        let awake = KeepAwake.shared
        guard KeepAwakeSettings.enabled, KeepAwakeSettings.notch, awake.isHolding,
              let screen = NSScreen.screens.first(where: { SnapBar.notch(of: $0) != nil }),
              let n = SnapBar.notch(of: screen) else { hide(); return }
        // Süresizde sadece fincan; süreliyken kalan dakika da yazar
        let text = awake.remainingText.flatMap { $0 == L("Süresiz") ? nil : $0 }
        let view = KeepAwakeNotchView(text: text)
        if panel == nil { build(view) } else { host?.rootView = view }
        guard let panel, let host else { return }
        let size = host.fittingSize
        panel.setFrame(NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                              y: screen.frame.maxY - n.height - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build(_ view: KeepAwakeNotchView) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 18),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none   // ekran görüntülerine ve kayıtlara girmesin
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .stationary]
        let h = NSHostingView(rootView: view)
        p.contentView = h
        panel = p
        host = h
    }
}

struct KeepAwakeNotchView: View {
    let text: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: KeepAwake.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Brand.red)
            if let text {
                Text(text)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 17)
        .background(NotchShape(radius: 8).fill(Color.black))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
