import Cocoa
import SwiftUI
import ScreenCaptureKit

// MARK: - Finder sekmeleri (Windows gibi)
//
// Finder'ın sekme çubuğunda sekmeler tüm genişliğe yayılır; tek sekme bile çubuğu boydan boya kaplar
// ve çok sekmede hangisinin hangisi olduğu zor seçilir. Finder öndeyken onun sekme çubuğunun tam
// üstüne kendi şeridimizi koyarız: sekmeler soldan dizilir, belli bir genişlikleri vardır (en fazla
// 220 pt), çoğaldıkça daralır (en az 120 pt), sığmayınca yana kayar. Tıklama, kapatma ve yeni
// sekme Finder'ın kendi sekmelerine Erişilebilirlik üzerinden iletilir; Finder'ın kendisine dokunulmaz.
//
// Sadece olayları dinler (AXObserver): Finder arkadayken hiçbir şey yapmaz.

enum FinderTabsSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "finderTabs.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "finderTabs.enabled") }
    }
}

struct FinderTab: Identifiable, Equatable {
    let id: Int
    let title: String
    let selected: Bool
    static func == (a: FinderTab, b: FinderTab) -> Bool { a.id == b.id && a.title == b.title && a.selected == b.selected }
}

final class FinderTabsModel: ObservableObject {
    @Published var tabs: [FinderTab] = []
    /// Şerit yukarıdan kayarak gelir
    @Published var shown = false
    /// Finder'ın kendi sekme çubuğunun rengi (Ekran Kaydı izni varsa ölçülür)
    @Published var barColor: NSColor?
    var onSelect: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }
    var onNew: () -> Void = {}
}

/// Şerit penceresi tıklamaları anında alsın (Finder öne gelmeden)
private final class TabsHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class FinderTabsController {
    private let model = FinderTabsModel()
    private var panel: NSPanel?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var tabElements: [AXUIElement] = []
    private var newTabButton: AXUIElement?
    private var pending = false
    private var running = false

