import AppKit
import Carbon

// MARK: - Mouse: ayar modeli
//
// LinearMouse (imleç, kaydırma modları, tuşlar) ve Mos'un (yumuşak kaydırma, uygulama istisnaları)
// yaptıkları tek bir modelde. Her ayar dört katmanda yazılabilir:
//   global → cihaz → ekran → uygulama   (sağdaki soldakini ezer)
// Katmanda boş (nil) bırakılan ayar alttakinden gelir; hiçbir katmanda yoksa varsayılan kullanılır.
// Çakışan özellikler (ters kaydırma, modifier tuşlar, tuş eşleme, uygulama ayarı) tek kopyadır.

enum ScrollMode: String, Codable, CaseIterable {
    case accelerated, lines, pixels
}

enum PointerMode: String, Codable, CaseIterable {
    case system, custom
}

/// Bir tuş ya da fare tuşu (modifier tuşlar dahil). Klavye için sanal tuş kodu, fare için tuş numarası (0 sol, 1 sağ, 2 orta, 3 geri, 4 ileri…).
struct MouseTrigger: Codable, Hashable {
    enum Kind: String, Codable { case key, mouse }
    var kind: Kind
    var code: Int
    /// Ek modifier'lar (sadece eşlemelerde; CGEventFlags'in ⌘⇧⌥⌃ kısmı)
    var modifiers: UInt64 = 0

    static func key(_ c: Int, _ m: UInt64 = 0) -> MouseTrigger { MouseTrigger(kind: .key, code: c, modifiers: m) }
    static func mouse(_ c: Int, _ m: UInt64 = 0) -> MouseTrigger { MouseTrigger(kind: .mouse, code: c, modifiers: m) }

    /// Modifier tuşları: sol/sağ sanal tuş kodları
    static let modifierKeyCodes: [Int: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
    ]
    var isModifierKey: Bool { kind == .key && Self.modifierKeyCodes[code] != nil }

    var title: String {
        let mods = MouseTrigger.modifierSymbols(modifiers)
        switch kind {
        case .mouse:
            let names = [0: L("Sol tık"), 1: L("Sağ tık"), 2: L("Orta tuş"), 3: L("Geri tuşu"), 4: L("İleri tuşu")]
            return mods + (names[code] ?? L("Tuş %d", code + 1))
        case .key:
            return mods + KeyNames.name(code)
        }
    }

    static func modifierSymbols(_ raw: UInt64) -> String {
        let f = CGEventFlags(rawValue: raw)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }
}

/// Kaydırma sırasında basılı tutulan tuşun etkisi (Mos'un dash/toggle/block'u + LinearMouse'un modifier eylemleri)
enum ScrollModifierAction: String, Codable, CaseIterable {
    case faster      // hızlandır (×scale)
    case swap        // dikey ↔ yatay
    case noSmooth    // yumuşatmayı geçici kapat
    case block       // kaydırmayı engelle
    case zoom        // ⌘+ / ⌘−
}

struct ScrollModifier: Codable, Hashable, Identifiable {
    var id = UUID()
    var trigger: MouseTrigger
    var action: ScrollModifierAction
    var scale: Double = 5
}

/// Tuşlara bağlanabilen eylemler (iki uygulamanın kütüphanelerinin birleşimi)
enum MouseActionKind: String, Codable, CaseIterable {
    case none
    // Sistem
    case missionControl, appExpose, showDesktop, launchpad, spaceLeft, spaceRight, spotlight, lockScreen
    // Missing'in kendi araçları
    case screenshot, screenshotArea, record, scrollingCapture, tile
    // Pencere / uygulama
    case back, forward, closeWindow, minimizeWindow, hideApp, quitApp, fullScreen, nextWindow
    // Fare
    case leftClick, rightClick, middleClick, doubleClick, scrollUp, scrollDown, scrollLeft, scrollRight
    // Medya / donanım tuşları
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    // Düzenleme
    case copy, paste, cut, undo, redo, selectAll
    // Özel
    case shortcut, openApp, openFile, runScript
}

