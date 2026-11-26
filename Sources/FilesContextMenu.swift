import AppKit
import Combine
import SwiftUI

// MARK: - Dosyalar'ın kendi sağ tık menüsü
//
// İçerik bugünkü NSMenu'dan gelir (eylemler, hedefler, alt menüler aynen çalışır); sadece çizim bizim:
// temaya göre zemin, simgeli satırlar, sağda kısayol, alt menüler yana açılır. Dışarı tıklayınca, Esc ile ya da
// bir satır seçilince kapanır. Görünüm Dosyalar temasını izler (FilesMenuLook): Missing koyu cam,
// Finder gerçek macOS menüsü, Windows 11 Gezgini menüsü, Cam yarı saydam; Finder/Windows/Cam sistemin açık/koyu ayarıyla.

@MainActor final class FilesContextMenu: ObservableObject {
    static let shared = FilesContextMenu()

    private var panels: [NSPanel] = []          // 0: ana menü, 1…: yana açılan alt menüler
    @Published private var openItems: [NSMenuItem?] = []   // her seviyede açık alt menünün sahibi
    private var monitors: [Any] = []
    private var root: NSMenu?
    private var pendingOpen: DispatchWorkItem?
    private var bag: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?

    /// Menünün paleti: panel ana pencerenin dışında, o yüzden tema ayarı + uygulamanın görünümünden kurulur
    @Published private(set) var palette: FilesPalette = FilesContextMenu.makePalette()

