import Cocoa
import IOKit.ps

// MARK: - Pil / şarj profilleri (sadece MacBook Pro 14" M4 Pro)
//
// Fişten çekilince: ekran "Apple Display (P3-600 nits)" ayarına ve 60 Hz'e iner, düşük güç modu.
// Şarja takılınca: "Apple XDR Display (P3-1600 nits)", ProMotion (120 Hz) ve yüksek güç modu.
// Güç modu macOS'un kendi pil / şarj ayarıyla yapılır (bir kez yönetici izni); macOS geçişi kendisi yapar.
// Diğer Mac'lerde bu özelliğin hiçbir parçası görünmez ve çalışmaz.

enum PowerProfileSettings {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "power.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "power.enabled") }
    }
    /// Şarj takılıp çıkarılınca kendiliğinden geç
    static var auto: Bool {
        get { d.object(forKey: "power.auto") as? Bool ?? true }
        set { d.set(newValue, forKey: "power.auto") }
    }
}

enum PowerProfile {
    case saver, performance

    var title: String { self == .saver ? L("Tasarruf") : L("Performans") }
    var detail: String { self == .saver ? L("600 nit · 60 Hz · Düşük güç") : L("1600 nit · ProMotion · Yüksek güç") }
    var symbol: String { self == .saver ? "leaf.fill" : "bolt.fill" }
    /// Ekran ayarının adında aranan parlaklık
    var nits: String { self == .saver ? "600 nits" : "1600 nits" }
    var hz: Double { self == .saver ? 60 : 120 }
}

@MainActor final class PowerProfiles: ObservableObject {
    static let shared = PowerProfiles()

    /// Bu Mac MacBook Pro 14" M4 Pro mu (model kimliği ya da çip + 14" yerleşik ekran)
    static let supported: Bool = {
        let model = sysctl("hw.model")
        if model == "Mac16,8" { return true }
        guard sysctl("machdep.cpu.brand_string") == "Apple M4 Pro" else { return false }
        let d = CGMainDisplayID()
        guard CGDisplayIsBuiltin(d) != 0 else { return false }
        let mm = CGDisplayScreenSize(d).width
        return (285...315).contains(mm)   // 14" (16" ≈ 345 mm)
    }()

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Görünür mü (desteklenen Mac + açık)
    static var active: Bool { supported && PowerProfileSettings.enabled }

    @Published private(set) var current: PowerProfile?
    private var source: CFRunLoopSource?
    private var lastOnAC: Bool?

    var onBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    func start() {
        guard Self.active, source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerProfiles>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
        lastOnAC = !onBattery
        if PowerProfileSettings.auto { apply(onBattery ? .saver : .performance) }
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = nil
    }

    private func powerChanged() {
        let ac = !onBattery
        guard ac != lastOnAC else { return }   // pil yüzdesi değişimi vb. değil, sadece fiş
        lastOnAC = ac
        // Elle yapılmış güç modu değişikliği varsa pil / şarj ayarı yerine otursun
        Self.sudoPmset([["-b", "powermode", "1"], ["-c", "powermode", "2"]])
        guard PowerProfileSettings.auto else { return }
        apply(ac ? .performance : .saver)
    }

    /// Menüden elle: diğer profile geç (güç modu dahil)
    func toggle() {
        apply(current == .saver ? .performance : .saver, manual: true)
    }

    /// manual: menüden ya da Ayarlar'dan; o anki güç kaynağının güç modu da değişir
    func apply(_ p: PowerProfile, manual: Bool = false) {
        guard Self.supported else { return }
        setPreset(p)
        setRefreshRate(p.hz)
        current = p
        if manual {
            let mode = p == .saver ? "1" : "2"
            Self.sudoPmset([[onBattery ? "-b" : "-c", "powermode", mode]])
        }
    }

