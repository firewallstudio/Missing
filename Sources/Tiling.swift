import Cocoa
import SwiftUI

// MARK: - Ayarlar

enum TileSettings {
    private static var d: UserDefaults { .standard }

    /// ⌘< ile ekran bölme
    static var enabled: Bool {
        get { d.object(forKey: "tile.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "tile.enabled") }
    }
    /// Birden fazla monitör varken her seferinde hangi monitör olduğunu sor
    static var askMonitor: Bool {
        get { d.object(forKey: "tile.askMonitor") as? Bool ?? false }
        set { d.set(newValue, forKey: "tile.askMonitor") }
    }
    /// Pencereler arası boşluk (nokta). Varsayılan 0: pencereler birbirine tam yapışık
    static var gap: Double {
        get {
            // Eski varsayılan 8'di; bir kerelik 0'a çekilir (sonra ayardan değiştirilebilir)
            if !d.bool(forKey: "tile.gap.v2") {
                d.set(true, forKey: "tile.gap.v2")
                if (d.object(forKey: "tile.gap") as? Double ?? 8) == 8 { d.set(0.0, forKey: "tile.gap") }
            }
            return d.object(forKey: "tile.gap") as? Double ?? 0
        }
        set { d.set(newValue, forKey: "tile.gap") }
    }
}

// MARK: - Düzenler

struct TileLayout: Identifiable {
    let id: String
    let name: String
    /// 0…1 aralığında, sol üst köşeden başlayan bölmeler
    let zones: [CGRect]

    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    static let all: [TileLayout] = [
        TileLayout(id: "full", name: L("Tam ekran"), zones: [r(0, 0, 1, 1)]),
        TileLayout(id: "2v", name: L("2 dikey"), zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)]),
        TileLayout(id: "2h", name: L("2 yatay"), zones: [r(0, 0, 1, 0.5), r(0, 0.5, 1, 0.5)]),
        TileLayout(id: "3v", name: L("3 dikey"), zones: [r(0, 0, 1.0 / 3, 1), r(1.0 / 3, 0, 1.0 / 3, 1), r(2.0 / 3, 0, 1.0 / 3, 1)]),
        TileLayout(id: "13", name: "⅓ + ⅔", zones: [r(0, 0, 1.0 / 3, 1), r(1.0 / 3, 0, 2.0 / 3, 1)]),
        TileLayout(id: "23", name: "⅔ + ⅓", zones: [r(0, 0, 2.0 / 3, 1), r(2.0 / 3, 0, 1.0 / 3, 1)]),
        TileLayout(id: "1+2", name: "½ + ¼ ¼", zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
        TileLayout(id: "4", name: "4 (2×2)", zones: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
        TileLayout(id: "6", name: "6 (3×2)", zones: (0..<6).map { i in
            r(Double(i % 3) / 3, Double(i / 3) / 2, 1.0 / 3, 0.5)
        }),
    ]
}

// MARK: - Monitörler

enum Screens {
    /// Soldan sağa sıralı monitörler: 1, 2, 3 numaraları bu sıraya göre verilir.
    static var ordered: [NSScreen] {
        NSScreen.screens.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.maxY > $1.frame.maxY
        }
    }

    static func index(of screen: NSScreen?, in list: [NSScreen]) -> Int {
        guard let screen else { return 0 }
        let id = displayID(of: screen)
        return list.firstIndex { displayID(of: $0) == id } ?? 0
    }

    static func size(_ s: NSScreen) -> String {
        "\(Int(s.frame.width))×\(Int(s.frame.height))"
    }
}

// MARK: - Pencere taşıma

@MainActor enum WindowMover {
    /// Bölmenin ekrandaki karşılığı (AppKit koordinatları, sol alt köşe)
    static func frame(_ zone: CGRect, on screen: NSScreen) -> CGRect {
        let g = CGFloat(TileSettings.gap)
        let vf = screen.visibleFrame.insetBy(dx: g / 2, dy: g / 2)
        let w = zone.width * vf.width
        let h = zone.height * vf.height
        let x = vf.minX + zone.minX * vf.width
        let y = vf.maxY - zone.minY * vf.height - h
        return CGRect(x: x, y: y, width: w, height: h).insetBy(dx: g / 2, dy: g / 2).integral
    }