    private static let finderID = "com.apple.finder"
    private static let notes: [String] = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXCreatedNotification, kAXUIElementDestroyedNotification,
        kAXValueChangedNotification, kAXTitleChangedNotification, kAXFocusedUIElementChangedNotification,
    ]

    init() {
        model.onSelect = { [weak self] i in self?.press(i) }
        model.onClose = { [weak self] i in self?.closeTab(i) }
        model.onNew = { [weak self] in self?.newTab() }
    }

    func start() {
        guard FinderTabsSettings.enabled, !running else { return }
        running = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        appChanged()
    }

    func stop() {
        running = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detach()
        panel?.orderOut(nil)
    }

    // MARK: Finder'ı izleme

    /// Finder öne gelince ya da arkaya geçince: şerit gizlenmez, sadece katmanı değişir
    /// (önde: Finder'ın üstünde yüzer; arkada: Finder penceresinin hemen üstüne yapışık kalır)
    @objc private func appChanged() {
        guard running else { return }
        if observedPid == 0 || NSRunningApplication(processIdentifier: observedPid)?.isTerminated != false,
           let f = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderID).first {
            attach(f.processIdentifier)
        }
        refresh()
    }

    private var finderFront: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID }

    private func attach(_ pid: pid_t) {
        guard observedPid != pid else { return }
        detach()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FinderTabsController>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.scheduleRefresh() }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notes { AXObserverAddNotification(obs, app, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        observedPid = pid
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        observedPid = 0
    }

    /// Bildirimler art arda gelir (ör. pencere sürüklenirken): bir turda bir kez yenile
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.refresh()
            }
        }
    }

    // MARK: Okuma ve yerleştirme

    /// Son yerleştirilen pencere ve o pencerede sekme çubuğu var mıydı (yeni belirince yerine oturur)
    private var lastWindow: CGWindowID = 0
    private var lastHadTabs = false

    private func refresh() {
        guard running, observedPid != 0 else { return }
        let app = AXUIElementCreateApplication(observedPid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, (finderFront ? kAXFocusedWindowAttribute : kAXMainWindowAttribute) as CFString, &v)
        // Finder bir an cevap veremedi (ör. sağ tık menüsü açıkken): olduğu gibi bırak
        if err == .cannotComplete { return }
        guard err == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { hide(); return }
        let win = v as! AXUIElement
        // Sağ tık menüsü açıkken Finder "odaktaki pencere" olarak menüyü verebilir: pencere değilse dokunma
        guard (AX.attr(win, kAXRoleAttribute) as String?) == kAXWindowRole as String,
              (AX.attr(win, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String else { return }
        if (AX.attr(win, kAXMinimizedAttribute) as Bool?) == true { hide(); return }
        guard let wid = axWindowID(win) else { return }
        guard let group = Self.tabGroup(in: win), let frame = Self.frame(of: group) else {
            // Başka pencereye geçildiyse gizle; aynı pencerede grup okunamadıysa (menü açık vb.) şerit kalsın,
            // pencere cevap veriyor ama sekme yoksa çubuk gerçekten kapanmıştır
            if wid != lastWindow { hide(); return }
            // Aynı pencere: araç çubuğu okunabiliyor ama sekme grubu yoksa çubuk gerçekten kapandı
            let kids: [AXUIElement] = AX.attr(win, kAXChildrenAttribute) ?? []
            let hasToolbar = kids.contains { (AX.attr($0, kAXRoleAttribute) as String?) == kAXToolbarRole as String }
            if hasToolbar { hide() }
            return
        }
        let kids: [AXUIElement] = AX.attr(group, kAXChildrenAttribute) ?? []
        var tabs: [FinderTab] = []
        var els: [AXUIElement] = []
        newTabButton = nil
        for k in kids {
            let role: String = AX.attr(k, kAXRoleAttribute) ?? ""
            if role == kAXRadioButtonRole as String {
                let title: String = AX.attr(k, kAXTitleAttribute) ?? ""
                let value: Int = AX.attr(k, kAXValueAttribute) ?? 0
                tabs.append(FinderTab(id: els.count, title: title, selected: value == 1))
                els.append(k)
            } else if role == kAXButtonRole as String {
                newTabButton = k
            }
        }
        guard !tabs.isEmpty else { return }
        tabElements = els
        if model.tabs != tabs { model.tabs = tabs }
        // Aynı pencerede sekme çubuğu şimdi belirdiyse yerine oturarak gelsin; başka her durumda anında
        let appeared = wid == lastWindow && !lastHadTabs && finderFront
        lastWindow = wid
        lastHadTabs = true
        place(frame, window: wid, animate: appeared)
    }

    private func hide() {
        lastHadTabs = false
        panel?.orderOut(nil)
    }

    // MARK: Renk

    private var sampledFor: String?

    /// Finder'ın sekme çubuğunun gerçek rengini ölç: seçili olmayan bir sekmenin boş köşesinden bir piksel.
    /// Pencere ve görünüm (açık/koyu) değişmedikçe bir kez yapılır; Ekran Kaydı izni yoksa hiç denenmez.
    private func sampleBarColor(window: AXUIElement, tabs: [AXUIElement], selected: [Bool]) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(),
              let wid = axWindowID(window) else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(wid)-\(dark)"
        guard sampledFor != key else { return }
        sampledFor = key
        let idx = selected.firstIndex(of: false) ?? 0
        guard let tabRect = Self.axRect(tabs[idx]), let winRect = Self.axRect(window) else { sampledFor = nil; return }
        // Pencereye göre nokta (sol üst başlangıçlı): seçili olmayan sekmenin sağ tarafındaki boşluk, dikeyde ortası
        // (kenar çizgileri ve yazıdan uzak)
        let pt = CGPoint(x: tabRect.maxX - winRect.minX - 12, y: tabRect.midY - winRect.minY)
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let w = content.windows.first(where: { $0.windowID == wid }) else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width)
            cfg.height = Int(w.frame.height)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                         configuration: cfg) else { return }
            let sx = CGFloat(img.width) / w.frame.width, sy = CGFloat(img.height) / w.frame.height
            let rep = NSBitmapImageRep(cgImage: img)
            // 5×5'lik küçük alanın ortalaması: tek piksel yanıltmasın
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
            for dx in -2...2 { for dy in -2...2 {
                let px = Int(pt.x * sx) + dx, py = Int(pt.y * sy) + dy
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                      let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            } }
            guard n > 0 else { await MainActor.run { self?.sampledFor = nil }; return }
            let color = NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
            await MainActor.run { self?.model.barColor = color }
        }
    }

    private static func axRect(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = AX.attr(el, kAXPositionAttribute), let sv: AXValue = AX.attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Pencerenin sekme grubu (araç çubuğunun altındaki AXTabGroup)
    private static func tabGroup(in el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) ?? []
        if let g = kids.first(where: { (AX.attr($0, kAXRoleAttribute) as String?) == kAXTabGroupRole as String }) { return g }
        guard depth < 2 else { return nil }
        // Bazı sürümlerde bir grup / bölme görünümünün içinde: sadece kapsayıcılara in (liste ve tablolara değil)
        for k in kids {
            let role: String = AX.attr(k, kAXRoleAttribute) ?? ""
            guard role == kAXGroupRole as String || role == kAXSplitGroupRole as String else { continue }
            if let g = tabGroup(in: k, depth: depth + 1) { return g }
        }
        return nil
    }

    /// AX çerçevesi (sol üst başlangıçlı) → ekran koordinatı (sol alt başlangıçlı)
    private static func frame(of el: AXUIElement) -> NSRect? {
        guard let pv: AXValue = AX.attr(el, kAXPositionAttribute), let sv: AXValue = AX.attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s), s.width > 40, s.height > 10 else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: p.x, y: top - p.y - s.height, width: s.width, height: s.height)
    }

    private func place(_ frame: NSRect, window wid: CGWindowID, animate: Bool) {
        let p = panel ?? make()
        panel = p
        if p.frame != frame { p.setFrame(frame, display: true) }
        if finderFront {
            p.level = .floating
            if !p.isVisible { p.orderFrontRegardless() }
        } else {
            // Finder arkada: şerit Finder penceresinin hemen üstünde kalsın; öndeki uygulamanın pencereleri onu örter
            p.level = .normal
            if wid != 0 { p.order(.above, relativeTo: Int(wid)) } else { p.orderOut(nil) }
        }
        if animate {
            // Sekme çubuğu yeni açıldı: Finder'ınki gibi yerine oturur
            model.shown = false
            DispatchQueue.main.async { [weak self] in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { self?.model.shown = true }
            }
        } else if !model.shown {
            model.shown = true
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        p.contentView = TabsHostingView(rootView: FinderTabsView(model: model))
        return p
    }

    // MARK: Eylemler (Finder'ın kendi sekmelerine iletilir)

    private func press(_ i: Int) {
        guard tabElements.indices.contains(i) else { return }
        AXUIElementPerformAction(tabElements[i], kAXPressAction as CFString)
        scheduleRefresh()
    }

    /// Finder sekmenin kapatma düğmesini sadece fare üstündeyken oluşturur; ona güvenmeden:
    /// sekmeyi seç, seçildiğinde ⌘W'yi doğrudan Finder'a gönder. Her seferinde aynı sonuç.
    private func closeTab(_ i: Int) {
        guard tabElements.indices.contains(i) else { return }
        let el = tabElements[i]
        let wasSelected = (AX.attr(el, kAXValueAttribute) as Int?) == 1
        if !wasSelected { AXUIElementPerformAction(el, kAXPressAction as CFString) }
        let pid = observedPid
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasSelected ? 0 : 0.12)) { [weak self] in
            MainActor.assumeIsolated {
                Self.sendKey(13, .maskCommand, to: pid)   // ⌘W
                self?.scheduleRefresh()
            }
        }
    }

    private func newTab() {
        if let b = newTabButton { AXUIElementPerformAction(b, kAXPressAction as CFString) } else { Self.sendKey(17, .maskCommand, to: observedPid) }   // ⌘T
        scheduleRefresh()
    }

    private static func sendKey(_ code: CGKeyCode, _ flags: CGEventFlags, to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            if pid != 0 { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
        }
    }
}

