import AppKit

// MARK: - Mouse: LinearMouse ve Mos ayarlarını içe aktarma
//
// LinearMouse: JSON ayar dosyası (schemes + if koşulları). Koşula göre katman seçilir:
// uygulama varsa uygulama, yoksa ekran, yoksa cihaz, hiçbiri yoksa genel.
// Mos: kendi tercih dosyası (eski 3.x ve yeni biçim). Uygulama listesindeki her yol, içindeki .app'e çevrilir.

enum MouseImport {
    struct Report {
        var ok: Bool
        var text: String
        var count = 0
        var notes: [String] = []
    }

    /// Bu Mac'teki başka fare uygulamalarının ayarlarını sırayla al (arayüzde adları geçmez)
    static func fromOtherApps(into c: inout MouseConfig) -> Report {
        var rules = 0, apps = 0, notes: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lmPaths = [home.appendingPathComponent(".config/linearmouse/linearmouse.json"),
                       home.appendingPathComponent("Library/Application Support/linearmouse/linearmouse.json")]
        if let url = lmPaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let d = try? Data(contentsOf: url) {
            let r = fromLinearMouse(d, into: &c)
            if r.ok { rules += r.count } else { notes.append(r.text) }
            notes.append(contentsOf: r.notes)
        }
        let m = fromMos(into: &c)
        if m.ok { rules += 1; apps += m.count; notes.append(contentsOf: m.notes) }
        guard rules > 0 else {
            return Report(ok: false, text: L("Bu Mac'te başka bir fare uygulamasının ayarı bulunamadı."))
        }
        var text = L("Önceki fare ayarların alındı: %d kural, %d uygulama.", rules, apps)
        if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
        return Report(ok: true, text: text)
    }

    // MARK: LinearMouse