    /// Pencereleri bölmelerine yerleştir. Listedeki ilk pencere en sonda öne gelir.
    static func place(_ pairs: [(Item, CGRect)]) {
        guard !pairs.isEmpty else { return }
        var waitForFullScreen = false
        for (item, _) in pairs where exitFullScreen(item) { waitForFullScreen = true }

        let work = {
            for (item, rect) in pairs { move(item, to: rect) }
            for (item, _) in pairs.reversed() { WindowList.focus(item) }
        }
        if waitForFullScreen {
            // Tam ekrandan çıkış animasyonu bitsin
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { MainActor.assumeIsolated { work() } }
        } else {
            work()
        }
    }

    static func move(_ item: Item, to rect: CGRect) {
        guard let w = item.window else { return }
        if item.app.isHidden { item.app.unhide() }
        if item.minimized {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        move(window: w, to: rect)
    }

    /// AX penceresini AppKit koordinatlarındaki dikdörtgene taşı
    static func move(window w: AXUIElement, to rect: CGRect) {
        // Erişilebilirlik koordinatları: ana monitörün sol üst köşesi başlangıç
        let primaryH = NSScreen.screens.first?.frame.height ?? rect.maxY
        var p = CGPoint(x: rect.minX, y: primaryH - rect.maxY)
        var s = rect.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // Konum → boyut → konum: başka monitöre geçerken boyut sınırına takılmasın
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    }

    private static func exitFullScreen(_ item: Item) -> Bool {
        guard let w = item.window else { return false }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &v) == .success,
              (v as? Bool) == true else { return false }
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
        return true
    }
}

// MARK: - Panel açıkken Missing'i öne al (fare tıklamaları kesin çalışsın)

/// Kenarsız, öne gelmeyen paneller başka uygulama öndeyken SwiftUI tıklamalarını kaçırabiliyor.
/// Panel açılınca Missing kısa süreliğine öne gelir; kapanınca önceki uygulama geri gelir.
@MainActor enum PanelFocus {
    private static var previous: NSRunningApplication?

    static func grab(_ panel: NSPanel) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { previous = front }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// restore: pencere yerleştirilmediyse önceki uygulamayı geri öne al
    static func release(restore: Bool) {
        defer { previous = nil }
        guard restore, let p = previous, !p.isTerminated else { return }
        p.activate(options: [])
    }
}

// MARK: - Tıklanabilir yerler (SwiftUI dokunmalarına güvenmeden)

/// Kenarsız, öne gelmeyen panellerde SwiftUI dokunmaları kaybolabiliyor (⌘Tab kartları da bu yüzden
/// kendi fare işleyicisini kullanıyor). Tıklanabilir her yerin çerçevesi burada tutulur; tıklama ortak
/// olay dinleyicisinde yakalanır, altındaki eylem doğrudan çalıştırılır.
@MainActor final class ClickTargets {
    static let shared = ClickTargets()
    private var items: [String: (rect: CGRect, action: () -> Void)] = [:]

    func set(_ id: String, _ rect: CGRect, _ action: @escaping () -> Void) { items[id] = (rect, action) }
    func remove(_ id: String) { items[id] = nil }

    /// p: panelin sol üst köşesine göre nokta. Üst üste binenlerden en küçüğü (en içteki) seçilir.
    func hit(prefix: String, _ p: CGPoint) -> (() -> Void)? {
        items.filter { $0.key.hasPrefix(prefix) && $0.value.rect.contains(p) }
            .min { $0.value.rect.width * $0.value.rect.height < $1.value.rect.width * $1.value.rect.height }?
            .value.action
    }
}

@MainActor struct ClickTargetModifier: ViewModifier {
    let id: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                let r = g.frame(in: .global)
                Color.clear
                    .onAppear { ClickTargets.shared.set(id, r, action) }
                    .onChange(of: r) { ClickTargets.shared.set(id, $0, action) }
                    .onDisappear { ClickTargets.shared.remove(id) }
            }
        )
    }
}

extension View {
    /// Bu görünüme tıklanınca action çalışır (panel ortak olay dinleyicisi üzerinden)
    func clickTarget(_ id: String, _ action: @escaping () -> Void) -> some View {
        modifier(ClickTargetModifier(id: id, action: action))
    }
}

// MARK: - Dışarı tıklayınca kapat