struct MouseAction: Codable, Hashable {
    var kind: MouseActionKind = .none
    /// shortcut: sanal tuş kodu + modifier'lar
    var keyCode: Int? = nil
    var modifiers: UInt64? = nil
    /// openApp / openFile: yol, runScript: kabuk komutu
    var target: String? = nil

    static let none = MouseAction()
    static func of(_ k: MouseActionKind) -> MouseAction { MouseAction(kind: k) }
}

struct MouseMapping: Codable, Hashable, Identifiable {
    var id = UUID()
    var trigger: MouseTrigger
    var action: MouseAction
    var enabled = true
}

/// Bir katman: her alan nil ise alttaki katmandan gelir. Eksen bazlı ayarlar v (dikey) / h (yatay) önekli.
struct MouseLayer: Codable, Equatable {
    // Kaydırma: mod (LinearMouse)
    var vMode: ScrollMode?, hMode: ScrollMode?
    var vLines: Double?, hLines: Double?
    var vPixels: Double?, hPixels: Double?
    var vAccel: Double?, hAccel: Double?
    var vSpeed: Double?, hSpeed: Double?
    // Kaydırma: yumuşatma ve yön (Mos, eksen bazlı)
    var vSmooth: Bool?, hSmooth: Bool?
    var vReverse: Bool?, hReverse: Bool?
    var step: Double?, gain: Double?, duration: Double?
    var simTrackpad: Bool?
    var scrollModifiers: [ScrollModifier]?
    // İmleç (LinearMouse)
    var pointerMode: PointerMode?
    var disableAccel: Bool?
    var pointerAccel: Double?
    var pointerSpeed: Double?
    // Tuşlar (LinearMouse)
    var backForward: Bool?
    var switchPrimary: Bool?
    var debounce: Bool?
    var debounceMs: Double?
    var debounceButtons: [Int]?
    var autoScroll: Bool?
    var autoScrollButton: Int?
    var gesture: Bool?
    var gestureButton: Int?
    var gestureLeft: MouseAction?, gestureRight: MouseAction?, gestureUp: MouseAction?, gestureDown: MouseAction?
    var redirectToScroll: Bool?
    var redirectButton: Int?
    // Eşlemeler (Mos + LinearMouse)
    var mappings: [MouseMapping]?
    /// Sadece uygulama katmanı: bu uygulamada Mouse hiçbir şeye dokunmasın
    var disabled: Bool?

    static let defaults = MouseLayer(
        vMode: .accelerated, hMode: .accelerated, vLines: 3, hLines: 3, vPixels: 36, hPixels: 36,
        vAccel: 1, hAccel: 1, vSpeed: 0, hSpeed: 0,
        vSmooth: true, hSmooth: true, vReverse: false, hReverse: false,
        step: 33.6, gain: 2.7, duration: 4.35, simTrackpad: false,
        scrollModifiers: [
            ScrollModifier(trigger: .key(58), action: .faster, scale: 5),   // ⌥: hızlandır
            ScrollModifier(trigger: .key(56), action: .swap),               // ⇧: yatay
            ScrollModifier(trigger: .key(55), action: .noSmooth),           // ⌘: yumuşatma yok
        ],
        pointerMode: .system, disableAccel: false, pointerAccel: 0.6875, pointerSpeed: 0.5,
        backForward: true, switchPrimary: false, debounce: false, debounceMs: 50, debounceButtons: [0],
        autoScroll: false, autoScrollButton: 2,
        gesture: false, gestureButton: 4,
        gestureLeft: .of(.spaceLeft), gestureRight: .of(.spaceRight), gestureUp: .of(.missionControl), gestureDown: .of(.appExpose),
        redirectToScroll: false, redirectButton: 3,
        mappings: [], disabled: false)

    /// Bu katmanda bir şey ayarlanmış mı
    var isEmpty: Bool { self == MouseLayer() }

