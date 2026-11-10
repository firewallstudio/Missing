import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mouse penceresi
//
// Ayarlardan ayrı pencere. Bölümler: Kaydırma, İmleç, Tuşlar, Uygulamalar, Genel.
// Üstteki "Uygulanacak yer" seçicisi hangi katmanın düzenlendiğini belirler (Tüm fareler / bir cihaz /
// bir ekran / bir uygulama). Global dışındaki katmanlarda değiştirilen her ayarın yanında ↺ çıkar;
// ona basınca ayar yeniden alttaki katmandan gelir.

enum MouseSection: String, CaseIterable {
    case scrolling, pointer, buttons, apps, general

    var title: String {
        switch self {
        case .scrolling: return L("Kaydırma")
        case .pointer: return L("İmleç")
        case .buttons: return L("Tuşlar")
        case .apps: return L("Uygulamalar")
        case .general: return L("Genel")
        }
    }

    var icon: String {
        switch self {
        case .scrolling: return "scroll"
        case .pointer: return "cursorarrow.motionlines"
        case .buttons: return "computermouse"
        case .apps: return "app.badge"
        case .general: return "gearshape"
        }
    }

    var scoped: Bool { self == .scrolling || self == .pointer || self == .buttons }
}

@MainActor final class MouseModel: ObservableObject {
    @Published var config = MouseEngine.shared.config
    @Published var section: MouseSection = .scrolling
    @Published var scope: MouseScope = .global
    @Published var vertical = true
    @Published var message: String?
    @Published var conflicts: [NSRunningApplication] = []

    private var saveWork: DispatchWorkItem?

    func reload() {
        config = MouseEngine.shared.config
        conflicts = MouseConflicts.running()
    }