/// Ekran bölme panelleri açıkken tıklamaları yakalar (ortak olay dinleyicisinden).
/// Panelin dışı: kapatır. İçi: kayıtlı tıklanabilir yere denk gelirse eylemi çalıştırır.
/// true dönerse tıklama yutulur ve arkadaki uygulamaya gitmez (⌘Tab paneli gibi).
@MainActor enum OutsideClick {
    static var handler: ((NSPoint) -> Bool)?

    static func install(for panel: NSPanel, targets prefix: String? = nil, close: @escaping () -> Void) {
        handler = { [weak panel] p in
            guard let panel, panel.isVisible else { return false }
            if panel.frame.contains(p) {
                guard let prefix else { return false }
                let local = CGPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
                guard let action = ClickTargets.shared.hit(prefix: prefix, local) else { return false }
                DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
                return true
            }
            close()
            return true
        }
    }
}

// MARK: - Monitör numaraları (birden fazla monitörde her ekranda büyük numara)

@MainActor final class MonitorBadges {
    private var panels: [NSPanel] = []

    /// avoid: ekran bölme seçicisinin çerçevesi; kart ona değmeyen ilk yere konur
    /// (sıra: üst orta, üst köşeler, alt kenar)
    func show(_ screens: [NSScreen], target: Int, avoid: NSRect? = nil) {
        hide()
        guard screens.count > 1 else { return }
        for (i, s) in screens.enumerated() {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none
            p.sharingType = .none
            p.appearance = NSAppearance(named: .darkAqua)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let host = GlassHostingView(rootView: MonitorBadgeView(number: i + 1, name: s.localizedName,
                                                                size: Screens.size(s), active: i == target))
            p.contentView = host
            let size = host.fittingSize
            p.setFrame(Self.spot(for: size, on: s, avoid: avoid), display: true)
            p.orderFrontRegardless()
            panels.append(p)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private static func spot(for size: NSSize, on s: NSScreen, avoid: NSRect?) -> NSRect {
        let vf = s.visibleFrame
        let topY = (vf.maxY - size.height - 36).rounded()
        let candidates = [
            NSRect(x: (vf.midX - size.width / 2).rounded(), y: topY, width: size.width, height: size.height),
            NSRect(x: (vf.minX + 36).rounded(), y: topY, width: size.width, height: size.height),
            NSRect(x: (vf.maxX - size.width - 36).rounded(), y: topY, width: size.width, height: size.height),
            NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.minY + 36).rounded(), width: size.width, height: size.height),
        ]
        guard let avoid else { return candidates[0] }
        let a = avoid.insetBy(dx: -12, dy: -12)
        return candidates.first { !$0.intersects(a) } ?? candidates[0]
    }
}

struct MonitorBadgeView: View {
    let number: Int
    let name: String
    let size: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text("\(number)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(active ? L("Hedef monitör") : size)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Brand.red : .white.opacity(0.6))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(minWidth: 180)
        .glass(radius: 24)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(active ? Brand.red : .clear, lineWidth: 3))
        .padding(8)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Ortak görünüm parçaları

/// Bir düzenin küçük çizimi. onZone verilirse bölmeler tıklanabilir.
struct LayoutShape: View {
    let layout: TileLayout
    var active: Int? = nil
    var labels: [Int: String] = [:]
    var icons: [Int: NSImage] = [:]
    var onZone: ((Int) -> Void)? = nil
    /// Verilirse bölmeler tıklanabilir yer olarak kaydedilir (ör. "tile.zone.")
    var targetPrefix: String? = nil
    @State private var hover: Int? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(layout.zones.indices, id: \.self) { i in
                    let z = layout.zones[i]
                    let g: CGFloat = 4
                    let w = max(4, z.width * geo.size.width - g)
                    let h = max(4, z.height * geo.size.height - g)
                    zone(i, w: w, h: h)
                        .position(x: z.midX * geo.size.width, y: z.midY * geo.size.height)
                }
            }
        }
    }

    private func zone(_ i: Int, w: CGFloat, h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isActive = active == i
        let isHover = hover == i && onZone != nil
        return shape
            .fill(isActive ? Color.accentColor.opacity(0.55) : .white.opacity(isHover ? 0.32 : 0.14))
            .overlay(shape.strokeBorder(isActive ? Color.accentColor : .white.opacity(isHover ? 0.6 : 0.25),
                                        lineWidth: isActive ? 2 : 1))
            .overlay(
                VStack(spacing: 3) {
                    if let icon = icons[i] {
                        Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                    }
                    if let label = labels[i] {
                        Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            )
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .modifier(OptionalClickTarget(id: targetPrefix.map { $0 + "\(i)" }) { onZone?(i) })
            .onHover { inside in hover = inside ? i : (hover == i ? nil : hover) }
            .onTapGesture { onZone?(i) }
    }
}

@MainActor struct OptionalClickTarget: ViewModifier {
    let id: String?
    let action: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if let id { content.clickTarget(id, action) } else { content }
    }
}