    private init() {
        // $theme değer yazılmadan önce yayınlar: yeni temayı parametreden al
        FilesThemeStore.shared.$theme.dropFirst().sink { [weak self] t in
            MainActor.assumeIsolated { self?.refreshPalette(theme: t) }
        }.store(in: &bag)
        // Sistem açık/koyu değişince
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshPalette() } }
        }
    }

    /// Missing menüsü her zaman koyu cam; diğer temalar sistemin açık/koyu ayarını izler
    static func makePalette(theme: FilesTheme? = nil) -> FilesPalette {
        let theme = theme ?? FilesThemeStore.shared.theme
        if theme == .missing { return FilesPalette(theme: .missing, dark: true) }
        let dark = theme.forcesDark || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return FilesPalette(theme: theme, dark: dark)
    }

    private func refreshPalette(theme: FilesTheme? = nil) {
        let p = Self.makePalette(theme: theme)
        guard p.theme != palette.theme || p.dark != palette.dark else { return }
        palette = p
        panels.forEach { $0.appearance = NSAppearance(named: p.dark ? .darkAqua : .aqua) }
    }

    var isOpen: Bool { !panels.isEmpty }
    /// Menünün dışına tıklanıp kapandığı son an (systemUptime): menüyü açan düğmeye basış onu kapattıysa
    /// bırakışta yeniden açılmasın (Esc ya da seçimle kapanış sayılmaz)
    private(set) var closedByClickAt: TimeInterval = 0

    /// Menüyü ekrandaki bir noktada aç (sol üst köşe orada olur; sığmazsa yukarı / sola kayar)
    private var lastShow: (time: TimeInterval, point: NSPoint)?

    func show(_ menu: NSMenu, at point: NSPoint, eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Aynı sağ tık için ikinci kez açılmasın (seçim değişince görünüm yeniden çizilirken tekrar tetiklenebilir)
        if let l = lastShow, abs(l.time - eventTime) < 0.25, hypot(l.point.x - point.x, l.point.y - point.y) < 4, isOpen { return }
        lastShow = (eventTime, point)
        close()
        refreshPalette()
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        // İçeriği kendi menümüze taşı: tarayıcı menüsünü yeniden kurarsa açık menü bozulmasın
        let snapshot = NSMenu()
        snapshot.autoenablesItems = false
        let items = menu.items
        menu.removeAllItems()
        items.forEach(snapshot.addItem)
        root = snapshot
        present(snapshot, level: 0, anchor: NSRect(origin: point, size: .zero), side: .below)
        installMonitors()
    }

    func close() {
        pendingOpen?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        openItems.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        root = nil
    }

    // MARK: Paneller

    private enum Side { case below, right }

    private func present(_ menu: NSMenu, level: Int, anchor: NSRect, side: Side) {
        // Bu seviyeden sonrakileri kapat
        while panels.count > level { panels.removeLast().orderOut(nil) }
        while openItems.count > level { openItems.removeLast() }

        let view = FilesMenuList(items: menu.items, level: level, controller: self)
        let host = FilesMenuHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let size = host.fittingSize
        let panel = FilesMenuPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // Barındırılan görünümler (renk etiketleri) ve sistem renkleri menünün açık/koyu hâlini izlesin
        panel.appearance = NSAppearance(named: palette.dark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.isReleasedWhenClosed = false

        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        switch side {
        case .below:
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
            if origin.y < vis.minY { origin.y = min(anchor.minY, vis.maxY - size.height) }
            if origin.x + size.width > vis.maxX { origin.x = anchor.minX - size.width }
        case .right:
            // Satırın hizasında, sağa; sığmazsa sola
            origin = NSPoint(x: anchor.maxX - 2, y: anchor.maxY - size.height + 6)
            if origin.x + size.width > vis.maxX { origin.x = anchor.minX - size.width + 2 }
            if origin.y < vis.minY { origin.y = vis.minY }
        }
        origin.x = max(vis.minX, origin.x)
        panel.setFrameOrigin(origin)
        // Odak pencerede kalsın (panel anahtar olmaz); Esc yerel izleyiciyle yakalanır
        panel.orderFrontRegardless()
        panels.append(panel)
        openItems.append(nil)
    }

    /// Satırın üstüne gelindi: alt menüyse biraz bekleyip yana aç, değilse daha derin menüleri kapat
    func hover(_ item: NSMenuItem, level: Int, rowFrame: NSRect) {
        pendingOpen?.cancel()
        guard let sub = item.submenu, item.isEnabled else {
            closeDeeper(than: level)
            return
        }
        if openItems.indices.contains(level), openItems[level] === item { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.openSubmenu(item, sub, level: level, rowFrame: rowFrame) }
        }
        pendingOpen = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func openSubmenu(_ item: NSMenuItem, _ sub: NSMenu, level: Int, rowFrame: NSRect) {
        guard panels.indices.contains(level) else { return }
        if sub.numberOfItems == 0 { sub.delegate?.menuNeedsUpdate?(sub) }
        sub.update()
        present(sub, level: level + 1, anchor: screenRect(rowFrame, in: panels[level]), side: .right)
        openItems[level] = item
    }

    private func closeDeeper(than level: Int) {
        while panels.count > level + 1 { panels.removeLast().orderOut(nil) }
        while openItems.count > level + 1 { openItems.removeLast() }
        if openItems.indices.contains(level) { openItems[level] = nil }
    }

    /// SwiftUI'deki satır çerçevesi (pencere içi, üstten) → ekran
    private func screenRect(_ r: NSRect, in panel: NSPanel) -> NSRect {
        let f = panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    fileprivate func click(_ item: NSMenuItem, level: Int, rowFrame: NSRect) {
        guard item.isEnabled else { return }
        if let sub = item.submenu {
            pendingOpen?.cancel()
            openSubmenu(item, sub, level: level, rowFrame: rowFrame)
            return
        }
        close()
        guard let action = item.action else { return }
        DispatchQueue.main.async { NSApp.sendAction(action, to: item.target, from: item) }
    }

    fileprivate var openSubmenuOwners: [NSMenuItem?] { openItems }

    // MARK: Kapanma

    /// Uygulama içinde menünün dışına fare inişi
    func closeForOutsideClick() {
        guard isOpen else { return }
        closedByClickAt = ProcessInfo.processInfo.systemUptime
        close()
    }

    private func installMonitors() {
        let ours: (NSEvent) -> Bool = { [weak self] e in
            guard let self, let w = e.window else { return false }
            return self.panels.contains { $0 === w }
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { if !ours(e) { self?.closeForOutsideClick() } }
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return e }
                if e.keyCode == 53 { self.close(); return nil }   // Esc
                return e
            }
        } as Any)
        // Yalnız gerçek kaydırmada kapan: trackpad'de iki parmakla sağ tık, hareketi sıfır olan bir
        // kaydırma olayı da gönderir ("başlayabilir" evresi); onu kaydırma sayarsak menü açılır açılmaz kapanır
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
            let moved = abs(e.scrollingDeltaX) > 0.5 || abs(e.scrollingDeltaY) > 0.5
            MainActor.assumeIsolated { if moved, !ours(e) { self?.close() } }
            return e
        } as Any)
    }
}

