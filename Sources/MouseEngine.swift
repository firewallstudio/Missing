import AppKit
import CoreVideo

// MARK: - Mouse: tek olay hattı
//
// Fare özelliğinin bütün işi tek bir olay yakalayıcıdan ve tek bir işleme hattından geçer:
// kaydırma, tuşlar ve tuş eşlemeleri. Yakalayıcı kendi yüksek öncelikli thread'inde çalışır
// (ana thread meşgulken kaydırma takılmasın, ⌘Tab'ın yakalayıcısı da yavaşlamasın).
//
// Yakalayıcı "annotated session" seviyesinde durur: olayın hangi uygulamaya gittiği (imlecin altındaki
// uygulama) burada bellidir. Kendi ürettiğimiz olaylar `eventSourceUserData` ile işaretlenir ve
// tekrar işlenmez.

/// Missing Mouse'un ürettiği olayların işareti ("MISSMOUS")
let mouseSyntheticTag: Int64 = 0x4D49_5353_4D4F_5553

final class MouseEngine: @unchecked Sendable {
    static let shared = MouseEngine()

    private var lock = os_unfair_lock()
    private var _config = MouseStore.load()
    private var cache: [String: MouseResolved] = [:]
    private var bundleCache: [pid_t: String] = [:]

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private(set) var isRunning = false

    let scroller = SmoothScroller()

    // Olay thread'inin durumu (sadece o thread'de değişir)
    private var heldKeys = Set<Int>()
    private var heldButtons = Set<Int>()
    private var scrolledWhileHeld = false
    private var lastDown: [Int: CFAbsoluteTime] = [:]
    private var swallowUp = Set<Int>()
    private var lastControlTap: CFAbsoluteTime = 0
    private var lastZoom: CFAbsoluteTime = 0
    // Tuş basılıyken sürükleme hareketi
    private var gestureButton: Int?
    private var gestureAccum = CGPoint.zero
    private var gestureFired = false
    private var gestureR: MouseResolved?
    // Tuşla imleci kaydırmaya çevirme
    private var redirectButton: Int?
    private var redirectMoved = false
    private var redirectPid: pid_t = 0
    // Orta tuşla otomatik kaydırma
    private var autoScroll: AutoScrollState?

    var config: MouseConfig {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _config
    }

    /// Ayarlar değişti: kaydet, önbelleği boşalt, imleç ayarlarını uygula
    @MainActor func update(_ c: MouseConfig) {
        os_unfair_lock_lock(&lock)
        _config = c
        cache.removeAll()
        os_unfair_lock_unlock(&lock)
        MouseStore.save(c)
        MouseKeys.refresh()
        if c.enabled && !isRunning { start() }
        else if !c.enabled && isRunning { stop() }
        else if isRunning { MousePointer.shared.apply() }
    }

    // MARK: Başlat / durdur

    @MainActor func start() {
        guard !isRunning, config.enabled, AXIsProcessTrusted() else { return }
        isRunning = true
        MouseScreens.refresh()
        MouseKeys.refresh()
        MouseDevices.shared.start()
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.firewallstudio.missing.mouse"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        MousePointer.shared.apply()
    }