/// Monitör seçici (birden fazla monitör varsa)
struct MonitorPicker: View {
    let screens: [NSScreen]
    let here: Int
    let target: Int
    var targetPrefix: String? = nil
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(screens.indices, id: \.self) { i in
                Button { onPick(i) } label: {
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .bold, design: .rounded))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(screens[i].localizedName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(i == here ? L("buradasın") : Screens.size(screens[i]))
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(width: 150, alignment: .leading)
                    .modifier(SelectionLook(selected: i == target, radius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(OptionalClickTarget(id: targetPrefix.map { $0 + "\(i)" }) { onPick(i) })
            }
        }
    }
}

// MARK: - ⌘< ekran bölme paneli

final class TilingModel: ObservableObject {
    enum Step { case monitor, layout, assign }

    @Published var step: Step = .layout
    @Published var screens: [NSScreen] = []
    @Published var here = 0
    @Published var target = 0
    @Published var layoutIndex = 0
    @Published var zone = 0
    @Published var assignments: [Int: Int] = [:]   // bölme → pencere sırası
    @Published var highlight = 0
    @Published var items: [Item] = []

    var layout: TileLayout { TileLayout.all[layoutIndex] }
    var targetScreen: NSScreen? { screens.indices.contains(target) ? screens[target] : nil }
    var aspect: CGFloat {
        guard let s = targetScreen, s.visibleFrame.height > 0 else { return 16.0 / 10 }
        return s.visibleFrame.width / s.visibleFrame.height
    }
    func zoneOf(item i: Int) -> Int? { assignments.first { $0.value == i }?.key }
}

@MainActor final class TilingController {
    private let model = TilingModel()
    private let panel: KeyPanel
    private var host: NSHostingView<TilingView>?
    private let badges = MonitorBadges()
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    var itemsProvider: () -> [Item] = { [] }

    static let size = NSSize(width: 800, height: 560)

    init() {
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let h = GlassHostingView(rootView: TilingView(model: model, controller: self))
        h.sizingOptions = []   // panel boyutunu biz belirleriz; içerik değişince kaymasın
        panel.contentView = h
        host = h
    }

    var isVisible: Bool { panel.isVisible }

    /// ⌘<: kapalıysa aç, açıksa hedef monitörü değiştir
    func trigger() {
        if isVisible { cycleMonitor(1); return }
        let list = Screens.ordered
        guard !list.isEmpty else { return }
        model.screens = list
        model.here = Screens.index(of: screenUnderMouse(), in: list)
        model.target = model.here
        model.items = itemsProvider()
        model.assignments = [:]
        model.zone = 0
        model.highlight = 0
        model.step = (TileSettings.askMonitor && list.count > 1) ? .monitor : .layout

        let f = list[model.here].visibleFrame
        panel.setFrame(NSRect(x: (f.midX - Self.size.width / 2).rounded(),
                              y: (f.midY - Self.size.height / 2).rounded(),
                              width: Self.size.width, height: Self.size.height), display: true)
        PanelFocus.grab(panel)
        installMonitors()
        badges.show(model.screens, target: model.target, avoid: panel.frame)
    }

    func hide(restoreFocus: Bool = true) {
        removeMonitors()
        badges.hide()
        panel.orderOut(nil)
        PanelFocus.release(restore: restoreFocus)
    }

    // MARK: Eylemler

    func chooseMonitor(_ i: Int) {
        guard model.screens.indices.contains(i) else { return }
        model.target = i
        badges.show(model.screens, target: i, avoid: panel.frame)
        if model.step == .monitor { model.step = .layout }
    }

    func cycleMonitor(_ d: Int) {
        let n = model.screens.count
        guard n > 1 else { return }
        chooseMonitor(((model.target + d) % n + n) % n)
    }

    func chooseLayout(_ i: Int) {
        guard TileLayout.all.indices.contains(i) else { return }
        model.layoutIndex = i
        model.assignments = [:]
        model.zone = 0
        model.highlight = 0
        model.step = .assign
    }