    static func fromLinearMouse(_ data: Data, into c: inout MouseConfig) -> Report {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemes = root["schemes"] as? [[String: Any]] else {
            return Report(ok: false, text: L("Bu dosya tanınan bir fare ayarı değil."))
        }
        var used = 0, skipped: [String] = []
        for s in schemes {
            let cond: [String: Any] = (s["if"] as? [String: Any]) ?? ((s["if"] as? [[String: Any]])?.first ?? [:])
            var scope = MouseScope.global
            var name = "", path = ""
            if let app = cond["app"] as? String {
                scope = .app(app)
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                    path = url.path
                    name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                } else { name = app }
            } else if let display = cond["display"] as? String {
                scope = .display(display)
            } else if let dev = cond["device"] as? [String: Any] {
                let v = int(dev["vendorID"]), p = int(dev["productID"])
                if v != 0 || p != 0 {
                    scope = .device("\(v):\(p):\(dev["serialNumber"] as? String ?? "")")
                    name = dev["productName"] as? String ?? ""
                }
            }
            if cond["processName"] != nil || cond["processPath"] != nil || cond["parentApp"] != nil || cond["groupApp"] != nil {
                skipped.append(L("süreç koşulu"))
            }
            var l = c.layer(scope)
            applyScrolling(s["scrolling"] as? [String: Any], &l, &skipped)
            applyPointer(s["pointer"] as? [String: Any], &l)
            applyButtons(s["buttons"] as? [String: Any], &l, &skipped)
            c.setLayer(scope, l, name: name, path: path)
            used += 1
        }
        let uniq = Array(Set(skipped)).sorted()
        let note = uniq.isEmpty ? [] : [L("Alınamayanlar: %@.", uniq.joined(separator: ", "))]
        return Report(ok: used > 0, text: L("%d kural alındı.", used) + (note.first.map { " " + $0 } ?? ""), count: used, notes: note)
    }

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String {
            let t = s.lowercased()
            if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) ?? 0 }
            return Int(t) ?? 0
        }
        return 0
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// LinearMouse'ta her kaydırma ayarı ya tek değer ya da {vertical, horizontal}
    private static func axes(_ v: Any?) -> (Any?, Any?) {
        if let d = v as? [String: Any], d["vertical"] != nil || d["horizontal"] != nil { return (d["vertical"], d["horizontal"]) }
        return (v, v)
    }

    private static func applyScrolling(_ s: [String: Any]?, _ l: inout MouseLayer, _ skipped: inout [String]) {
        guard let s else { return }
        let (rv, rh) = axes(s["reverse"])
        if let b = rv as? Bool { l.vReverse = b }
        if let b = rh as? Bool { l.hReverse = b }
        let (dv, dh) = axes(s["distance"])
        func distance(_ d: Any?, _ vertical: Bool) {
            guard let d else { return }
            var mode: ScrollMode?
            if let str = d as? String {
                if str == "auto" { mode = .accelerated }
                else if str.hasSuffix("px"), let px = Double(str.dropLast(2)) {
                    mode = .pixels
                    if vertical { l.vPixels = px } else { l.hPixels = px }
                } else if let n = Double(str) {
                    mode = .lines
                    if vertical { l.vLines = n } else { l.hLines = n }
                }
            } else if let n = double(d) {
                mode = .lines
                if vertical { l.vLines = n } else { l.hLines = n }
            }
            if let mode { if vertical { l.vMode = mode } else { l.hMode = mode } }
        }
        distance(dv, true); distance(dh, false)
        let (av, ah) = axes(s["acceleration"])
        if let a = double(av) { l.vAccel = a }
        if let a = double(ah) { l.hAccel = a }
        let (sv, sh) = axes(s["speed"])
        if let x = double(sv) { l.vSpeed = x }
        if let x = double(sh) { l.hSpeed = x }
        let (smv, smh) = axes(s["smoothed"])
        if let d = smv as? [String: Any] { l.vSmooth = (d["enabled"] as? Bool) ?? true }
        if let d = smh as? [String: Any] { l.hSmooth = (d["enabled"] as? Bool) ?? true }
        if smv != nil || smh != nil { skipped.append(L("yumuşatma eğrileri (Missing'in yumuşatmasına çevrildi)")) }
        // Modifier tuşları (dikey olanlar; yatayda ayrı liste tutulmuyor)
        let (mv, _) = axes(s["modifiers"])
        if let m = mv as? [String: Any] {
            let keys = ["command": 55, "shift": 56, "option": 58, "control": 59]
            var list: [ScrollModifier] = []
            for (k, code) in keys {
                guard let a = m[k] else { continue }
                let type = (a as? String) ?? ((a as? [String: Any])?["type"] as? String) ?? ""
                switch type {
                case "changeSpeed":
                    let scale = double((a as? [String: Any])?["scale"]) ?? 2
                    list.append(ScrollModifier(trigger: .key(code), action: .faster, scale: scale))
                case "alterOrientation": list.append(ScrollModifier(trigger: .key(code), action: .swap))
                case "preventDefault": list.append(ScrollModifier(trigger: .key(code), action: .block))
                case "zoom", "zoomReversed", "pinchZoom", "pinchZoomReversed":
                    list.append(ScrollModifier(trigger: .key(code), action: .zoom))
                    if type.hasPrefix("pinch") { skipped.append(L("pinch zoom (⌘+ / ⌘− ile yakınlaştırmaya çevrildi)")) }
                default: break
                }
            }
            if !list.isEmpty { l.scrollModifiers = list.sorted { $0.trigger.code < $1.trigger.code } }
        }
    }

    private static func applyPointer(_ p: [String: Any]?, _ l: inout MouseLayer) {
        guard let p else { return }
        if let a = double(p["acceleration"]) { l.pointerAccel = a; l.pointerMode = .custom }
        if let s = double(p["speed"]) { l.pointerSpeed = s; l.pointerMode = .custom }
        if let d = p["disableAcceleration"] as? Bool { l.disableAccel = d }
        if let r = p["redirectsToScroll"] as? Bool, r { l.redirectToScroll = true }
    }

    private static func applyButtons(_ b: [String: Any]?, _ l: inout MouseLayer, _ skipped: inout [String]) {
        guard let b else { return }
        if let u = b["universalBackForward"] as? Bool { l.backForward = u }
        if b["universalBackForward"] is String { l.backForward = true }
        if let s = b["switchPrimaryButtonAndSecondaryButtons"] as? Bool { l.switchPrimary = s }
        if let d = b["clickDebouncing"] as? [String: Any] {
            l.debounce = true
            if let t = double(d["timeout"]) { l.debounceMs = t }
            if let bs = d["buttons"] as? [Int] { l.debounceButtons = bs }
        }
        if let a = b["autoScroll"] as? [String: Any] {
            l.autoScroll = (a["enabled"] as? Bool) ?? false
            if let t = a["trigger"] as? [String: Any], let btn = t["button"] as? Int { l.autoScrollButton = btn }
        }
        if let g = b["gesture"] as? [String: Any] {
            l.gesture = (g["enabled"] as? Bool) ?? false
            if let t = g["trigger"] as? [String: Any], let btn = t["button"] as? Int { l.gestureButton = btn }
            if let acts = g["actions"] as? [String: Any] {
                if let a = action(acts["left"]) { l.gestureLeft = a }
                if let a = action(acts["right"]) { l.gestureRight = a }
                if let a = action(acts["up"]) { l.gestureUp = a }
                if let a = action(acts["down"]) { l.gestureDown = a }
            }
        }
        if let maps = b["mappings"] as? [[String: Any]] {
            var out: [MouseMapping] = l.mappings ?? []
            var lost = 0
            for m in maps {
                // Eski düz biçim: {button, command, shift, option, control, action}
                var mods: UInt64 = 0
                if m["command"] as? Bool == true { mods |= CGEventFlags.maskCommand.rawValue }
                if m["shift"] as? Bool == true { mods |= CGEventFlags.maskShift.rawValue }
                if m["option"] as? Bool == true { mods |= CGEventFlags.maskAlternate.rawValue }
                if m["control"] as? Bool == true { mods |= CGEventFlags.maskControl.rawValue }
                guard let btn = m["button"] as? Int, let a = action(m["action"]) else { lost += 1; continue }
                out.append(MouseMapping(trigger: .mouse(btn, mods), action: a))
            }
            l.mappings = out
            if lost > 0 { skipped.append(L("%d eşleme (tekerlek / yeni biçim)", lost)) }
        }
    }

    /// LinearMouse eylem adı → Missing eylemi
    private static func action(_ v: Any?) -> MouseAction? {
        if let d = v as? [String: Any] {
            if let run = d["run"] as? String { return MouseAction(kind: .runScript, target: run) }
            if let keys = d["keyPress"] as? [String] { return shortcut(keys) }
            return nil
        }
        guard let s = v as? String else { return nil }
        let map: [String: MouseActionKind] = [
            "auto": .none, "none": .none,
            "missionControl": .missionControl, "missionControl.spaceLeft": .spaceLeft, "missionControl.spaceRight": .spaceRight,
            "appExpose": .appExpose, "launchpad": .launchpad, "showDesktop": .showDesktop,
            "mouse.button.left": .leftClick, "mouse.button.middle": .middleClick, "mouse.button.right": .rightClick,
            "mouse.button.back": .back, "mouse.button.forward": .forward, "mouse.button.leftDouble": .doubleClick,
            "mouse.wheel.scrollUp": .scrollUp, "mouse.wheel.scrollDown": .scrollDown,
            "mouse.wheel.scrollLeft": .scrollLeft, "mouse.wheel.scrollRight": .scrollRight,
            "media.playPause": .playPause, "media.next": .nextTrack, "media.previous": .previousTrack,
            "media.volumeUp": .volumeUp, "media.volumeDown": .volumeDown, "media.mute": .mute,
            "display.brightnessUp": .brightnessUp, "display.brightnessDown": .brightnessDown,
            "window.minimize": .minimizeWindow,
        ]
        return map[s].map { MouseAction(kind: $0) }
    }

    private static func shortcut(_ keys: [String]) -> MouseAction? {
        var mods: UInt64 = 0
        var code: Int?
        for k in keys {
            switch k.lowercased() {
            case "command", "commandleft", "commandright": mods |= CGEventFlags.maskCommand.rawValue
            case "shift", "shiftleft", "shiftright": mods |= CGEventFlags.maskShift.rawValue
            case "option", "optionleft", "optionright": mods |= CGEventFlags.maskAlternate.rawValue
            case "control", "controlleft", "controlright": mods |= CGEventFlags.maskControl.rawValue
            case "enter", "return": code = 36
            case "tab": code = 48
            case "space": code = 49
            case "delete", "backspace": code = 51
            case "escape": code = 53
            case "arrowleft": code = 123
            case "arrowright": code = 124
            case "arrowdown": code = 125
            case "arrowup": code = 126
            default:
                if k.count == 1 { code = KeyNames.keyCode(for: k.lowercased()) }
            }
        }
        guard let code else { return nil }
        return MouseAction(kind: .shortcut, keyCode: code, modifiers: mods)
    }

    // MARK: Mos

    static func fromMos(into c: inout MouseConfig) -> Report {
        guard let d = UserDefaults(suiteName: "com.caldis.Mos"), d.object(forKey: "smooth") != nil || d.object(forKey: "step") != nil else {
            return Report(ok: false, text: "")
        }
        var l = c.global
        let smooth = d.object(forKey: "smooth") as? Bool ?? true
        let reverse = d.object(forKey: "reverse") as? Bool ?? true
        l.vSmooth = smooth && (d.object(forKey: "smoothVertical") as? Bool ?? true)
        l.hSmooth = smooth && (d.object(forKey: "smoothHorizontal") as? Bool ?? true)
        l.vReverse = reverse && (d.object(forKey: "reverseVertical") as? Bool ?? true)
        l.hReverse = reverse && (d.object(forKey: "reverseHorizontal") as? Bool ?? true)
        if let v = d.object(forKey: "step") as? Double { l.step = v }
        if let v = d.object(forKey: "speed") as? Double { l.gain = v }
        if let v = d.object(forKey: "duration") as? Double { l.duration = v }
        if let v = d.object(forKey: "smoothSimTrackpad") as? Bool { l.simTrackpad = v }
        var mods: [ScrollModifier] = []
        for (key, action) in [("dash", ScrollModifierAction.faster), ("toggle", .swap), ("block", .noSmooth)] {
            if let t = mosHotkey(d.object(forKey: key)) { mods.append(ScrollModifier(trigger: t, action: action, scale: 5)) }
        }
        l.scrollModifiers = mods
        c.global = l

        var apps = 0
        if let data = d.data(forKey: "applications"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for a in list {
                guard let path = a["path"] as? String, a["inherit"] as? Bool == false,
                      let app = enclosingApp(path), let b = Bundle(url: app), let id = b.bundleIdentifier else { continue }
                var al = MouseLayer()
                // Eski biçim: scrollBasic + scrollAdvanced; yeni biçim: scroll
                let basic = (a["scrollBasic"] as? [String: Any]) ?? (a["scroll"] as? [String: Any]) ?? [:]
                let adv = (a["scrollAdvanced"] as? [String: Any]) ?? (a["scroll"] as? [String: Any]) ?? [:]
                if let s = basic["smooth"] as? Bool {
                    al.vSmooth = s && (basic["smoothVertical"] as? Bool ?? true)
                    al.hSmooth = s && (basic["smoothHorizontal"] as? Bool ?? true)
                }
                if let r = basic["reverse"] as? Bool {
                    al.vReverse = r && (basic["reverseVertical"] as? Bool ?? true)
                    al.hReverse = r && (basic["reverseHorizontal"] as? Bool ?? true)
                }
                if let v = double(adv["step"]) { al.step = v }
                if let v = double(adv["speed"]) { al.gain = v }
                if let v = double(adv["duration"]) { al.duration = v }
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                c.setLayer(.app(id), MouseLayer.merge([c.layer(.app(id)), al]), name: name, path: app.path)
                apps += 1
            }
        }
        var notes: [String] = []
        if d.object(forKey: "allowlist") as? Bool == true {
            notes.append(L("Önceki uygulamada beyaz liste açıktı; Missing'de listedeki uygulamalar kendi ayarını kullanır, diğerleri genel ayarı."))
        }
        return Report(ok: true, text: L("%d uygulama alındı.", apps), count: apps, notes: notes)
    }

    /// Mos kısayolu: eski biçim tuş kodu (0 = yok), yeni biçim {type, code} JSON
    private static func mosHotkey(_ v: Any?) -> MouseTrigger? {
        if let i = v as? Int { return i == 0 ? nil : .key(i) }
        if let data = v as? Data, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = d["code"] as? Int {
            return (d["type"] as? String) == "mouse" ? .mouse(code) : .key(code)
        }
        return nil
    }

    /// ".../Foo.app/Contents/MacOS/Foo" → ".../Foo.app"
    private static func enclosingApp(_ path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