    /// Kurulumda eklenen dar izinle (sadece pmset powermode) şifresiz çalıştır; izin yoksa sessizce geç
    private static func sudoPmset(_ commands: [[String]]) {
        guard FileManager.default.fileExists(atPath: sudoersPath) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for c in commands { _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + c) }
        }
    }

    // MARK: Ekran ayarı (MonitorPanel)

    private func setPreset(_ p: PowerProfile) {
        _ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW)
        guard let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return }
        let mgr = cls.init()
        guard let displays = mgr.value(forKey: "displays") as? [NSObject] else { return }
        let sel = NSSelectorFromString("setActivePreset:")
        for disp in displays {
            guard (disp.value(forKey: "hasPresets") as? Bool) == true, disp.responds(to: sel),
                  let presets = disp.value(forKey: "presets") as? [NSObject] else { continue }
            guard let target = presets.first(where: {
                ($0.value(forKey: "isValid") as? Bool) == true
                    && (($0.value(forKey: "presetName") as? String) ?? "").contains(p.nits)
                    && !(p == .saver && (($0.value(forKey: "presetName") as? String) ?? "").contains("1600"))
            }) else { continue }
            if let active = disp.value(forKey: "activePreset") as? NSObject,
               (active.value(forKey: "presetName") as? String) == (target.value(forKey: "presetName") as? String) { continue }
            disp.perform(sel, with: target)
        }
    }

    // MARK: Yenileme hızı

    private func setRefreshRate(_ hz: Double) {
        let d = CGMainDisplayID()
        guard CGDisplayIsBuiltin(d) != 0, let cur = CGDisplayCopyDisplayMode(d), abs(cur.refreshRate - hz) > 0.5 else { return }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
        guard let m = modes.first(where: {
            $0.width == cur.width && $0.height == cur.height && $0.pixelWidth == cur.pixelWidth && abs($0.refreshRate - hz) < 0.5
        }) else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    // MARK: Güç modu (macOS'un pil / şarj ayarı)

    /// macOS'ta pilde düşük güç (1), şarjda yüksek güç (2) ayarlı mı
    var powerModesConfigured: Bool {
        let out = Self.run("/usr/bin/pmset", ["-g", "custom"])
        var battery: String?, ac: String?
        var section = ""
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Battery Power") { section = "b"; continue }
            if t.hasPrefix("AC Power") { section = "c"; continue }
            let parts = t.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "powermode" else { continue }
            if section == "b" { battery = String(parts[1]) } else if section == "c" { ac = String(parts[1]) }
        }
        return battery == "1" && ac == "2"
    }

    static let sudoersPath = "/etc/sudoers.d/missing-pmset"

    /// Kurulum tam mı: güç modları ayarlı ve elle geçiş için izin kuralı yerinde
    var fullyConfigured: Bool { powerModesConfigured && FileManager.default.fileExists(atPath: Self.sudoersPath) }

    /// Bir kez: pilde düşük güç, şarjda yüksek güç + elle geçiş için dar izin kuralı
    /// (sadece bu kullanıcı, sadece "pmset -b/-c powermode 0/1/2"). macOS yönetici şifresini kendi penceresinde sorar.
    /// Kural visudo ile doğrulanmadan yerleştirilmez.
    @discardableResult
    func configurePowerModes() -> Bool {
        let raw = NSUserName()
        let user = raw.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } && !raw.isEmpty ? raw : "%admin"
        let cmds = ["-b", "-c"].flatMap { s in ["0", "1", "2"].map { "/usr/bin/pmset \(s) powermode \($0)" } }
        let rule = "\(user) ALL=(root) NOPASSWD: " + cmds.joined(separator: ", ")
        let script = """
        #!/bin/sh
        set -e
        /usr/bin/pmset -b powermode 1
        /usr/bin/pmset -c powermode 2
        TMP=$(/usr/bin/mktemp)
        /bin/cat > "$TMP" <<'RULE'
        # Missing: pil / şarj güç modunu elle değiştirmek için (sadece pmset powermode)
        \(rule)
        RULE
        /usr/sbin/visudo -c -f "$TMP" >/dev/null
        /usr/bin/install -o root -g wheel -m 0440 "$TMP" \(Self.sudoersPath)
        /bin/rm -f "$TMP"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-power-\(UUID().uuidString).sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        let src = "do shell script \"/bin/sh '\(url.path)'\" with administrator privileges"
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        objectWillChange.send()
        return err == nil
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
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
}