    /// Sağdaki katmanın dolu alanları soldakinin üstüne yazılır
    static func merge(_ layers: [MouseLayer]) -> MouseLayer {
        var out: [String: Any] = [:]
        for l in layers {
            guard let d = try? JSONEncoder().encode(l),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            for (k, v) in obj where !(v is NSNull) { out[k] = v }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: out),
              let l = try? JSONDecoder().decode(MouseLayer.self, from: d) else { return defaults }
        return l
    }
}

/// Katmanların hepsi çözülmüş, her alanı dolu ayar (olay hattı bunu okur)
struct MouseResolved {
    let l: MouseLayer
    init(_ l: MouseLayer) { self.l = l }

    func mode(_ vertical: Bool) -> ScrollMode { (vertical ? l.vMode : l.hMode) ?? .accelerated }
    func lines(_ v: Bool) -> Double { (v ? l.vLines : l.hLines) ?? 3 }
    func pixels(_ v: Bool) -> Double { (v ? l.vPixels : l.hPixels) ?? 36 }
    func accel(_ v: Bool) -> Double { (v ? l.vAccel : l.hAccel) ?? 1 }
    func speed(_ v: Bool) -> Double { (v ? l.vSpeed : l.hSpeed) ?? 0 }
    func smooth(_ v: Bool) -> Bool { (v ? l.vSmooth : l.hSmooth) ?? true }
    func reverse(_ v: Bool) -> Bool { (v ? l.vReverse : l.hReverse) ?? false }
    var step: Double { l.step ?? 33.6 }
    var gain: Double { l.gain ?? 2.7 }
    var simTrackpad: Bool { l.simTrackpad ?? false }
    /// Trackpad simülasyonu açıkken süre Mos'taki gibi 4.75'e kilitlenir
    var duration: Double { simTrackpad ? 4.75 : (l.duration ?? 4.35) }
    var scrollModifiers: [ScrollModifier] { l.scrollModifiers ?? [] }
    var disabled: Bool { l.disabled ?? false }
    var backForward: Bool { l.backForward ?? true }
    var switchPrimary: Bool { l.switchPrimary ?? false }
    var debounce: Bool { l.debounce ?? false }
    var debounceMs: Double { l.debounceMs ?? 50 }
    var debounceButtons: [Int] { l.debounceButtons ?? [0] }
    var autoScroll: Bool { l.autoScroll ?? false }
    var autoScrollButton: Int { l.autoScrollButton ?? 2 }
    var gesture: Bool { l.gesture ?? false }
    var gestureButton: Int { l.gestureButton ?? 4 }
    var redirectToScroll: Bool { l.redirectToScroll ?? false }
    var redirectButton: Int { l.redirectButton ?? 3 }
    var mappings: [MouseMapping] { (l.mappings ?? []).filter(\.enabled) }
}

struct MouseDeviceLayer: Codable, Identifiable, Equatable {
    var id: String { key }
    /// "vendor:product:seri" (seri yoksa boş)
    var key: String
    var name: String
    var layer = MouseLayer()
}

struct MouseDisplayLayer: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var layer = MouseLayer()
}

struct MouseAppLayer: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var path: String
    var layer = MouseLayer()
}

struct MouseConfig: Codable, Equatable {
    var version = 1
    var enabled = false
    var showPointerLocation = false
    var global = MouseLayer()
    var devices: [MouseDeviceLayer] = []
    var displays: [MouseDisplayLayer] = []
    var apps: [MouseAppLayer] = []

    /// Cihaz anahtarı "üretici:ürün:seri". Bazı fareler (Bluetooth) seri numarasını bildirmez; o zaman
    /// üretici ve ürün aynıysa aynı cihaz sayılır. Önce tam eşleşme aranır.
    static func sameDevice(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = a.split(separator: ":", omittingEmptySubsequences: false)
        let y = b.split(separator: ":", omittingEmptySubsequences: false)
        guard x.count == 3, y.count == 3, x[0] == y[0], x[1] == y[1] else { return false }
        return x[2].isEmpty || y[2].isEmpty
    }