    /// Değişiklik: hemen motora, kısa bir bekleyişle (sürgü sürüklerken) diske
    func commit(_ c: MouseConfig) {
        config = c
        saveWork?.cancel()
        let w = DispatchWorkItem { MouseEngine.shared.update(c) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    var layer: MouseLayer { config.layer(scope) }
    var inherited: MouseLayer { config.inherited(below: scope) }

    func setLayer(_ l: MouseLayer) {
        var c = config
        let (name, path) = scopeMeta()
        c.setLayer(scope, l, name: name, path: path)
        commit(c)
    }

    private func scopeMeta() -> (String, String) {
        switch scope {
        case .device(let k): return (MouseDevices.shared.uniqueDevices.first { $0.key == k }?.name ?? k, "")
        case .app(let b):
            let a = config.apps.first { $0.bundleID == b }
            return (a?.name ?? b, a?.path ?? "")
        default: return ("", "")
        }
    }

    func bind<T>(_ kp: WritableKeyPath<MouseLayer, T?>, _ def: T) -> Binding<T> {
        Binding(get: { [unowned self] in self.layer[keyPath: kp] ?? self.inherited[keyPath: kp] ?? def },
                set: { [unowned self] v in var l = self.layer; l[keyPath: kp] = v; self.setLayer(l) })
    }

    /// Eksene göre (dikey / yatay) iki alandan biri
    func axis<T>(_ v: WritableKeyPath<MouseLayer, T?>, _ h: WritableKeyPath<MouseLayer, T?>) -> WritableKeyPath<MouseLayer, T?> {
        vertical ? v : h
    }

    func overridden<T>(_ kp: WritableKeyPath<MouseLayer, T?>) -> Bool {
        scope != .global && layer[keyPath: kp] != nil
    }

    func reset<T>(_ kp: WritableKeyPath<MouseLayer, T?>) {
        var l = layer; l[keyPath: kp] = nil; setLayer(l)
    }

    var scopeTitle: String {
        switch scope {
        case .global: return L("Tüm fareler")
        case .device(let k): return MouseDevices.shared.uniqueDevices.first { $0.key == k }?.name
            ?? config.devices.first { $0.key == k }?.name ?? k
        case .display(let n): return n
        case .app(let b): return config.apps.first { $0.bundleID == b }?.name ?? b
        }
    }

    // MARK: Uygulamalar

    func addApp(_ url: URL) {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
        var c = config
        guard !c.apps.contains(where: { $0.bundleID == id }) else { scope = .app(id); return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        c.apps.append(MouseAppLayer(bundleID: id, name: name, path: url.path))
        commit(c)
    }

    func removeApp(_ id: String) {
        var c = config
        c.apps.removeAll { $0.bundleID == id }
        if scope == .app(id) { scope = .global }
        commit(c)
    }

    func removeScopeLayer() {
        var c = config
        switch scope {
        case .global: c.global = MouseLayer()
        case .device(let k): c.devices.removeAll { $0.key == k }
        case .display(let n): c.displays.removeAll { $0.name == n }
        case .app(let b): if let i = c.apps.firstIndex(where: { $0.bundleID == b }) { c.apps[i].layer = MouseLayer() }
        }
        commit(c)
    }
}

enum MouseConflicts {
    static let ids = ["com.lujjjh.LinearMouse": "LinearMouse", "com.caldis.Mos": "Mos"]

    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { ids[$0.bundleIdentifier ?? ""] != nil }
    }
}

final class MouseWindowController: NSObject, NSWindowDelegate {
    @MainActor static let shared = MouseWindowController()
    private var window: NSWindow?
    @MainActor let model = MouseModel()

    @MainActor func show(_ section: MouseSection? = nil) {
        if let section { model.section = section }
        model.reload()
        let w = window ?? make()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @MainActor private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("Mouse")
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: MouseView(model: model, devices: MouseDevices.shared))
        w.center()
        return w
    }
}

// MARK: - Görünüm

struct MouseView: View {
    @ObservedObject var model: MouseModel
    @ObservedObject var devices: MouseDevices

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.section.title).font(.system(size: 22, weight: .bold))
                    Spacer()
                    if model.section.scoped { scopePicker }
                }
                .padding(.horizontal, 26).padding(.top, 36).padding(.bottom, 10)
                if !model.config.enabled && model.section != .general { offBanner.padding(.horizontal, 26).padding(.bottom, 8) }
                if !model.conflicts.isEmpty { conflictBanner.padding(.horizontal, 26).padding(.bottom, 8) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content }
                        .padding(.horizontal, 26).padding(.bottom, 26)
                        .id("\(model.section)-\(model.scope)-\(model.vertical)")
                }
            }
        }
        .frame(width: 820, height: 640)
        .background(ZStack { GlassBlur(material: .hudWindow); Color.black.opacity(0.32) }.ignoresSafeArea())
        .foregroundStyle(Color.white)
        .tint(Brand.red)
        .environment(\.colorScheme, .dark)
        .onAppear { MouseScreens.refresh(); devices.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .scrolling: MouseScrollingPage(model: model)
        case .pointer: MousePointerPage(model: model)
        case .buttons: MouseButtonsPage(model: model)
        case .apps: MouseAppsPage(model: model)
        case .general: MouseGeneralPage(model: model)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "computermouse.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.red)
                Text(L("Mouse")).font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.top, 40).padding(.bottom, 14)
            ForEach(MouseSection.allCases, id: \.self) { s in
                if s == .apps || s == .general { Spacer().frame(height: 10) }
                Button { model.section = s } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                            .foregroundStyle(model.section == s ? Color.white : Color.white.opacity(0.6))
                        Text(s.title).font(.system(size: 13, weight: model.section == s ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.section == s ? Brand.red.opacity(0.85) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(L("Öncelik: uygulama › ekran › cihaz › tüm fareler"))
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10).padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(Color.black.opacity(0.18))
    }

    private var scopePicker: some View {
        HStack(spacing: 6) {
            Menu {
                Button(L("Tüm fareler")) { model.scope = .global }
                let devs = devices.uniqueDevices.filter { $0.category != .trackpad }
                if !devs.isEmpty {
                    Section(L("Cihaz")) {
                        ForEach(devs) { d in
                            Button(mark(model.config.devices.contains { $0.key == d.key && !$0.layer.isEmpty }) + d.name) {
                                model.scope = .device(d.key)
                            }
                        }
                    }
                }
                let screens = MouseScreens.allNames
                if screens.count > 0 {
                    Section(L("Ekran")) {
                        ForEach(screens, id: \.self) { n in
                            Button(mark(model.config.displays.contains { $0.name == n && !$0.layer.isEmpty }) + n) { model.scope = .display(n) }
                        }
                    }
                }
                if !model.config.apps.isEmpty {
                    Section(L("Uygulama")) {
                        ForEach(model.config.apps) { a in
                            Button(mark(!a.layer.isEmpty) + a.name) { model.scope = .app(a.bundleID) }
                        }
                    }
                }
            } label: {
                Label(model.scopeTitle, systemImage: scopeIcon)
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(model.scope == .global ? Color.white.opacity(0.1) : Brand.red.opacity(0.6)))
            if model.scope != .global, !model.layer.isEmpty {
                Button { model.removeScopeLayer() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .help(L("Bu yerdeki bütün değişiklikleri sil"))
            }
        }
    }

    private func mark(_ customized: Bool) -> String { customized ? "● " : "" }

    private var scopeIcon: String {
        switch model.scope {
        case .global: return "globe"
        case .device: return "computermouse"
        case .display: return "display"
        case .app: return "app"
        }
    }

    private var offBanner: some View {
        HStack {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(L("Mouse kapalı; ayarlar kaydediliyor ama uygulanmıyor."))
                .font(.system(size: 12))
            Spacer()
            Button(L("Aç")) {
                var c = model.config; c.enabled = true; model.commit(c)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.15)))
    }

    private var conflictBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(L("Şu da çalışıyor: %@. İkisi aynı anda fareyi değiştirirse ayarlar çakışır.",
                   model.conflicts.compactMap { MouseConflicts.ids[$0.bundleIdentifier ?? ""] }.joined(separator: ", ")))
                .font(.system(size: 12))
            Spacer()
            Button(L("Kapat")) {
                for a in model.conflicts { a.terminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.reload() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.13)))
    }
}