    func selectZone(_ z: Int) {
        guard model.layout.zones.indices.contains(z) else { return }
        model.zone = z
    }

    func assign(_ itemIndex: Int) {
        guard model.items.indices.contains(itemIndex) else { return }
        for (z, v) in model.assignments where v == itemIndex { model.assignments[z] = nil }
        model.assignments[model.zone] = itemIndex
        advance()
    }

    func skipZone() { advance() }

    func clearZone() { model.assignments[model.zone] = nil }

    /// Bölmeler sırayla doldurulur; son bölmeden sonra uygulanır.
    /// (Bir bölmeye tıklayarak sırayı atlayabilirsin.)
    private func advance() {
        if model.zone + 1 < model.layout.zones.count {
            model.zone += 1
            model.highlight = model.items.indices.first { model.zoneOf(item: $0) == nil } ?? 0
        } else {
            apply()
        }
    }

    func back() {
        switch model.step {
        case .assign:
            if model.zone > 0 { model.zone -= 1 } else { model.step = .layout }
        case .layout:
            if TileSettings.askMonitor && model.screens.count > 1 { model.step = .monitor } else { hide() }
        case .monitor:
            hide()
        }
    }

    func apply() {
        guard let screen = model.targetScreen else { hide(); return }
        let layout = model.layout
        let pairs: [(Item, CGRect)] = model.assignments.keys.sorted().compactMap { z in
            guard let i = model.assignments[z], model.items.indices.contains(i), layout.zones.indices.contains(z) else { return nil }
            return (model.items[i], WindowMover.frame(layout.zones[z], on: screen))
        }
        hide(restoreFocus: pairs.isEmpty)
        WindowMover.place(pairs)
    }

    // MARK: Klavye

    private func handleKey(_ e: NSEvent) -> Bool {
        let digit = e.charactersIgnoringModifiers.flatMap { Int($0) }
        switch model.step {
        case .monitor:
            switch e.keyCode {
            case 53: hide()
            case 123: cycleMonitor(-1)
            case 124, 48: cycleMonitor(1)
            case 36, 76, 49: model.step = .layout
            default:
                if let n = digit, n >= 1 { chooseMonitor(n - 1) } else { return false }
            }
        case .layout:
            let n = TileLayout.all.count
            switch e.keyCode {
            case 53: back()
            case 48: cycleMonitor(1)
            case 123: model.layoutIndex = (model.layoutIndex - 1 + n) % n
            case 124: model.layoutIndex = (model.layoutIndex + 1) % n
            case 126: model.layoutIndex = (model.layoutIndex - 3 + n) % n
            case 125: model.layoutIndex = (model.layoutIndex + 3) % n
            case 36, 76: chooseLayout(model.layoutIndex)
            default:
                if let d = digit, d >= 1, d <= n { chooseLayout(d - 1) } else { return false }
            }
        case .assign:
            let n = model.items.count
            switch e.keyCode {
            case 53: back()
            case 48: cycleMonitor(1)
            case 126: if n > 0 { model.highlight = (model.highlight - 1 + n) % n }
            case 125: if n > 0 { model.highlight = (model.highlight + 1) % n }
            case 123: back()
            case 124, 49: skipZone()
            case 51, 117: clearZone()
            case 36, 76:
                if e.modifierFlags.contains(.command) || n == 0 { apply() } else { assign(model.highlight) }
            default:
                if let d = digit, d >= 1, d <= n { assign(d - 1) } else { return false }
            }
        }
        return true
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        OutsideClick.install(for: panel, targets: "tile.") { [weak self] in self?.hide() }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        OutsideClick.handler = nil
    }
}