    @MainActor func stop() {
        guard isRunning else { return }
        isRunning = false
        scroller.stop()
        if let rl = runLoop {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else { return }
                self.endAutoScroll()
                if self.redirectButton != nil { CGAssociateMouseAndMouseCursorPosition(1) }
                self.redirectButton = nil
                if let tap = self.tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
                self.tap = nil
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(rl)
        }
        runLoop = nil
        thread = nil
        MousePointer.shared.restoreAll()
        MouseDevices.shared.stop()
        MouseIndicator.hideAutoScroll()
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: mouseTapCallback, userInfo: me) else {
            isRunning = false
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        // Sessizce kapanmış yakalayıcıyı geri aç (macOS bazen zaman aşımında kapatır)
        let keeper = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0) { [weak self] _ in
            guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), keeper, .commonModes)
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(keeper)
    }

    // MARK: Çözümleme

    func bundleID(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        os_unfair_lock_lock(&lock)
        if let b = bundleCache[pid] { os_unfair_lock_unlock(&lock); return b }
        os_unfair_lock_unlock(&lock)
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        os_unfair_lock_lock(&lock)
        if bundleCache.count > 200 { bundleCache.removeAll() }
        bundleCache[pid] = b
        os_unfair_lock_unlock(&lock)
        return b
    }

    private func resolved(device: MouseDevice?, display: String?, app: String?) -> MouseResolved {
        let key = "\(device?.key ?? "")|\(display ?? "")|\(app ?? "")"
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if let r = cache[key] { return r }
        let r = _config.resolve(device: device?.key, display: display, app: app)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = r
        return r
    }

    private func resolve(_ e: CGEvent, _ dev: MouseDevice?) -> (MouseResolved, pid_t) {
        let pid = pid_t(e.getIntegerValueField(.eventTargetUnixProcessID))
        let app = bundleID(pid)
        return (resolved(device: dev, display: MouseScreens.name(at: e.location), app: app), pid)
    }

    // MARK: Olay hattı

    func handle(_ type: CGEventType, _ e: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return e
        default: break
        }
        if e.getIntegerValueField(.eventSourceUserData) == mouseSyntheticTag { return e }
        switch type {
        case .flagsChanged: return flags(e)
        case .keyDown, .keyUp: return key(type, e)
        case .scrollWheel: return scroll(e)
        default: return button(type, e)
        }
    }

    private func flags(_ e: CGEvent) -> CGEvent? {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        // ⌃'ye iki kez dokununca imlecin yeri gösterilir
        if code == 59 || code == 62, e.flags.contains(.maskControl),
           !e.flags.contains(.maskCommand), !e.flags.contains(.maskAlternate), !e.flags.contains(.maskShift) {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastControlTap < 0.35, config.showPointerLocation {
                lastControlTap = 0
                DispatchQueue.main.async { MouseIndicator.showPointer() }
            } else {
                lastControlTap = now
            }
        }
        return e
    }

    private func key(_ type: CGEventType, _ e: CGEvent) -> CGEvent? {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let down = type == .keyDown
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        // Klavye tetikleyicili eşlemeler (öndeki uygulamaya göre)
        let pid = pid_t(e.getIntegerValueField(.eventTargetUnixProcessID))
        let r = resolved(device: nil, display: MouseScreens.name(at: e.location), app: bundleID(pid))
        guard !r.disabled else { return e }
        let mods = e.flags.rawValue & MouseKeys.modifierMask
        if let m = r.mappings.first(where: { $0.trigger.kind == .key && $0.trigger.code == code && $0.trigger.modifiers == mods }) {
            if down, e.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let a = m.action
                DispatchQueue.main.async { MouseActions.perform(a, pid: pid) }
            }
            return nil
        }
        return e
    }

    // MARK: Kaydırma

    private func scroll(_ e: CGEvent) -> CGEvent? {
        let dev = mouseDeviceTable.device(for: e)
        // Trackpad, Magic Mouse ve faz bilgisi taşıyan (sürekli) olaylar olduğu gibi geçer
        if let dev, dev.category != .mouse { return e }
        if e.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            || e.getIntegerValueField(.scrollWheelEventScrollCount) != 0 { return e }
        let (r, pid) = resolve(e, dev)
        guard !r.disabled else { return e }
        if !heldButtons.isEmpty { scrolledWhileHeld = true }

        // Basılı tuşların etkisi
        var faster = 1.0, swap = false, noSmooth = false, zoom = false
        var strip: CGEventFlags = []
        for m in r.scrollModifiers where isHeld(m.trigger, e.flags) {
            switch m.action {
            case .faster: faster *= m.scale; strip.formUnion(MouseTrigger.modifierKeyCodes[m.trigger.code] ?? [])
            case .swap: swap = true; strip.formUnion(MouseTrigger.modifierKeyCodes[m.trigger.code] ?? [])
            case .noSmooth: noSmooth = true
            case .block: return nil
            case .zoom: zoom = true
            }
        }
        if swap, Self.delta(e, axis: 2) == 0 { Self.swapAxes(e) }
        var v = Self.delta(e, axis: 1)
        var h = Self.delta(e, axis: 2)
        guard v != 0 || h != 0 else { return e }
        if zoom {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastZoom > 0.12, v != 0 {
                lastZoom = now
                let inZoom = v > 0
                DispatchQueue.main.async { MouseActions.zoom(in: inZoom) }
            }
            return nil
        }
        if !strip.isEmpty { e.flags = e.flags.subtracting(strip) }
        if r.reverse(true) { v = -v }
        if r.reverse(false) { h = -h }

        let lineV = abs(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let lineH = abs(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        let smoothV = v != 0 && r.smooth(true) && !noSmooth
        let smoothH = h != 0 && r.smooth(false) && !noSmooth
        var feed = (v: 0.0, h: 0.0)
        if smoothV { feed.v = Self.target(v, lines: lineV, vertical: true, r, faster) }
        if smoothH { feed.h = Self.target(h, lines: lineH, vertical: false, r, faster) }
        if smoothV || smoothH {
            scroller.feed(v: feed.v, h: feed.h, template: e, pid: pid, r: r)
        }
        // Yumuşatılmayan eksen: seçilen moda göre olayın kendisi değiştirilir
        if !smoothV { Self.write(e, axis: 1, value: v, mode: r.mode(true), r, faster, vertical: true) }
        if !smoothH { Self.write(e, axis: 2, value: h, mode: r.mode(false), r, faster, vertical: false) }
        if smoothV { Self.zero(e, axis: 1) }
        if smoothH { Self.zero(e, axis: 2) }
        // İki eksen de yumuşatılıyorsa asıl olay yutulur
        if (smoothV || v == 0) && (smoothH || h == 0) { return nil }
        return e
    }

    /// Olaydaki kaydırma miktarı: önce piksel, sonra sabit noktalı, sonra satır (Mos'taki sıra)
    static func delta(_ e: CGEvent, axis: Int) -> Double {
        let p = e.getDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        if p != 0 { return p }
        let f = e.getDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)
        if f != 0 { return f }
        return Double(e.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2))
    }

    /// Yumuşak kaydırmaya verilecek mesafe. İvmeli mod: Mos'un adım alt sınırı ve hız çarpanı.
    /// Satır / piksel mod: her çentik tam o kadar (yumuşatılarak) gider.
    static let lineHeight = 12.0
    static func target(_ d: Double, lines: Double, vertical: Bool, _ r: MouseResolved, _ faster: Double) -> Double {
        let sign: Double = d < 0 ? -1 : 1
        switch r.mode(vertical) {
        case .accelerated:
            var x = d * r.accel(vertical)
            if r.speed(vertical) != 0 { x += sign * r.speed(vertical) }
            if abs(x) < r.step { x = sign * r.step }
            return x * r.gain * faster
        case .lines:
            return sign * r.lines(vertical) * max(1, lines.rounded()) * lineHeight * faster
        case .pixels:
            return sign * r.pixels(vertical) * faster
        }
    }

    static func write(_ e: CGEvent, axis: Int, value: Double, mode: ScrollMode, _ r: MouseResolved, _ faster: Double, vertical: Bool) {
        let pd: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fd: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let dd: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let orig = delta(e, axis: axis)
        guard value != 0 else { return }
        let sign: Double = value < 0 ? -1 : 1
        switch mode {
        case .accelerated:
            // Ters çevirme / hızlandırma / ivme: bütün alanlar aynı oranla
            let k = (orig == 0 ? 1 : value / orig) * r.accel(vertical) * faster
            // Sıra önemli: satır alanı yazılınca macOS diğer ikisini yeniden hesaplar
            var p = e.getDoubleValueField(pd) * k
            if r.speed(vertical) != 0 { p += sign * r.speed(vertical) }
            let f = e.getDoubleValueField(fd) * k
            let d = Double(e.getIntegerValueField(dd)) * k
            e.setIntegerValueField(dd, value: Int64(d == 0 ? 0 : (abs(d) < 1 ? sign : d.rounded())))
            e.setDoubleValueField(fd, value: f)
            e.setDoubleValueField(pd, value: p)
        case .lines:
            let n = (r.lines(vertical) * faster).rounded()
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            e.setIntegerValueField(dd, value: Int64(sign * n))
            e.setDoubleValueField(fd, value: sign * n)
            e.setDoubleValueField(pd, value: sign * n * lineHeight)
        case .pixels:
            let px = r.pixels(vertical) * faster
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(dd, value: Int64(sign * max(1, (px / 10).rounded())))
            e.setDoubleValueField(fd, value: sign * px / 10)
            e.setDoubleValueField(pd, value: sign * px)
        }
    }

    /// Dikey kaydırmayı yataya taşı (bütün alanlarıyla)
    private static func swapAxes(_ e: CGEvent) {
        let d1 = e.getIntegerValueField(.scrollWheelEventDeltaAxis1), d2 = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let f1 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), f2 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let p1 = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), p2 = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        // Sıra önemli: önce satır, sonra sabit noktalı, en son piksel
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: d2)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: d1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: f2)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: f1)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: p2)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: p1)
    }

    private static func zero(_ e: CGEvent, axis: Int) {
        e.setDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2, value: 0)
        e.setDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2, value: 0)
        e.setIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2, value: 0)
    }

    private func isHeld(_ t: MouseTrigger, _ flags: CGEventFlags) -> Bool {
        switch t.kind {
        case .mouse: return heldButtons.contains(t.code)
        case .key:
            if let f = MouseTrigger.modifierKeyCodes[t.code] { return flags.contains(f) }
            return heldKeys.contains(t.code)
        }
    }

    // MARK: Tuşlar

    private func button(_ type: CGEventType, _ e: CGEvent) -> CGEvent? {
        let dev = mouseDeviceTable.device(for: e)
        if let dev, dev.category == .trackpad { return e }
        let (r, pid) = resolve(e, dev)
        guard !r.disabled else { return e }
        var type = type
        let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let up = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
        var btn = Int(e.getIntegerValueField(.mouseEventButtonNumber))
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged { btn = 0 }
        if type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged { btn = 1 }

        // 1. Birincil / ikincil tuş değişimi
        if r.switchPrimary, btn < 2 {
            let swapped: [CGEventType: CGEventType] = [
                .leftMouseDown: .rightMouseDown, .rightMouseDown: .leftMouseDown,
                .leftMouseUp: .rightMouseUp, .rightMouseUp: .leftMouseUp,
                .leftMouseDragged: .rightMouseDragged, .rightMouseDragged: .leftMouseDragged,
            ]
            if let t = swapped[type] {
                type = t
                e.type = t
                btn = 1 - btn
                e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(btn))
            }
        }

        // Otomatik kaydırma açıkken (tıklayarak başlatılmış) herhangi bir tık onu bitirir
        if let a = autoScroll, down, !a.holding || btn != a.button {
            endAutoScroll()
            swallowUp.insert(btn)
            return nil
        }

        // 2. Çift tıklama koruması: tuş çok kısa sürede tekrar basılırsa yok sayılır
        if down, r.debounce, r.debounceButtons.contains(btn) {
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastDown[btn], (now - last) * 1000 <= r.debounceMs {
                swallowUp.insert(btn)
                return nil
            }
            lastDown[btn] = now
        }
        if up, swallowUp.remove(btn) != nil { return nil }
        if down, btn == 0 { scroller.stop() }

        // 3. Kaydırma tuşu olarak kullanılan fare tuşları (basılıyken hızlandır / yön değiştir…)
        if btn >= 2, r.scrollModifiers.contains(where: { $0.trigger.kind == .mouse && $0.trigger.code == btn }) {
            if down { heldButtons.insert(btn); scrolledWhileHeld = false }
            if up {
                heldButtons.remove(btn)
                if !scrolledWhileHeld { MouseActions.click(button: btn, at: e.location) }
            }
            return nil
        }

        // 4. Tuşla imleci kaydırmaya çevir
        if r.redirectToScroll, btn == r.redirectButton {
            if down {
                redirectButton = btn; redirectMoved = false; redirectPid = pid
                CGAssociateMouseAndMouseCursorPosition(0)
                return nil
            }
            if up, redirectButton == btn {
                redirectButton = nil
                CGAssociateMouseAndMouseCursorPosition(1)
                if !redirectMoved { MouseActions.click(button: btn, at: e.location) }
                return nil
            }
        }
        if let rb = redirectButton, rb == btn, !down, !up {
            let dx = e.getDoubleValueField(.mouseEventDeltaX), dy = e.getDoubleValueField(.mouseEventDeltaY)
            if dx != 0 || dy != 0 {
                redirectMoved = true
                var sy = -dy * 2, sx = -dx * 2
                if r.reverse(true) { sy = -sy }
                if r.reverse(false) { sx = -sx }
                MouseActions.postPixelScroll(dy: sy, dx: sx, pid: redirectPid)
            }
            return nil
        }

        // 5. Tuş basılıyken sürükleme hareketi
        if r.gesture, btn == r.gestureButton, btn >= 2 {
            if down { gestureButton = btn; gestureAccum = .zero; gestureFired = false; gestureR = r; return nil }
            if up, gestureButton == btn {
                gestureButton = nil
                if !gestureFired, hypot(gestureAccum.x, gestureAccum.y) < 10 { MouseActions.click(button: btn, at: e.location) }
                return nil
            }
        }
        if let gb = gestureButton, gb == btn, !down, !up {
            gestureAccum.x += e.getDoubleValueField(.mouseEventDeltaX)
            gestureAccum.y += e.getDoubleValueField(.mouseEventDeltaY)
            if !gestureFired, let gr = gestureR, max(abs(gestureAccum.x), abs(gestureAccum.y)) >= 50 {
                gestureFired = true
                let a: MouseAction?
                if abs(gestureAccum.x) > abs(gestureAccum.y) { a = gestureAccum.x < 0 ? gr.l.gestureLeft : gr.l.gestureRight }
                else { a = gestureAccum.y < 0 ? gr.l.gestureUp : gr.l.gestureDown }
                if let a { DispatchQueue.main.async { MouseActions.perform(a, pid: pid) } }
            }
            return e
        }

        // 6. Orta tuşla otomatik kaydırma
        if r.autoScroll, btn == r.autoScrollButton, btn >= 2 {
            if down {
                if MouseActions.isClickable(at: e.location) { return e }   // bağlantı / düğme: normal orta tık
                beginAutoScroll(at: e.location, button: btn, pid: pid, r: r)
                return nil
            }
            if up, var a = autoScroll, a.button == btn {
                if a.moved { endAutoScroll() } else { a.holding = false; autoScroll = a }   // tıklama: açık kalır
                return nil
            }
            if autoScroll != nil, !down, !up {
                if let a = autoScroll, hypot(e.location.x - a.anchor.x, e.location.y - a.anchor.y) > 10 {
                    autoScroll?.moved = true
                }
                return e
            }
        }

        // 7. Eşlemeler (sol/sağ tık sadece modifier ile)
        let mods = e.flags.rawValue & MouseKeys.modifierMask
        if let m = r.mappings.first(where: { $0.trigger.kind == .mouse && $0.trigger.code == btn && $0.trigger.modifiers == mods
                                               && (btn >= 2 || mods != 0) }) {
            if down {
                let a = m.action
                DispatchQueue.main.async { MouseActions.perform(a, pid: pid) }
                swallowUp.insert(btn)
            }
            return down || up ? nil : e
        }

        // 8. Evrensel geri / ileri
        if r.backForward, btn == 3 || btn == 4 {
            let app = bundleID(pid) ?? ""
            if MouseActions.handlesNavButtonsNatively(app) { return e }
            if down {
                let back = btn == 3
                DispatchQueue.main.async { MouseActions.navigate(back: back, pid: pid) }
                swallowUp.insert(btn)
            }
            return down || up ? nil : e
        }
        return e
    }

    // MARK: Otomatik kaydırma

    private struct AutoScrollState {
        var anchor: CGPoint
        var button: Int
        var pid: pid_t
        var holding = true
        var moved = false
        var last: CFAbsoluteTime
        var carry = CGPoint.zero
        var reverseV: Bool
        var reverseH: Bool
        var timer: CFRunLoopTimer?
    }

    private func beginAutoScroll(at p: CGPoint, button: Int, pid: pid_t, r: MouseResolved) {
        endAutoScroll()
        var s = AutoScrollState(anchor: p, button: button, pid: pid, last: CFAbsoluteTimeGetCurrent(),
                                reverseV: r.reverse(true), reverseH: r.reverse(false))
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 1.0 / 60, 0, 0) { [weak self] _ in
            self?.autoScrollTick()
        }
        s.timer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        autoScroll = s
        DispatchQueue.main.async { MouseIndicator.showAutoScroll(at: p) }
    }

    private func endAutoScroll() {
        guard let a = autoScroll else { return }
        if let t = a.timer { CFRunLoopTimerInvalidate(t) }
        autoScroll = nil
        DispatchQueue.main.async { MouseIndicator.hideAutoScroll() }
    }

    /// Firefox'un otomatik kaydırma eğrisi: merkezden uzaklaştıkça hız üstel artar
    private func autoScrollTick() {
        guard var a = autoScroll else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(now - a.last, 0.1)
        a.last = now
        let p = CGEvent(source: nil)?.location ?? a.anchor
        func speed(_ offset: Double) -> Double {
            let steps = offset / 12
            guard abs(steps) > 1 else { return 0 }
            let s: Double = steps < 0 ? -1 : 1
            return (steps * abs(steps).squareRoot() - s) * elapsed / 0.02
        }
        var dy = -speed(p.y - a.anchor.y) + a.carry.y
        var dx = -speed(p.x - a.anchor.x) + a.carry.x
        if a.reverseV { dy = -dy }
        if a.reverseH { dx = -dx }
        let iy = dy.rounded(.towardZero), ix = dx.rounded(.towardZero)
        a.carry = CGPoint(x: dx - ix, y: dy - iy)
        autoScroll = a
        if iy != 0 || ix != 0 { MouseActions.postPixelScroll(dy: max(min(iy, 10000), -10000), dx: max(min(ix, 10000), -10000), pid: a.pid) }
    }
}