// MARK: - Ortak parçalar

/// Katmanı olan satır: global dışında değiştirilmişse yanında ↺ çıkar
struct LayerRow<T, Control: View>: View {
    @ObservedObject var model: MouseModel
    let title: String
    let detail: String?
    let kp: WritableKeyPath<MouseLayer, T?>
    @ViewBuilder let control: Control

    init(_ model: MouseModel, _ title: String, _ detail: String? = nil, _ kp: WritableKeyPath<MouseLayer, T?>,
         @ViewBuilder control: () -> Control) {
        self.model = model; self.title = title; self.detail = detail; self.kp = kp; self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).help(detail ?? "")
            if model.overridden(kp) {
                Button { model.reset(kp) } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Brand.red)
                }
                .buttonStyle(.plain)
                .help(L("Alttaki ayarı kullan"))
            }
            Spacer()
            control
        }
    }
}

struct MouseSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { value = (($0 / step).rounded() * step) }), in: range)
                .frame(width: width)
            Text(String(format: format, value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// Bir sonraki tuşu ya da fare tuşunu kaydeder (Esc vazgeçer)
struct TriggerRecorder: View {
    @Binding var trigger: MouseTrigger
    /// true: modifier'larla birlikte (eşlemeler); false: tek tuş (kaydırma tuşları)
    var withModifiers = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Bir tuşa bas…") : trigger.title)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 110)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(recording ? Brand.red.opacity(0.7) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown, .leftMouseDown, .rightMouseDown]) { e in
            let mods = withModifiers ? (UInt64(e.cgEvent?.flags.rawValue ?? 0) & MouseKeys.modifierMask) : 0
            switch e.type {
            case .keyDown:
                if e.keyCode == 53 { stop(); return nil }
                trigger = .key(Int(e.keyCode), mods)
            case .flagsChanged:
                guard !withModifiers, MouseTrigger.modifierKeyCodes[Int(e.keyCode)] != nil,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty == false else { return e }
                trigger = .key(Int(e.keyCode))
            case .otherMouseDown:
                trigger = .mouse(e.buttonNumber, mods)
            case .leftMouseDown, .rightMouseDown:
                // Sol / sağ tık sadece modifier ile (yoksa her tık yakalanırdı)
                guard withModifiers, mods != 0 else { return e }
                trigger = .mouse(e.type == .leftMouseDown ? 0 : 1, mods)
            default: return e
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

extension MouseActionKind {
    var title: String {
        switch self {
        case .none: return L("Hiçbir şey")
        case .missionControl: return "Mission Control"
        case .appExpose: return L("Uygulama pencereleri")
        case .showDesktop: return L("Masaüstünü göster")
        case .launchpad: return "Launchpad"
        case .spaceLeft: return L("Soldaki masaüstü")
        case .spaceRight: return L("Sağdaki masaüstü")
        case .spotlight: return "Spotlight"
        case .lockScreen: return L("Ekranı kilitle")
        case .screenshot: return L("Ekran görüntüsü")
        case .screenshotArea: return L("Alan görüntüsü")
        case .record: return L("Ekranı kaydet")
        case .scrollingCapture: return L("Kaydırmalı görüntü")
        case .tile: return L("Ekranı böl")
        case .back: return L("Geri")
        case .forward: return L("İleri")
        case .closeWindow: return L("Pencereyi kapat")
        case .minimizeWindow: return L("Pencereyi küçült")
        case .hideApp: return L("Uygulamayı gizle")
        case .quitApp: return L("Uygulamadan çık")
        case .fullScreen: return L("Tam ekran")
        case .nextWindow: return L("Sonraki pencere")
        case .leftClick: return L("Sol tık")
        case .rightClick: return L("Sağ tık")
        case .middleClick: return L("Orta tık")
        case .doubleClick: return L("Çift tık")
        case .scrollUp: return L("Yukarı kaydır")
        case .scrollDown: return L("Aşağı kaydır")
        case .scrollLeft: return L("Sola kaydır")
        case .scrollRight: return L("Sağa kaydır")
        case .playPause: return L("Oynat / duraklat")
        case .nextTrack: return L("Sonraki parça")
        case .previousTrack: return L("Önceki parça")
        case .volumeUp: return L("Sesi aç")
        case .volumeDown: return L("Sesi kıs")
        case .mute: return L("Sessiz")
        case .brightnessUp: return L("Parlaklığı artır")
        case .brightnessDown: return L("Parlaklığı azalt")
        case .copy: return L("Kopyala")
        case .paste: return L("Yapıştır")
        case .cut: return L("Kes")
        case .undo: return L("Geri al")
        case .redo: return L("Yinele")
        case .selectAll: return L("Tümünü seç")
        case .shortcut: return L("Klavye kısayolu…")
        case .openApp: return L("Uygulama aç…")
        case .openFile: return L("Dosya aç…")
        case .runScript: return L("Komut çalıştır…")
        }
    }

    static let groups: [[MouseActionKind]] = [
        [.none],
        [.missionControl, .appExpose, .showDesktop, .launchpad, .spaceLeft, .spaceRight, .spotlight, .lockScreen],
        [.screenshot, .screenshotArea, .record, .scrollingCapture, .tile],
        [.back, .forward, .closeWindow, .minimizeWindow, .hideApp, .quitApp, .fullScreen, .nextWindow],
        [.leftClick, .rightClick, .middleClick, .doubleClick, .scrollUp, .scrollDown, .scrollLeft, .scrollRight],
        [.playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute, .brightnessUp, .brightnessDown],
        [.copy, .paste, .cut, .undo, .redo, .selectAll],
        [.shortcut, .openApp, .openFile, .runScript],
    ]
}

/// Eylem seçici + seçilen eylemin ek alanı (kısayol, uygulama, dosya, komut)
struct ActionPicker: View {
    @Binding var action: MouseAction

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(MouseActionKind.groups.enumerated()), id: \.offset) { i, g in
                    if i > 0 { Divider() }
                    ForEach(g, id: \.self) { k in
                        Button(k.title) {
                            var a = MouseAction(kind: k)
                            if k == .openApp || k == .openFile { a.target = choose(app: k == .openApp) }
                            if k == .runScript { a.target = action.kind == .runScript ? action.target : "" }
                            action = a
                        }
                    }
                }
            } label: { Text(label).font(.system(size: 12)) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if action.kind == .shortcut {
                TriggerRecorder(trigger: Binding(get: { .key(action.keyCode ?? 0, action.modifiers ?? 0) },
                                                 set: { action.keyCode = $0.code; action.modifiers = $0.modifiers }),
                                withModifiers: true)
            }
            if action.kind == .runScript {
                TextField(L("kabuk komutu"), text: Binding(get: { action.target ?? "" }, set: { action.target = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
    }

    private var label: String {
        switch action.kind {
        case .openApp, .openFile:
            let n = action.target.map { ($0 as NSString).lastPathComponent } ?? ""
            return action.kind.title.replacingOccurrences(of: "…", with: "") + (n.isEmpty ? "" : ": \(n)")
        case .shortcut, .runScript: return action.kind.title.replacingOccurrences(of: "…", with: "")
        default: return action.kind.title
        }
    }

    private func choose(app: Bool) -> String? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = !app
        p.allowsMultipleSelection = false
        if app {
            p.allowedContentTypes = [.application]
            p.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

func mouseButtonName(_ b: Int) -> String {
    MouseTrigger.mouse(b).title
}

struct ButtonPicker: View {
    @Binding var button: Int
    var body: some View {
        Picker("", selection: $button) {
            ForEach(2..<12, id: \.self) { b in Text(mouseButtonName(b)).tag(b) }
        }
        .labelsHidden()
        .frame(width: 140)
    }
}

// MARK: - Kaydırma

struct MouseScrollingPage: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        let m = model
        Picker("", selection: $model.vertical) {
            Text(L("Dikey")).tag(true)
            Text(L("Yatay")).tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .padding(.bottom, 4)

        let modeKP = m.axis(\.vMode, \.hMode)
        let mode = m.bind(modeKP, ScrollMode.accelerated).wrappedValue
        Card(title: L("Kaydırma modu"), icon: "arrow.up.arrow.down", subtitle: L("Her çentikte ne kadar kayacağı"), startOpen: true) {
            LayerRow(m, L("Mod"), nil, modeKP) {
                Picker("", selection: m.bind(modeKP, .accelerated)) {
                    Text(L("İvmeli")).tag(ScrollMode.accelerated)
                    Text(L("Satır")).tag(ScrollMode.lines)
                    Text(L("Piksel")).tag(ScrollMode.pixels)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            switch mode {
            case .accelerated:
                LayerRow(m, L("İvme"), L("macOS'un tekerlek ivmesinin çarpanı (1 = sistemdeki gibi)"), m.axis(\.vAccel, \.hAccel)) {
                    MouseSlider(value: m.bind(m.axis(\.vAccel, \.hAccel), 1), range: 0...10)
                }
                LayerRow(m, L("Hız"), L("Her çentiğe eklenen piksel"), m.axis(\.vSpeed, \.hSpeed)) {
                    MouseSlider(value: m.bind(m.axis(\.vSpeed, \.hSpeed), 0), range: 0...128)
                }
            case .lines:
                LayerRow(m, L("Satır"), L("Her çentikte kaç satır"), m.axis(\.vLines, \.hLines)) {
                    MouseSlider(value: m.bind(m.axis(\.vLines, \.hLines), 3), range: 1...10, step: 1, format: "%.0f")
                }
            case .pixels:
                LayerRow(m, L("Piksel"), L("Her çentikte kaç piksel"), m.axis(\.vPixels, \.hPixels)) {
                    MouseSlider(value: m.bind(m.axis(\.vPixels, \.hPixels), 36), range: 1...128, step: 0.1, format: "%.1f")
                }
            }
            Divider().opacity(0.4)
            LayerRow(m, L("Yumuşak kaydırma"), L("Bu eksende kaydırmayı yumuşat (seçili mod yumuşatılarak uygulanır)"), m.axis(\.vSmooth, \.hSmooth)) {
                BrandToggle(isOn: m.bind(m.axis(\.vSmooth, \.hSmooth), true))
            }
            LayerRow(m, L("Ters çevir"), L("Bu eksende kaydırma yönünü ters çevir"), m.axis(\.vReverse, \.hReverse)) {
                BrandToggle(isOn: m.bind(m.axis(\.vReverse, \.hReverse), false))
            }
        }

        let sim = m.bind(\.simTrackpad, false).wrappedValue
        Card(title: L("Yumuşatma"), icon: "wind", subtitle: L("İki eksen için ortak; Mos'taki ayarlar"), startOpen: true) {
            LayerRow(m, L("Adım"), L("Bir çentiğin en az ne kadar kaydıracağı. Küçük hareketler bu değere yükseltilir."), \.step) {
                MouseSlider(value: m.bind(\.step, 33.6), range: 0.01...100)
            }
            LayerRow(m, L("Hız çarpanı"), L("Her çentiğin mesafesi bununla çarpılır"), \.gain) {
                MouseSlider(value: m.bind(\.gain, 2.7), range: 1...10)
            }
            LayerRow(m, L("Süre"), L("Kaydırmanın ne kadar uzun süzüleceği"), \.duration) {
                MouseSlider(value: Binding(get: { sim ? 4.75 : m.bind(\.duration, 4.35).wrappedValue },
                                           set: { m.bind(\.duration, 4.35).wrappedValue = $0 }), range: 1...5)
                    .disabled(sim)
                    .opacity(sim ? 0.5 : 1)
            }
            LayerRow(m, L("Trackpad gibi"), L("Kaydırmayı trackpad hareketi gibi gönder (sayfa sonunda esner, geri/ileri kaydırma hareketleri çalışır). Süre 4,75'e kilitlenir."), \.simTrackpad) {
                BrandToggle(isOn: m.bind(\.simTrackpad, false))
            }
            HStack {
                Spacer()
                Button(L("Mos varsayılanları")) {
                    var l = m.layer
                    l.step = 33.6; l.gain = 2.7; l.duration = 4.35; l.simTrackpad = false
                    m.setLayer(l)
                }
            }
        }

        Card(title: L("Kaydırma tuşları"), icon: "command", subtitle: L("Basılı tutarken kaydırmayı değiştiren tuşlar"), startOpen: true) {
            ScrollModifierList(model: m)
        }
    }
}

struct ScrollModifierList: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        let kp: WritableKeyPath<MouseLayer, [ScrollModifier]?> = \.scrollModifiers
        let list = model.bind(kp, [])
        LayerRow(model, L("Tuşlar"), nil, kp) { EmptyView() }
        ForEach(list.wrappedValue) { item in
            let i = list.wrappedValue.firstIndex(of: item) ?? 0
            HStack(spacing: 8) {
                TriggerRecorder(trigger: Binding(get: { list.wrappedValue[i].trigger }, set: { list.wrappedValue[i].trigger = $0 }))
                Picker("", selection: Binding(get: { list.wrappedValue[i].action }, set: { list.wrappedValue[i].action = $0 })) {
                    Text(L("Hızlandır")).tag(ScrollModifierAction.faster)
                    Text(L("Yön değiştir (dikey ↔ yatay)")).tag(ScrollModifierAction.swap)
                    Text(L("Yumuşatma yok")).tag(ScrollModifierAction.noSmooth)
                    Text(L("Kaydırma yok")).tag(ScrollModifierAction.block)
                    Text(L("Yakınlaştır / uzaklaştır")).tag(ScrollModifierAction.zoom)
                }
                .labelsHidden().frame(width: 210)
                if list.wrappedValue[i].action == .faster {
                    MouseSlider(value: Binding(get: { list.wrappedValue[i].scale }, set: { list.wrappedValue[i].scale = $0 }),
                                range: 0.1...10, step: 0.1, format: "×%.1f", width: 110)
                }
                Spacer()
                Button { list.wrappedValue.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
        }
        HStack {
            Button(L("Tuş ekle")) {
                list.wrappedValue.append(ScrollModifier(trigger: .key(59), action: .faster, scale: 3))
            }
            Spacer()
            Text(L("Fare tuşu da seçilebilir; hiç kaydırmadan bırakırsan normal tıklama olur."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - İmleç

struct MousePointerPage: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        let m = model
        let custom = m.bind(\.pointerMode, PointerMode.system).wrappedValue == .custom
        Card(title: L("İmleç hızı"), icon: "cursorarrow.motionlines", subtitle: L("Farenin imleci ne kadar hızlı götüreceği"), startOpen: true) {
            LayerRow(m, L("Ayar"), nil, \.pointerMode) {
                Picker("", selection: m.bind(\.pointerMode, .system)) {
                    Text(L("Sistemdeki gibi")).tag(PointerMode.system)
                    Text(L("Özel")).tag(PointerMode.custom)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if custom {
                LayerRow(m, L("İvme"), L("Hızlı hareketlerde imlecin ne kadar fazla gideceği (macOS varsayılanı 0,6875)"), \.pointerAccel) {
                    MouseSlider(value: m.bind(\.pointerAccel, 0.6875), range: 0...5, step: 0.0001, format: "%.4f")
                }
                LayerRow(m, L("Hız"), L("İmlecin temel hızı (0 yavaş, 1 hızlı)"), \.pointerSpeed) {
                    MouseSlider(value: m.bind(\.pointerSpeed, 0.5), range: 0...1, step: 0.0001, format: "%.4f")
                }
            }
            LayerRow(m, L("İvmeyi kapat"), L("İmleç elin hareketiyle birebir gitsin (oyun ve tasarım için)"), \.disableAccel) {
                BrandToggle(isOn: m.bind(\.disableAccel, false))
            }
            HStack {
                Spacer()
                Button(L("Sistem varsayılanına dön")) {
                    var l = m.layer
                    l.pointerMode = .system; l.disableAccel = false; l.pointerAccel = nil; l.pointerSpeed = nil
                    m.setLayer(l)
                }
            }
            Text(L("İmleç ayarı öndeki uygulamaya ve imlecin bulunduğu ekrana göre seçilir. Missing kapanınca ya da çökerse sistem ayarına döner."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        if m.scope == .global {
            Card(title: L("İmlecin yeri"), icon: "scope",
                 isOn: Binding(get: { m.config.showPointerLocation }, set: { v in var c = m.config; c.showPointerLocation = v; m.commit(c) }),
                 subtitle: L("⌃'ye iki kez dokununca imlecin etrafında halka")) {
                EmptyView()
            }
        }
    }
}

// MARK: - Tuşlar

struct MouseButtonsPage: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        let m = model
        Card(title: L("Temel"), icon: "computermouse", startOpen: true) {
            LayerRow(m, L("Evrensel geri / ileri"), L("Farenin yan tuşları her uygulamada geri / ileri gitsin"), \.backForward) {
                BrandToggle(isOn: m.bind(\.backForward, true))
            }
            LayerRow(m, L("Sol ve sağ tuşu değiştir"), nil, \.switchPrimary) {
                BrandToggle(isOn: m.bind(\.switchPrimary, false))
            }
            LayerRow(m, L("Çift tıklama koruması"), L("Eskiyen farelerin istemeden çift tıklamasını engeller"), \.debounce) {
                BrandToggle(isOn: m.bind(\.debounce, false))
            }
            if m.bind(\.debounce, false).wrappedValue {
                LayerRow(m, L("Bekleme"), L("Bu süre içindeki ikinci basış yok sayılır"), \.debounceMs) {
                    MouseSlider(value: m.bind(\.debounceMs, 50), range: 5...500, step: 1, format: "%.0f ms")
                }
                LayerRow(m, L("Tuşlar"), nil, \.debounceButtons) {
                    let b = m.bind(\.debounceButtons, [0])
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            let on = b.wrappedValue.contains(i)
                            Button(mouseButtonName(i)) {
                                if on { b.wrappedValue.removeAll { $0 == i } } else { b.wrappedValue.append(i) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Brand.red.opacity(0.8) : Color.white.opacity(0.1)))
                        }
                    }
                }
            }
        }

        Card(title: L("Otomatik kaydırma"), icon: "arrow.up.and.down.and.arrow.left.and.right",
             isOn: m.bind(\.autoScroll, false),
             subtitle: L("Tuşa bas ve imleci oynat; bırakınca ya da tekrar tıklayınca biter")) {
            LayerRow(m, L("Tuş"), nil, \.autoScrollButton) { ButtonPicker(button: m.bind(\.autoScrollButton, 2)) }
            Text(L("Bağlantı ve düğmelerin üstünde orta tık yine normal çalışır (yeni sekmede aç gibi)."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }

        Card(title: L("Hareketler"), icon: "hand.draw", isOn: m.bind(\.gesture, false),
             subtitle: L("Tuş basılıyken fareyi bir yöne çek")) {
            LayerRow(m, L("Tuş"), nil, \.gestureButton) { ButtonPicker(button: m.bind(\.gestureButton, 4)) }
            LayerRow(m, L("Sola"), nil, \.gestureLeft) { ActionPicker(action: m.bind(\.gestureLeft, .of(.spaceLeft))) }
            LayerRow(m, L("Sağa"), nil, \.gestureRight) { ActionPicker(action: m.bind(\.gestureRight, .of(.spaceRight))) }
            LayerRow(m, L("Yukarı"), nil, \.gestureUp) { ActionPicker(action: m.bind(\.gestureUp, .of(.missionControl))) }
            LayerRow(m, L("Aşağı"), nil, \.gestureDown) { ActionPicker(action: m.bind(\.gestureDown, .of(.appExpose))) }
        }

        Card(title: L("Fareyle kaydır"), icon: "arrow.up.and.down.circle", isOn: m.bind(\.redirectToScroll, false),
             subtitle: L("Tuş basılıyken fareyi oynatmak sayfayı kaydırır, imleç yerinde kalır")) {
            LayerRow(m, L("Tuş"), nil, \.redirectButton) { ButtonPicker(button: m.bind(\.redirectButton, 3)) }
        }

        Card(title: L("Tuş eşlemeleri"), icon: "rectangle.and.hand.point.up.left", subtitle: L("Fare tuşlarına ve klavye kısayollarına eylem bağla"), startOpen: true) {
            MappingList(model: m)
        }
    }
}

struct MappingList: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        let kp: WritableKeyPath<MouseLayer, [MouseMapping]?> = \.mappings
        let list = model.bind(kp, [])
        LayerRow(model, L("Eşlemeler"), nil, kp) { EmptyView() }
        ForEach(list.wrappedValue) { item in
            let i = list.wrappedValue.firstIndex(of: item) ?? 0
            HStack(spacing: 8) {
                BrandToggle(isOn: Binding(get: { list.wrappedValue[i].enabled }, set: { list.wrappedValue[i].enabled = $0 }))
                TriggerRecorder(trigger: Binding(get: { list.wrappedValue[i].trigger }, set: { list.wrappedValue[i].trigger = $0 }),
                                withModifiers: true)
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4))
                ActionPicker(action: Binding(get: { list.wrappedValue[i].action }, set: { list.wrappedValue[i].action = $0 }))
                Spacer()
                Button { list.wrappedValue.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
        }
        if conflicts(list.wrappedValue) {
            Label(L("Aynı tetikleyici birden fazla eşlemede var; ilki kullanılır."), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.yellow)
        }
        HStack {
            Button(L("Eşleme ekle")) {
                list.wrappedValue.append(MouseMapping(trigger: .mouse(3), action: .of(.missionControl)))
            }
            Spacer()
            Text(L("Sol ve sağ tık sadece ⌘ ⌥ ⌃ ⇧ ile birlikte eşlenebilir."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func conflicts(_ l: [MouseMapping]) -> Bool {
        let t = l.filter(\.enabled).map(\.trigger)
        return Set(t).count != t.count
    }
}

// MARK: - Uygulamalar

struct MouseAppsPage: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Text(L("Listedeki her uygulama ya genel ayarları kullanır ya da kendi ayarlarını. Kendi ayarı için Düzenle'ye bas: Kaydırma, İmleç ve Tuşlar o uygulama için açılır; değiştirdiğin her ayar sadece orada geçerli olur."))
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Menu(L("Çalışan uygulamalardan ekle")) {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { a in
                    Button(a.localizedName ?? a.bundleIdentifier ?? "?") { if let u = a.bundleURL { model.addApp(u) } }
                        .disabled(model.config.apps.contains { $0.bundleID == a.bundleIdentifier })
                }
            }
            .fixedSize()
            Button(L("Dosyadan ekle…")) {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.application]
                p.directoryURL = URL(fileURLWithPath: "/Applications")
                p.allowsMultipleSelection = true
                if p.runModal() == .OK { for u in p.urls { model.addApp(u) } }
            }
            Spacer()
        }
        .padding(.bottom, 6)
        if model.config.apps.isEmpty {
            Text(L("Henüz uygulama yok.")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).padding(.top, 20)
        }
        ForEach(model.config.apps) { a in appRow(a) }
    }

    private func appRow(_ a: MouseAppLayer) -> some View {
        let disabled = a.layer.disabled ?? false
        let noSmooth = a.layer.vSmooth == false && a.layer.hSmooth == false
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.system(size: 13, weight: .semibold))
                Text(a.layer.isEmpty ? L("Genel ayarları kullanıyor") : (disabled ? L("Mouse bu uygulamada kapalı") : L("Kendi ayarları var")))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Toggle(L("Yumuşatma yok"), isOn: Binding(get: { noSmooth }, set: { v in
                update(a.bundleID) { $0.vSmooth = v ? false : nil; $0.hSmooth = v ? false : nil }
            }))
            .toggleStyle(.checkbox).font(.system(size: 11.5))
            Toggle(L("Hiç dokunma"), isOn: Binding(get: { disabled }, set: { v in update(a.bundleID) { $0.disabled = v ? true : nil } }))
                .toggleStyle(.checkbox).font(.system(size: 11.5))
            Button(L("Düzenle")) { model.scope = .app(a.bundleID); model.section = .scrolling }
            Button { model.removeApp(a.bundleID) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func update(_ id: String, _ f: (inout MouseLayer) -> Void) {
        var c = model.config
        guard let i = c.apps.firstIndex(where: { $0.bundleID == id }) else { return }
        f(&c.apps[i].layer)
        model.commit(c)
    }
}

// MARK: - Genel

struct MouseGeneralPage: View {
    @ObservedObject var model: MouseModel

    var body: some View {
        Card(title: L("Mouse"), icon: "computermouse.fill",
             isOn: Binding(get: { model.config.enabled }, set: { v in
                 var c = model.config; c.enabled = v; model.commit(c)
                 if v, !AXIsProcessTrusted() {
                     _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                 }
             }),
             subtitle: L("Kaydırma, imleç ve tuş ayarlarının hepsi"), startOpen: true) {
            Text(L("Kapatınca Missing fareye hiç dokunmaz; imleç ayarları sistemdekine döner. Ayarların silinmez."))
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            if model.config.enabled, !AXIsProcessTrusted() {
                Label(L("Erişilebilirlik izni gerekiyor (Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik)."),
                      systemImage: "exclamationmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }

        Card(title: L("Bağlı cihazlar"), icon: "cable.connector", startOpen: true) {
            ForEach(MouseDevices.shared.uniqueDevices) { d in
                HStack {
                    Image(systemName: d.symbol).frame(width: 20)
                    Text(d.name).font(.system(size: 12.5, weight: .medium))
                    Text(d.transport).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(d.category == .mouse ? L("Fare") : d.category == .trackpad ? L("Trackpad · dokunulmaz") : L("Magic Mouse · yumuşatma yok"))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }

        Card(title: L("Dışa / içe aktar"), icon: "square.and.arrow.up.on.square", startOpen: true) {
            HStack {
                Button(L("Dışa aktar…")) { exportConfig() }
                Button(L("İçe aktar…")) { importConfig() }
                Spacer()
            }
            Divider().opacity(0.4)
            HStack {
                Button(L("LinearMouse ayarlarını al")) { importLinearMouse() }
                Button(L("Mos ayarlarını al")) { report(MouseImport.fromMos(into: &workingConfig)) }
                Spacer()
            }
            Text(L("Alınan ayarlar şimdikilerin üstüne yazılır."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            if let msg = model.message {
                Text(msg).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack {
            Button(L("Bütün Mouse ayarlarını sıfırla")) {
                var c = MouseConfig(); c.enabled = model.config.enabled
                model.scope = .global
                model.commit(c)
                model.message = L("Ayarlar sıfırlandı.")
            }
            Spacer()
        }
        Text(L("LinearMouse (MIT) ve Mos'un yaptıklarını bir araya getirir. LinearMouse'tan alınan parçalar lisans notuyla birlikte; Mos'tan kod alınmadı, davranışı yeniden yazıldı."))
            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private var workingConfig: MouseConfig {
        get { model.config }
        nonmutating set { model.commit(newValue) }
    }

    private func report(_ r: MouseImport.Report) {
        model.message = r.text
        if r.ok { model.scope = .global }
    }

    private func exportConfig() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Missing Mouse.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let d = MouseStore.export(model.config) else { return }
        do { try d.write(to: url); model.message = L("Kaydedildi: %@", url.lastPathComponent) }
        catch { model.message = error.localizedDescription }
    }

    private func importConfig() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let d = try? Data(contentsOf: url) else { return }
        if var c = try? JSONDecoder().decode(MouseConfig.self, from: d) {
            c.enabled = model.config.enabled
            model.commit(c)
            model.message = L("İçe aktarıldı: %@", url.lastPathComponent)
        } else {
            // Missing dosyası değilse LinearMouse ayarı olabilir
            var c = model.config
            let r = MouseImport.fromLinearMouse(d, into: &c)
            if r.ok { model.commit(c) }
            report(r)
        }
    }

    private func importLinearMouse() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".config/linearmouse/linearmouse.json"),
                     home.appendingPathComponent("Library/Application Support/linearmouse/linearmouse.json")]
        var url = paths.first { FileManager.default.fileExists(atPath: $0.path) }
        if url == nil {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.json]
            url = p.runModal() == .OK ? p.url : nil
        }
        guard let url, let d = try? Data(contentsOf: url) else { return }
        var c = model.config
        let r = MouseImport.fromLinearMouse(d, into: &c)
        if r.ok { model.commit(c) }
        report(r)
    }
}