private final class FilesMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Panel anahtar pencere değilken gelen ilk tıklama da satıra ulaşsın: NSHostingView varsayılan olarak
/// ilk tıklamayı pencereyi öne almak için harcıyordu, menüde bir şeyi seçmek için iki kez tıklamak gerekiyordu.
final class FilesMenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Tema görünümü

/// Menüye gömülen kendi görünümlü satırlar (ör. renk etiketleri) için: satır metninin menü içeriğinin solundan uzaklığı
/// (vurgu boşluğu + simge sütunu + aradaki boşluk); böylece gömülü satır diğer satırların yazısıyla aynı hizada başlar
extension FilesContextMenu {
    static func textInset(for p: FilesPalette) -> CGFloat {
        let look = FilesMenuLook(p: p)
        return look.rowPadding + look.iconColumn + look.gap
    }
}

/// Menünün temaya göre ölçü ve renkleri. Panel ana pencerenin dışında olduğu için palet
/// tema ayarı + sistem görünümünden kurulur (FilesContextMenu.palette).
/// missing: koyu cam, kırmızı vurgu · finder: gerçek macOS menüsü · windows: Windows 11 Gezgini menüsü · glass: yarı saydam cam
private struct FilesMenuLook {
    let p: FilesPalette
    private var t: FilesTheme { p.theme }

    // MARK: Ölçüler

    var radius: CGFloat {
        switch t {
        case .missing: return 12
        case .finder: return 8
        case .windows: return 8
        case .glass: return 14
        }
    }
    /// Kenar ile satır vurgusu arasındaki boşluk
    var pad: CGFloat {
        switch t {
        case .windows: return 4
        case .glass: return 6
        default: return 5
        }
    }
    var rowHeight: CGFloat {
        switch t {
        case .missing: return 24
        case .finder: return 22
        case .windows: return 32
        case .glass: return 26
        }
    }
    var rowRadius: CGFloat {
        switch t {
        case .missing: return 7
        case .finder: return 5
        case .windows: return 4
        case .glass: return 9
        }
    }
    /// Satır içi yatay boşluk (vurgunun kenarından metne/simgeye)
    var rowPadding: CGFloat {
        switch t {
        case .finder: return 6
        case .windows: return 10
        default: return 8
        }
    }
    var minWidth: CGFloat {
        switch t {
        case .windows: return 264
        case .finder: return 220
        default: return 230
        }
    }
    var iconColumn: CGFloat { t == .windows ? 20 : 18 }
    var iconSize: CGFloat { t == .finder ? 14 : (t == .windows ? 16 : 15) }
    var gap: CGFloat { t == .windows ? 12 : (t == .finder ? 6 : 8) }
    var fontSize: CGFloat { 13 }
    var shortcutSize: CGFloat { 12 }

    var separatorInset: CGFloat {
        switch t {
        case .windows: return 0
        case .glass: return 12
        default: return 10
        }
    }
    var separatorSpacing: CGFloat { t == .windows ? 4 : 5 }

    // MARK: Renkler

    var text: Color {
        switch t {
        case .missing: return .white.opacity(0.92)
        case .finder: return Color(nsColor: .labelColor)
        case .windows: return p.fg.opacity(p.dark ? 1 : 0.9)
        case .glass: return p.fg.opacity(0.9)
        }
    }
    var secondary: Color {
        switch t {
        case .missing: return .white.opacity(0.45)
        case .finder: return Color(nsColor: .secondaryLabelColor)
        case .windows: return p.fg.opacity(p.dark ? 0.62 : 0.55)
        case .glass: return p.fg.opacity(0.5)
        }
    }
    var icon: Color {
        switch t {
        case .missing: return .white.opacity(0.78)
        case .finder: return Color(nsColor: .labelColor)
        case .windows: return p.fg.opacity(p.dark ? 0.92 : 0.82)
        case .glass: return p.fg.opacity(0.75)
        }
    }