private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<MouseEngine>.fromOpaque(refcon).takeUnretainedValue()
    guard let out = engine.handle(type, event) else { return nil }
    return Unmanaged.passUnretained(out)
}

// MARK: - Yumuşak kaydırma (Mos davranışı, kendi uygulamamız)
//
// Her çentik bir "hedef" biriktirir; her ekran karesinde hedefe kalan mesafenin sabit bir oranı kadar
// ilerlenir (oran süreden: 1 − √(süre / 5.2)). Çıkış ayrıca α = 0.23'lük bir yumuşatmadan geçer.
// Yön değişince birikim sıfırlanır. Ekranın kendi yenileme hızıyla (120 Hz dahil) çalışır; kaydırma
// yokken ekran saati durur, işlemci kullanmaz.

/// Yumuşak kaydırmanın saf hesabı (zamanlayıcıdan ve olay göndermeden bağımsız; test edilebilir)
struct SmoothState {
    var buffer = [0.0, 0.0], current = [0.0, 0.0], prev = [0.0, 0.0], ema = [0.0, 0.0]
    var factor = 0.085
    var lastWheel: CFAbsoluteTime = 0
    var manualEnded = true
    var momentum = false
    var running = false
    var simTrackpad = false
    static let deadZone = 1.0

    /// Süreden kare başına ilerleme oranı: 1 − √(süre / 5.2), üç basamağa yuvarlanmış
    static func factor(duration: Double) -> Double {
        ((1 - (duration / 5.2).squareRoot()) * 1000).rounded() / 1000
    }