    func deviceIndex(_ key: String) -> Int? {
        devices.firstIndex { $0.key == key } ?? devices.firstIndex { MouseConfig.sameDevice($0.key, key) }
    }

    /// Öncelik: uygulama > ekran > cihaz > global
    func resolve(device: String?, display: String?, app: String?) -> MouseResolved {
        var layers = [MouseLayer.defaults, global]
        if let device, let i = deviceIndex(device) { layers.append(devices[i].layer) }
        if let display, let d = displays.first(where: { $0.name == display }) { layers.append(d.layer) }
        if let app, let a = apps.first(where: { $0.bundleID == app }) { layers.append(a.layer) }
        return MouseResolved(MouseLayer.merge(layers))
    }

    /// Ayarlarda düzenlenen katmanın altındaki katmanlar (gösterilen "miras" değer için)
    func inherited(below scope: MouseScope) -> MouseLayer {
        switch scope {
        case .global: return MouseLayer.defaults
        case .device: return MouseLayer.merge([.defaults, global])
        case .display: return MouseLayer.merge([.defaults, global])
        case .app: return MouseLayer.merge([.defaults, global])
        }
    }

    func layer(_ scope: MouseScope) -> MouseLayer {
        switch scope {
        case .global: return global
        case .device(let k): return deviceIndex(k).map { devices[$0].layer } ?? MouseLayer()
        case .display(let n): return displays.first { $0.name == n }?.layer ?? MouseLayer()
        case .app(let b): return apps.first { $0.bundleID == b }?.layer ?? MouseLayer()
        }
    }

    mutating func setLayer(_ scope: MouseScope, _ l: MouseLayer, name: String = "", path: String = "") {
        switch scope {
        case .global: global = l
        case .device(let k):
            if let i = deviceIndex(k) { devices[i].layer = l }
            else { devices.append(MouseDeviceLayer(key: k, name: name, layer: l)) }
        case .display(let n):
            if let i = displays.firstIndex(where: { $0.name == n }) { displays[i].layer = l }
            else { displays.append(MouseDisplayLayer(name: n, layer: l)) }
        case .app(let b):
            if let i = apps.firstIndex(where: { $0.bundleID == b }) { apps[i].layer = l }
            else { apps.append(MouseAppLayer(bundleID: b, name: name, path: path, layer: l)) }
        }
    }
}

/// Ayarlarda hangi katman düzenleniyor
enum MouseScope: Hashable {
    case global
    case device(String)
    case display(String)
    case app(String)
}

// MARK: - Kayıt

enum MouseStore {
    private static let key = "mouse.config"

    static func load() -> MouseConfig {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(MouseConfig.self, from: d) else { return MouseConfig() }
        return c
    }

    static func save(_ c: MouseConfig) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    static func export(_ c: MouseConfig) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(c)
    }
}

// MARK: - Tuş adları

enum KeyNames {
    static func name(_ code: Int) -> String {
        let fixed: [Int: String] = [
            55: "⌘", 54: L("Sağ ⌘"), 56: "⇧", 60: L("Sağ ⇧"), 58: "⌥", 61: L("Sağ ⌥"), 59: "⌃", 62: L("Sağ ⌃"), 63: "fn",
            36: "↩", 48: "⇥", 49: L("Boşluk"), 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        if let f = fixed[code] { return f }
        if let c = character(for: code) { return c.uppercased() }
        return L("Tuş %d", code)
    }

    /// Geçerli klavye düzeninde bu tuşun yazdığı karakter
    static func character(for code: Int) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let r = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            guard r == noErr, len > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: len)
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
    }

    /// Geçerli düzende bu karakteri yazan tuş (⌘+ / ⌘[ gibi kısayollar düzenden bağımsız çalışsın)
    static func keyCode(for char: String) -> Int? {
        for code in 0..<128 where character(for: code) == char { return code }
        return nil
    }
}