    var hoverFill: Color {
        switch t {
        case .missing: return .white.opacity(0.10)
        case .finder: return p.accent                       // controlAccentColor
        case .windows: return p.fg.opacity(0.06)
        case .glass: return p.glassFill(0.14)
        }
    }
    var hoverStroke: Color? { t == .glass ? p.glassStroke(0.22) : nil }
    var hoverText: Color { t == .finder ? .white : text }
    var hoverSecondary: Color { t == .finder ? .white.opacity(0.8) : secondary }
    var hoverIcon: Color {
        switch t {
        case .missing: return Brand.red
        case .finder: return .white
        case .windows: return icon
        case .glass: return glassAccent
        }
    }
    /// İşaretli satırın tiki
    var check: Color { t == .glass ? glassAccent : (t == .missing ? .white : text) }
    /// Cam vurgusu (mor); açık zeminde açık mor okunmaz, koyulaştır
    private var glassAccent: Color { p.dark ? p.accent : Color(red: 0.42, green: 0.30, blue: 0.88) }

    /// Çöp sepeti gibi yıkıcı satırlar; yalnız Missing renklendirir (macOS ve Windows normal metin kullanır)
    var destructiveText: Color? { t == .missing ? Color(red: 1, green: 0.36, blue: 0.34) : nil }
    var destructiveIcon: Color? { t == .missing ? Brand.red : nil }

    var separator: Color {
        switch t {
        case .missing: return .white.opacity(0.10)
        case .finder: return Color(nsColor: .separatorColor)
        case .windows: return p.divider
        case .glass: return p.fg.opacity(p.dark ? 0.14 : 0.10)
        }
    }

    var border: Color {
        switch t {
        case .missing: return .white.opacity(0.10)
        case .finder: return p.dark ? .white.opacity(0.14) : .black.opacity(0.08)
        case .windows: return p.dark ? .white.opacity(0.08) : .black.opacity(0.10)
        case .glass: return p.dark ? .white.opacity(0.25) : .black.opacity(0.10)
        }
    }

    @ViewBuilder var background: some View {
        switch t {
        case .missing:
            ZStack {
                GlassBlur(material: .hudWindow, appearance: .darkAqua)
                Color.black.opacity(0.38)
                LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.01)], startPoint: .top, endPoint: .bottom)
            }
        case .finder:
            GlassBlur(material: .menu, appearance: p.dark ? .darkAqua : .aqua)
        case .windows:
            p.dark ? Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2C / 255.0)
                   : Color(red: 0xF9 / 255.0, green: 0xF9 / 255.0, blue: 0xF9 / 255.0)
        case .glass:
            ZStack {
                GlassBlur(material: .hudWindow, appearance: p.dark ? .darkAqua : .aqua)
                Color.white.opacity(p.dark ? 0.06 : 0.30)
                LinearGradient(colors: [.white.opacity(p.dark ? 0.10 : 0.25), .clear], startPoint: .top, endPoint: .center)
            }
        }
    }

    /// Windows 11: en sık işlemler menünün üstünde yalnız simgeli düğmeler olarak durur
    var usesQuickBar: Bool { t == .windows }
}

// MARK: Görünüm

private struct FilesMenuList: View {
    let items: [NSMenuItem]
    let level: Int
    @ObservedObject var controller: FilesContextMenu

    var body: some View {
        let look = FilesMenuLook(p: controller.palette)
        let quick = look.usesQuickBar ? FilesMenuShortcuts.quickBarItems(in: items) : []
        let rows = visible(excluding: quick)
        let shape = RoundedRectangle(cornerRadius: look.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if !quick.isEmpty {
                FilesMenuQuickBar(items: quick, level: level, controller: controller, look: look)
                if !rows.isEmpty { separator(look) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    separator(look)
                } else if let v = item.view {
                    HostedMenuView(view: v)
                        .frame(width: max(v.fittingSize.width, 200), height: max(v.fittingSize.height, 24), alignment: .leading)
                } else {
                    FilesMenuRow(item: item, level: level, controller: controller, look: look)
                }
            }
        }
        .padding(look.pad)
        .frame(minWidth: look.minWidth, alignment: .leading)
        .fixedSize()
        .background(look.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(look.border, lineWidth: 1))
        .environment(\.filesPalette, controller.palette)
        .environment(\.colorScheme, controller.palette.dark ? .dark : .light)
    }