    /// Yeni çentik. Önce gönderilmesi gereken faz olaylarını (trackpad simülasyonu) döndürür.
    mutating func feed(v: Double, h: Double, now: CFAbsoluteTime, duration: Double, simTrackpad sim: Bool) -> [(Int64, Int64)] {
        var pre: [(Int64, Int64)] = []
        let newGesture = manualEnded || now - lastWheel >= 0.45 || !running
        simTrackpad = sim
        factor = Self.factor(duration: duration)
        if newGesture, sim {
            if momentum { pre.append((0, 3)) }
            pre.append((1, 0))
            momentum = false
        }
        for (i, d) in [v, h].enumerated() where d != 0 {
            // Aynı yönde birikir; yön değişince kalan kaydırma bırakılır
            if d * prev[i] > 0 { buffer[i] += d } else { buffer[i] = d; current[i] = 0; ema[i] = 0 }
            prev[i] = d
        }
        lastWheel = now
        manualEnded = false
        running = true
        return pre
    }

    struct Frame {
        var y = 0.0, x = 0.0
        var post = false
        var phase: Int64 = 0, momentum: Int64 = 0
        var extra: [(Int64, Int64)] = []
        var finished = false
    }

    /// Bir ekran karesi
    mutating func step(now: CFAbsoluteTime) -> Frame {
        var f = Frame()
        guard running else { return f }
        var out = [0.0, 0.0]
        for i in 0..<2 {
            let s = (buffer[i] - current[i]) * factor
            current[i] += s
            out[i] = ema[i]                      // bir kare gecikmeli çıkış
            ema[i] += 0.23 * (s - ema[i])
        }
        let residual = max(abs(buffer[0] - current[0]), abs(buffer[1] - current[1]))
        if !manualEnded, now - lastWheel > 0.18 {
            manualEnded = true
            if simTrackpad { f.extra.append((4, 0)) }
        }
        if simTrackpad {
            if manualEnded {
                if residual > Self.deadZone { f.momentum = momentum ? 2 : 1; momentum = true }
            } else {
                f.phase = 2                      // başlangıç fazı çentikle birlikte gönderildi
            }
        }
        let tiny = max(abs(out[0]), abs(out[1])) <= Self.deadZone
        f.y = out[0]; f.x = out[1]
        f.post = !tiny
        if manualEnded && residual <= Self.deadZone && tiny {
            f.finished = true
            if simTrackpad && momentum { f.extra.append((0, 3)) }
            self = SmoothState()
        }
        return f
    }
}