struct TilingView: View {
    @ObservedObject var model: TilingModel
    let controller: TilingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label(L("Ekranı Böl"), systemImage: "rectangle.split.3x1")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if model.screens.count > 1 {
                    MonitorPicker(screens: model.screens, here: model.here, target: model.target,
                                  targetPrefix: "tile.mon.") { controller.chooseMonitor($0) }
                }
            }

            switch model.step {
            case .monitor: monitorStep
            case .layout: layoutStep
            case .assign: assignStep
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: TilingController.size.width, height: TilingController.size.height)
        .glass(radius: 26)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Monitör

    private var monitorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Hangi monitörde?")).font(.system(size: 14, weight: .semibold))
            HStack(spacing: 14) {
                ForEach(model.screens.indices, id: \.self) { i in
                    let s = model.screens[i]
                    VStack(spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 48, weight: .bold, design: .rounded))
                        Text(s.localizedName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(Screens.size(s)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        if i == model.here {
                            Text(L("Buradasın")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .modifier(SelectionLook(selected: i == model.target, radius: 18))
                    .contentShape(Rectangle())
                    .clickTarget("tile.step.mon.\(i)") { controller.chooseMonitor(i); model.step = .layout }
                    .onTapGesture { controller.chooseMonitor(i); model.step = .layout }
                    .onHover { if $0 { model.target = i } }
                }
            }
        }
    }

    // MARK: Düzen

    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Ekranı kaça bölelim?")).font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(TileLayout.all.indices, id: \.self) { i in
                    let l = TileLayout.all[i]
                    VStack(spacing: 6) {
                        LayoutShape(layout: l)
                            .aspectRatio(model.aspect, contentMode: .fit)
                            .frame(height: 92)
                        HStack(spacing: 6) {
                            Text("\(i + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                            Text(l.name).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .modifier(SelectionLook(selected: i == model.layoutIndex, radius: 14))
                    .contentShape(Rectangle())
                    .clickTarget("tile.layout.\(i)") { controller.chooseLayout(i) }
                    .onTapGesture { controller.chooseLayout(i) }
                    .onHover { if $0 { model.layoutIndex = i } }
                }
            }
        }
    }

    // MARK: Atama

    private var assignStep: some View {
        let layout = model.layout
        var labels: [Int: String] = [:]
        var icons: [Int: NSImage] = [:]
        for (z, i) in model.assignments where model.items.indices.contains(i) {
            labels[z] = model.items[i].app.localizedName ?? model.items[i].title
            if let icon = model.items[i].app.icon { icons[z] = icon }
        }
        for z in layout.zones.indices where labels[z] == nil { labels[z] = "\(z + 1)" }

        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Bölme %@ / %@: hangi pencere?", "\(model.zone + 1)", "\(layout.zones.count)"))
                    .font(.system(size: 14, weight: .semibold))
                LayoutShape(layout: layout, active: model.zone, labels: labels, icons: icons,
                            onZone: { controller.selectZone($0) }, targetPrefix: "tile.zone.")
                    .aspectRatio(model.aspect, contentMode: .fit)
                    .frame(width: 380, height: 250)
                HStack(spacing: 8) {
                    Button(L("Boş bırak")) { controller.skipZone() }
                        .clickTarget("tile.btn.skip") { controller.skipZone() }
                    Button(L("Düzenlere dön")) { model.step = .layout }
                        .clickTarget("tile.btn.back") { model.step = .layout }
                    Spacer()
                    Button(L("Uygula")) { controller.apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.assignments.isEmpty)
                        .clickTarget("tile.btn.apply") { if !model.assignments.isEmpty { controller.apply() } }
                }
                .frame(width: 380)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        if model.items.isEmpty {
                            Text(L("Taşınabilir pencere yok")).foregroundStyle(.white.opacity(0.5)).padding()
                        }
                        ForEach(model.items.indices, id: \.self) { i in
                            TileWindowRow(item: model.items[i], number: i + 1,
                                          zone: model.zoneOf(item: i), highlighted: i == model.highlight)
                                .id(i)
                                .contentShape(Rectangle())
                                .clickTarget("tile.row.\(i)") { controller.assign(i) }
                                .onTapGesture { controller.assign(i) }
                                .onHover { if $0 { model.highlight = i } }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.highlight) { h in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(h, anchor: .center) }
                }
            }
        }
    }
}

struct TileWindowRow: View {
    let item: Item
    let number: Int
    let zone: Int?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.app.icon ?? NSImage())
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.app.localizedName ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let zone {
                Text(L("Bölme %@", "\(zone + 1)"))
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.8)))
            } else if number <= 9 {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.10)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(SelectionLook(selected: highlighted, radius: 12))
        .opacity(zone == nil ? 1 : 0.7)
    }
}

// MARK: - ⌘Tab kartındaki bölme düğmesi: tek pencere için bölme seçici

final class ZonePickerModel: ObservableObject {
    @Published var screens: [NSScreen] = []
    @Published var here = 0
    @Published var target = 0
    @Published var title = ""
    @Published var icon: NSImage?