    private func separator(_ look: FilesMenuLook) -> some View {
        Rectangle().fill(look.separator).frame(height: 1)
            .padding(.horizontal, look.separatorInset).padding(.vertical, look.separatorSpacing)
    }

    /// Gizli satırları (ve üst düğme çubuğuna taşınanları) ve art arda / baştaki / sondaki ayıraçları at
    private func visible(excluding skip: [NSMenuItem]) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for i in items where !i.isHidden && !skip.contains(where: { $0 === i }) {
            if i.isSeparatorItem, out.last?.isSeparatorItem ?? true { continue }
            out.append(i)
        }
        if out.last?.isSeparatorItem == true { out.removeLast() }
        return out
    }
}

private struct FilesMenuRow: View {
    let item: NSMenuItem
    let level: Int
    @ObservedObject var controller: FilesContextMenu
    let look: FilesMenuLook
    @State private var hover = false
    @State private var frame: NSRect = .zero

    var body: some View {
        let enabled = item.isEnabled
        let lit = (hover || isOpenParent) && enabled
        let danger = FilesMenuShortcuts.isDestructive(item)
        let textColor = danger ? (look.destructiveText ?? (lit ? look.hoverText : look.text)) : (lit ? look.hoverText : look.text)
        let iconColor = lit ? look.hoverIcon : (danger ? (look.destructiveIcon ?? look.icon) : look.icon)
        HStack(spacing: look.gap) {
            ZStack {
                if item.state == .on {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lit ? look.hoverText : look.check)
                } else if item.state == .mixed {
                    Image(systemName: "minus").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lit ? look.hoverText : look.check)
                } else if let img = icon {
                    Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original)
                        .resizable().scaledToFit().frame(width: look.iconSize, height: look.iconSize)
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: look.iconColumn)
            Text(item.title).font(.system(size: look.fontSize)).lineLimit(1)
                .foregroundStyle(textColor)
            Spacer(minLength: 20)
            if let k = FilesMenuShortcuts.text(for: item) {
                Text(k).font(.system(size: look.shortcutSize))
                    .foregroundStyle(lit ? look.hoverSecondary : look.secondary)
            }
            if item.submenu != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: look.p.theme == .windows ? 11 : 10, weight: look.p.theme == .windows ? .regular : .semibold))
                    .foregroundStyle(lit ? look.hoverSecondary : look.secondary)
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .padding(.horizontal, look.rowPadding)
        .frame(height: look.rowHeight)
        .background(highlight(lit))
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame = $0 }
        })
        .onHover { h in
            hover = h
            if h { controller.hover(item, level: level, rowFrame: frame) }
        }
        .onTapGesture { controller.click(item, level: level, rowFrame: frame) }
        .help(item.toolTip ?? "")
    }

    private func highlight(_ lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: look.rowRadius, style: .continuous)
        return shape.fill(lit ? look.hoverFill : .clear)
            .overlay(shape.strokeBorder(lit ? (look.hoverStroke ?? .clear) : .clear, lineWidth: 1))
    }

    private var isOpenParent: Bool {
        let o = controller.openSubmenuOwners
        return o.indices.contains(level) && o[level] === item
    }

    private var icon: NSImage? {
        if let i = item.image { return i }
        guard let s = FilesMenuShortcuts.symbol(for: item),
              let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) else { return nil }
        img.isTemplate = true
        return img
    }
}

/// Windows 11 sağ tık menüsünün üstündeki simge düğmeleri (Kes, Kopyala, Yapıştır, Yeniden adlandır, Sil)
private struct FilesMenuQuickBar: View {
    let items: [NSMenuItem]
    let level: Int
    @ObservedObject var controller: FilesContextMenu
    let look: FilesMenuLook

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                FilesMenuQuickButton(item: item, level: level, controller: controller, look: look)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FilesMenuQuickButton: View {
    let item: NSMenuItem
    let level: Int
    @ObservedObject var controller: FilesContextMenu
    let look: FilesMenuLook
    @State private var hover = false

    var body: some View {
        let enabled = item.isEnabled
        Image(systemName: FilesMenuShortcuts.symbol(for: item) ?? "questionmark")
            .font(.system(size: 15))
            .foregroundStyle(look.icon)
            .frame(width: 40, height: 36)
            .background(RoundedRectangle(cornerRadius: look.rowRadius, style: .continuous)
                .fill(hover && enabled ? look.hoverFill : .clear))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                if h { controller.hover(item, level: level, rowFrame: .zero) }
            }
            .onTapGesture { controller.click(item, level: level, rowFrame: .zero) }
            .help(item.title)
            .accessibilityLabel(item.title)
    }
}