final class SmoothScroller: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var link: CVDisplayLink?
    private var state = SmoothState()
    private var template: CGEvent?
    private var pid: pid_t = 0
    private var bundle = ""
    private let postQueue = DispatchQueue(label: "com.firewallstudio.missing.scroll", qos: .userInteractive)

    func feed(v: Double, h: Double, template e: CGEvent, pid: pid_t, r: MouseResolved) {
        let bundle = MouseEngine.shared.bundleID(pid) ?? ""
        os_unfair_lock_lock(&lock)
        let start = !state.running
        let pre = state.feed(v: v, h: h, now: CFAbsoluteTimeGetCurrent(), duration: r.duration, simTrackpad: r.simTrackpad)
        template = e.copy()
        self.pid = pid
        self.bundle = bundle
        let tpl = template
        os_unfair_lock_unlock(&lock)
        for (sp, mp) in pre { post(tpl, 0, 0, phase: sp, momentum: mp) }
        if start { startLink(at: e.location) }
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        state = SmoothState()
        os_unfair_lock_unlock(&lock)
        stopLink()
    }

    private func startLink(at p: CGPoint) {
        stopLink()
        var l: CVDisplayLink?
        let display = MouseScreens.displayID(at: p) ?? CGMainDisplayID()
        guard CVDisplayLinkCreateWithCGDisplay(display, &l) == kCVReturnSuccess, let l else { return }
        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
            self?.frame()
            return kCVReturnSuccess
        }
        os_unfair_lock_lock(&lock); link = l; os_unfair_lock_unlock(&lock)
        CVDisplayLinkStart(l)
    }

    private func stopLink() {
        os_unfair_lock_lock(&lock)
        let l = link; link = nil
        os_unfair_lock_unlock(&lock)
        if let l { postQueue.async { CVDisplayLinkStop(l) } }
    }

    /// Her ekran karesinde (ekran saatinin thread'i)
    private func frame() {
        os_unfair_lock_lock(&lock)
        let sim = state.simTrackpad
        let f = state.step(now: CFAbsoluteTimeGetCurrent())
        let tpl = template, app = bundle
        os_unfair_lock_unlock(&lock)
        if f.post { post(tpl, f.y, f.x, phase: f.phase, momentum: f.momentum) }
        for (sp, mp) in f.extra { post(tpl, 0, 0, phase: sp, momentum: mp) }
        if f.finished {
            // Trackpad simülasyonu kapalıyken Chrome kaydırmanın bittiğini anlasın
            if !sim, app == "com.google.Chrome" { post(tpl, 0, 0, phase: 4, momentum: 0) }
            stopLink()
        }
    }

    private func post(_ tpl: CGEvent?, _ y: Double, _ x: Double, phase: Int64, momentum: Int64) {
        guard let tpl, let e = tpl.copy() else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Sıra önemli: satır alanı yazılınca macOS sabit noktalı ve piksel alanlarını yeniden hesaplar
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((y / 10).rounded(.towardZero)))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((x / 10).rounded(.towardZero)))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y / 10)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x / 10)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.setIntegerValueField(.eventSourceUserData, value: mouseSyntheticTag)
        let target = pid
        if target > 1 { e.postToPid(target) } else { e.post(tap: .cgSessionEventTap) }
    }
}