// MARK: - Görünüm

struct FinderTabsView: View {
    @ObservedObject var model: FinderTabsModel
    @Environment(\.colorScheme) private var scheme

    static let maxW: CGFloat = 220
    static let minW: CGFloat = 120
    static let plusW: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let avail = geo.size.width - Self.plusW - 12
            let n = CGFloat(max(1, model.tabs.count))
            let w = min(Self.maxW, max(Self.minW, (avail - (n - 1) * 2) / n))
            ZStack(alignment: .leading) {
                barBackground
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(model.tabs) { t in
                                    TabChip(tab: t, width: w, model: model).id(t.id)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                        .onAppear { scrollToSelected(proxy) }
                        .onChange(of: model.tabs) { _ in scrollToSelected(proxy) }
                    }
                    .frame(maxWidth: min(avail + 12, n * (w + 2) + 12), alignment: .leading)
                    Button(action: model.onNew) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Yeni sekme"))
                    Spacer(minLength: 0)
                }
            }
            .offset(y: model.shown ? 0 : -geo.size.height * 0.6)
            .opacity(model.shown ? 1 : 0)
        }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        if let s = model.tabs.first(where: \.selected) { proxy.scrollTo(s.id) }
    }

    /// Finder'ın kendi çubuğuyla aynı malzeme (başlık çubuğu camı): açık / koyu görünümde ve
    /// pencere önde / arkadayken tonu Finder'ınkiyle birlikte değişir
    private var barBackground: some View {
        TitlebarMaterial()
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            }
    }
}

private struct TabChip: View {
    let tab: FinderTab
    let width: CGFloat
    @ObservedObject var model: FinderTabsModel
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let selectedFill = scheme == .dark ? Color(white: 0.24) : Color(white: 0.98)
        let showClose = hover || tab.selected
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 15, height: 15)
            Text(tab.title)
                .font(.system(size: 12, weight: tab.selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tab.selected ? Color.primary : Color.secondary)
        .padding(.leading, 10)
        .padding(.trailing, showClose ? 26 : 10)   // kapatma düğmesi sadece görününce yer kaplar
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if showClose {
                Button { model.onClose(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .help(L("Sekmeyi kapat"))
            }
        }
        .background(
            UnevenTop(radius: 7)
                .fill(tab.selected ? selectedFill : Color.primary.opacity(hover ? 0.06 : 0))
                .padding(.top, 3)
        )
        .overlay(alignment: .trailing) {
            // Windows'taki gibi seçili olmayan sekmeler arasında ince ayırıcı
            if !tab.selected && !hover {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14).offset(x: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if tab.selected { Rectangle().fill(Brand.red).frame(height: 2).padding(.horizontal, 8) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.onSelect(tab.id) }
        .onHover { hover = $0 }
        .help(tab.title)
    }
}

/// Sadece üst köşeleri yuvarlak sekme şekli
private struct UnevenTop: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}


/// macOS'un başlık çubuğu malzemesi (Finder'ın araç ve sekme çubuğu bununla çizilir)
private struct TitlebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .titlebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