/// NSMenuItem'ın kendi görünümü (renk etiketleri satırı)
private struct HostedMenuView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.removeFromSuperview()
        view.frame.origin = .zero
        box.addSubview(view)
        return box
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Simge ve kısayol eşleşmeleri

@MainActor enum FilesMenuShortcuts {
    private static func name(_ item: NSMenuItem) -> String { item.action.map(NSStringFromSelector) ?? "" }

    static func symbol(for item: NSMenuItem) -> String? {
        switch name(item) {
        case "openSelection:": return "arrow.up.forward.app"
        case "openSelectionInTab:": return "plus.rectangle.on.rectangle"
        case "toggleQuickLook:": return "eye"
        case "renameSelection:": return "pencil"
        case "duplicateSelection:": return "plus.square.on.square"
        case "cut:": return "scissors"
        case "copy:": return "doc.on.doc"
        case "copyPath:": return "link"
        case "paste:": return "doc.on.clipboard"
        case "moveHere:": return "arrow.down.doc"
        case "newFolder:": return "folder.badge.plus"
        case "pinSelection:": return "sidebar.left"
        case "openInTerminal:": return "terminal"
        case "revealInFinder:": return "macwindow"
        case "trashSelection:": return "trash"
        case "showList:": return "list.bullet"
        case "showGrid:": return "square.grid.2x2"
        case "showColumns:": return "rectangle.split.3x1"
        case "toggleHidden:": return "eye.slash"
        default: break
        }
        switch item.title {
        case L("Birlikte aç"): return "app.badge"
        case L("Paylaş"): return "square.and.arrow.up"
        case L("Sırala"): return "arrow.up.arrow.down"
        default: return nil
        }
    }

    /// Yıkıcı satır (Missing temasında kırmızı çizilir)
    static func isDestructive(_ item: NSMenuItem) -> Bool { name(item) == "trashSelection:" }

    /// Windows 11'deki gibi menünün üstünde simge düğmesi olacak satırlar, Windows'un sırasıyla.
    /// En az iki tane yoksa çubuk kurulmaz (tek düğme tuhaf durur), satırlar yerinde kalır.
    static func quickBarItems(in items: [NSMenuItem]) -> [NSMenuItem] {
        let order = ["cut:", "copy:", "paste:", "renameSelection:", "trashSelection:"]
        let found = order.compactMap { sel in
            items.first { !$0.isHidden && $0.view == nil && $0.submenu == nil && name($0) == sel }
        }
        return found.count >= 2 ? found : []
    }

    static func text(for item: NSMenuItem) -> String? {
        if !item.keyEquivalent.isEmpty {
            let m = item.keyEquivalentModifierMask
            var s = ""
            if m.contains(.control) { s += "⌃" }
            if m.contains(.option) { s += "⌥" }
            if m.contains(.shift) { s += "⇧" }
            if m.contains(.command) { s += "⌘" }
            return s + item.keyEquivalent.uppercased()
        }
        switch name(item) {
        case "toggleQuickLook:": return "Space"
        case "renameSelection:": return "↩"
        case "duplicateSelection:": return "⌘D"
        case "copy:": return "⌘C"
        case "copyPath:": return "⌥⌘C"
        case "paste:": return "⌘V"
        case "moveHere:": return "⌥⌘V"
        case "newFolder:": return "⇧⌘N"
        case "trashSelection:": return "⌘⌫"
        case "revealInFinder:": return "⌥⌘R"
        case "showList:": return "⌘1"
        case "showGrid:": return "⌘2"
        case "showColumns:": return "⌘3"
        case "toggleHidden:": return "⇧⌘."
        default: return nil
        }
    }
}