    var aspect: CGFloat {
        guard screens.indices.contains(target), screens[target].visibleFrame.height > 0 else { return 16.0 / 10 }
        let f = screens[target].visibleFrame
        return f.width / f.height
    }
}

@MainActor final class ZonePickerController {
    private let model = ZonePickerModel()
    private let panel: KeyPanel
    private var host: NSHostingView<ZonePickerView>?
    private let badges = MonitorBadges()
    private var item: Item?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let h = GlassHostingView(rootView: ZonePickerView(model: model, controller: self))
        h.sizingOptions = []   // monitör değişince kutu yerinde kalsın
        panel.contentView = h
        host = h
    }

    func show(_ item: Item) {
        guard item.window != nil else { NSSound.beep(); return }
        self.item = item
        let list = Screens.ordered
        guard !list.isEmpty else { return }
        model.screens = list
        model.here = Screens.index(of: screenUnderMouse(), in: list)
        model.target = model.here
        model.title = item.title
        model.icon = item.app.icon

        // Sabit boyut: monitör seçimiyle değişmez, içerik kesilmez
        let size = NSSize(width: ZonePickerView.width(screens: list.count), height: ZonePickerView.height)
        let screen = list[model.here]
        let f = screen.visibleFrame
        let m = NSEvent.mouseLocation
        let x = min(max(f.minX + 8, m.x - size.width / 2), f.maxX - size.width - 8)
        let y = min(max(f.minY + 8, m.y - size.height / 2), f.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        PanelFocus.grab(panel)
        installMonitors()
        badges.show(list, target: model.target, avoid: panel.frame)
    }

    func hide(restoreFocus: Bool = true) {
        removeMonitors()
        badges.hide()
        panel.orderOut(nil)
        PanelFocus.release(restore: restoreFocus)
        item = nil
    }

    func chooseMonitor(_ i: Int) {
        guard model.screens.indices.contains(i) else { return }
        model.target = i
        badges.show(model.screens, target: i, avoid: panel.frame)
    }

    func pick(_ zone: CGRect) {
        guard let item, model.screens.indices.contains(model.target) else { hide(); return }
        let rect = WindowMover.frame(zone, on: model.screens[model.target])
        hide(restoreFocus: false)
        WindowMover.place([(item, rect)])
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch e.keyCode {
                case 53: self.hide()
                case 48, 124:
                    let n = self.model.screens.count
                    if n > 1 { self.chooseMonitor((self.model.target + 1) % n) }
                case 123:
                    let n = self.model.screens.count
                    if n > 1 { self.chooseMonitor((self.model.target - 1 + n) % n) }
                default:
                    if let d = e.charactersIgnoringModifiers.flatMap({ Int($0) }), d >= 1 { self.chooseMonitor(d - 1) } else { return false }
                }
                return true
            }
            return handled ? nil : e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        OutsideClick.install(for: panel, targets: "zone.") { [weak self] in self?.hide() }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        OutsideClick.handler = nil
    }
}

struct ZonePickerView: View {
    @ObservedObject var model: ZonePickerModel
    let controller: ZonePickerController

    static func width(screens: Int) -> CGFloat {
        screens > 1 ? max(600, CGFloat(screens) * 156 + 280) : 600
    }
    /// başlık 40 + 3 satır düzen (3 × 128 + 2 × 12 = 408) + alt yazı 18 + aralıklar 24 + kenar 36 = 526
    static let height: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(L("Ekranın hangi bölmesine?")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 10)
                if model.screens.count > 1 {
                    MonitorPicker(screens: model.screens, here: model.here, target: model.target,
                                  targetPrefix: "zone.mon.") { controller.chooseMonitor($0) }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(170), spacing: 12), count: 3), spacing: 12) {
                ForEach(TileLayout.all) { l in
                    VStack(spacing: 5) {
                        LayoutShape(layout: l, onZone: { z in controller.pick(l.zones[z]) }, targetPrefix: "zone.\(l.id).")
                            .aspectRatio(model.aspect, contentMode: .fit)
                            .frame(width: 154, height: 86)
                        Text(l.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(8)
                    .frame(width: 170, height: 128)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                }
            }
        }
        .padding(18)
        .frame(width: Self.width(screens: model.screens.count), height: Self.height, alignment: .top)
        .glass(radius: 24)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
    }
}
