import Cocoa
import SwiftUI

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

    @objc private func appChanged() {
        guard running else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Self.finderID, let pid = front?.processIdentifier {
            attach(pid)
            refresh()
        } else if front?.processIdentifier != getpid() {
            panel?.orderOut(nil)
        }
    }

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

    private func refresh() {
        guard running, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID, observedPid != 0 else {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() { panel?.orderOut(nil) }
            return
        }
        let app = AXUIElementCreateApplication(observedPid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let win: AXUIElement = AX.attr(app, kAXFocusedWindowAttribute),
              (AX.attr(win, kAXMinimizedAttribute) as Bool?) != true,
              let group = Self.tabGroup(in: win),
              let frame = Self.frame(of: group) else {
            panel?.orderOut(nil)
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
        guard !tabs.isEmpty else { panel?.orderOut(nil); return }
        tabElements = els
        if model.tabs != tabs { model.tabs = tabs }
        place(frame)
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

    private func place(_ frame: NSRect) {
        let p = panel ?? make()
        panel = p
        if p.frame != frame { p.setFrame(frame, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
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
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle, .transient]
        p.contentView = TabsHostingView(rootView: FinderTabsView(model: model))
        return p
    }

    // MARK: Eylemler (Finder'ın kendi sekmelerine iletilir)

    private func press(_ i: Int) {
        guard tabElements.indices.contains(i) else { return }
        AXUIElementPerformAction(tabElements[i], kAXPressAction as CFString)
        scheduleRefresh()
    }

    private func closeTab(_ i: Int) {
        guard tabElements.indices.contains(i) else { return }
        let kids: [AXUIElement] = AX.attr(tabElements[i], kAXChildrenAttribute) ?? []
        if let close = kids.first(where: { (AX.attr($0, kAXRoleAttribute) as String?) == kAXButtonRole as String }) {
            AXUIElementPerformAction(close, kAXPressAction as CFString)
        } else {
            // Kapatma düğmesi bulunamazsa: sekmeyi seç, ⌘W gönder
            AXUIElementPerformAction(tabElements[i], kAXPressAction as CFString)
            Self.sendKey(13, .maskCommand)
        }
        scheduleRefresh()
    }

    private func newTab() {
        if let b = newTabButton { AXUIElementPerformAction(b, kAXPressAction as CFString) } else { Self.sendKey(17, .maskCommand) }   // ⌘T
        scheduleRefresh()
    }

    private static func sendKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
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
        }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        if let s = model.tabs.first(where: \.selected) { proxy.scrollTo(s.id) }
    }

    /// Finder'ın sekme çubuğuyla aynı ton (açık / koyu görünüm)
    private var barBackground: some View {
        Rectangle()
            .fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.86))
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
