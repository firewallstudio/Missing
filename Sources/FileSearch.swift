import UniformTypeIdentifiers
import Cocoa
import Quartz

// MARK: - ⌘Space dosya arama
//
// Everything tarzı: sadece dosya ADINA bakar, yazdıkça anında süzer (FileIndex).
// Finder öndeyken açılırsa Finder'daki klasörün içinde arar; boş arama o klasörün içeriğini gösterir,
// klasörlere Enter ile girilir, ⌘↑ ile üst klasöre çıkılır (küçük bir Finder penceresi gibi).

enum FileSearchSettings {
    private static var d: UserDefaults { .standard }

    /// ⌘Space ile dosya arama (açıkken macOS'un Spotlight kısayolu kapanır)
    static var enabled: Bool {
        get { d.object(forKey: "fileSearch.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "fileSearch.enabled") }
    }
}

// MARK: - Seçimleri hatırla (aynı aramada aynı dosya üste çıksın)

@MainActor enum SearchMemory {
    private static let picksKey = "fileSearch.picks"
    private static let recentsKey = "fileSearch.recents"

    /// katlanmış arama → [yol: kaç kez]
    private static var picks: [String: [String: Int]] {
        get { UserDefaults.standard.dictionary(forKey: picksKey) as? [String: [String: Int]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: picksKey) }
    }

    static var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(30)), forKey: recentsKey) }
    }

    static func record(query: String, path: String) {
        var r = recents
        r.removeAll { $0 == path }
        r.insert(path, at: 0)
        recents = r
        let q = FileIndex.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return }
        var all = picks
        var entry = all[q] ?? [:]
        entry[path, default: 0] += 1
        all[q] = entry
        if all.count > 400 {
            // En az kullanılanları at
            let sorted = all.sorted { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }
            for (k, _) in sorted.prefix(all.count - 300) { all[k] = nil }
        }
        picks = all
    }

    /// Bu aramaya uyan önceki seçimler → ek puan
    static func boosts(for query: String) -> [String: Int32] {
        let q = FileIndex.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [:] }
        var out: [String: Int32] = [:]
        for (k, v) in picks {
            let exact = k == q
            guard exact || k.hasPrefix(q) || q.hasPrefix(k) else { continue }
            for (path, n) in v {
                let base: Int32 = exact ? 500 : 260
                let extra: Int32 = Int32(min(n, 5)) * 40
                out[path] = max(out[path] ?? 0, base + extra)
            }
        }
        for (i, p) in recents.prefix(10).enumerated() {
            let b: Int32 = Int32(60 - i * 5)
            out[p] = (out[p] ?? 0) + b
        }
        return out
    }
}

// MARK: - Finder'da açık klasör

@MainActor enum FinderLocation {
    /// Finder öndeyse öndeki penceresinin klasörü (pencere yoksa masaüstü)
    static func current() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.finder" else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        if let w: AXUIElement = AX.attr(ax, kAXFocusedWindowAttribute) {
            if let doc: String = AX.attr(w, kAXDocumentAttribute), let u = URL(string: doc), u.isFileURL {
                return clean(u.path)
            }
            if let u: URL = AX.attr(w, kAXDocumentAttribute), u.isFileURL { return clean(u.path) }
        }
        // Yedek: Finder'a sor (ilk seferde macOS "Finder'ı denetleme" izni ister)
        let src = "tell application \"Finder\" to return POSIX path of (insertion location as alias)"
        var err: NSDictionary?
        if let s = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue, !s.isEmpty {
            return clean(s)
        }
        return nil
    }

    /// Öndeki Finder penceresinin çerçevesi (ekran koordinatı)
    static func windowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.finder" else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let w: AXUIElement = AX.attr(ax, kAXFocusedWindowAttribute),
              let pv: AXValue = AX.attr(w, kAXPositionAttribute), let sv: AXValue = AX.attr(w, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: p.x, y: top - p.y - s.height, width: s.width, height: s.height)
    }

    private static func clean(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Panel

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    weak var quickLook: FileSearchController?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLook
        panel.delegate = quickLook
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        // Hızlı Bakış kapanınca arama açık kalsın ve yazmaya devam edilebilsin
        if isVisible {
            makeKeyAndOrderFront(nil)
            if let c = quickLook { MainActor.assumeIsolated { c.refocus() } }
        }
    }
}

/// Arama sürümü: yeni harf gelince eski arama erken bırakılır
private final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == v }
}

@MainActor final class FileSearchController: NSObject {
    private let panel: SearchPanel
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let table = HoverTableView()
    /// Sağdaki önizleme bölmesi
    private let previewPane = SearchPreviewPane()
    /// Arama yerini gösteren jeton (büyütecin yanında)
    private let scopeToken = ScopeTokenView()
    /// Alttaki kısayol çubuğu
    private let hints = NSTextField(labelWithString: "")
    /// Oklarla / fareyle sonuçlarda gezinildi: Space Hızlı Bakış açar (yazarken boşluk yazar)
    private var navigating = false
    private var currentQuery = ""
    private var divider: NSView!
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")

    private var results: [FileResult] = []
    /// Arama kapsamı (nil = bu Mac)
    private var scope: String?
    /// Tab ile geri dönülecek klasör
    private var lastFolder: String?
    private let gen = Generation()
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var dragging = false
    private var indexState: FileIndexState = .idle
    private var openedSomething = false

    // Spotlight ölçüleri: hap biçimli arama çubuğu, sonuçlar yazınca altında açılır
    private static let width: CGFloat = 840
    private static let listW: CGFloat = 450
    private static let footerH: CGFloat = 30
    private static let minListH: CGFloat = 320
    private static let barH: CGFloat = 56
    private static let height: CGFloat = 470
    private static let rowH: CGFloat = 40
    private static let headerH: CGFloat = 26
    private static let listGap: CGFloat = 8
    private static let listPad: CGFloat = 6
    private static let maxListH: CGFloat = 460
    private var listGlass: NSView!
    /// Tablodaki satırlar: bölüm başlığı ya da sonuç (results sırası)
    private enum DisplayRow { case header(String), item(Int) }
    private var rows: [DisplayRow] = []
    /// results sırası → tablo satırı
    private var tableRow: [Int] = []
    /// Panelin üst kenarı (yeniden boyutlanırken yerinde kalır)
    private var topY: CGFloat = 0
    /// Klasörde gezinildi mi (boş aramada klasör içeriği gösterilir); Finder'dan ilk açılışta sadece çubuk
    private var browsing = false

    override init() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.quickLook = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        build()

        FileIndex.shared.onState = { [weak self] s in self?.indexChanged(s) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Görünüm

    /// Spotlight camı: bulanık arka plan, hafif koyu ton, ince parlak kenar
    private static func glassView(radius: CGFloat) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 0.75
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.autoresizingMask = [.width, .height]
        v.addSubview(tint)
        return v
    }

    private func build() {
        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        panel.acceptsMouseMovedEvents = true

        // Arama çubuğu: tek başına duran hap — büyüteç · klasör jetonu · yazı · durum
        let bar = Self.glassView(radius: Self.barH / 2)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glass.contentTintColor = .white.withAlphaComponent(0.6)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        scopeToken.onClick = { [weak self] in self?.toggleScope() }

        status.font = .systemFont(ofSize: 12)
        status.textColor = .white.withAlphaComponent(0.45)
        status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [glass, scopeToken, field, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.setCustomSpacing(12, after: glass)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        // Sonuçlar: çubuğun altında ayrı cam kart — solda liste, sağda önizleme, altta kısayollar
        let list = Self.glassView(radius: 22)
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list)
        listGlass = list

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowH
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateSelected)
        table.refusesFirstResponder = true
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.menu = makeMenu()
        table.onHoverRow = { [weak self] row in self?.hoverRow(row) }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.listPad, left: 0, bottom: Self.listPad, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(scroll)

        let divider = NSView()
        self.divider = divider
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(divider)

        previewPane.translatesAutoresizingMaskIntoConstraints = false
        previewPane.onOpen = { [weak self] in if let r = self?.selected { self?.open(r) } }
        previewPane.onReveal = { [weak self] in if let r = self?.selected { self?.reveal(r) } }
        previewPane.onTrash = { [weak self] in if let r = self?.selected { self?.trash(r) } }
        list.addSubview(previewPane)

        let footerLine = NSView()
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        footerLine.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(footerLine)

        hints.font = .systemFont(ofSize: 11, weight: .medium)
        hints.textColor = .white.withAlphaComponent(0.5)
        hints.lineBreakMode = .byTruncatingTail
        hints.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(hints)

        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .white.withAlphaComponent(0.45)
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(empty)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barH),

            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scopeToken.heightAnchor.constraint(equalToConstant: 30),
            scopeToken.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Self.listGap),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 6),
            scroll.widthAnchor.constraint(equalToConstant: Self.listW - 12),
            scroll.topAnchor.constraint(equalTo: list.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor),

            divider.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: Self.listW),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: list.topAnchor, constant: 12),
            divider.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -12),

            previewPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            previewPane.topAnchor.constraint(equalTo: list.topAnchor),
            previewPane.bottomAnchor.constraint(equalTo: footerLine.topAnchor),

            footerLine.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            footerLine.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -Self.footerH),

            hints.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 16),
            hints.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor, constant: -16),
            hints.centerYAnchor.constraint(equalTo: list.bottomAnchor, constant: -Self.footerH / 2),

            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: -Self.footerH / 2),
        ])
        updateHints()
    }

    /// Alttaki kısayol çubuğu: tuşlar beyaz, açıklamaları soluk
    private func updateHints() {
        let items: [(String, String)] = [("↩", L("Aç")), ("⌘↩", L("Finder'da göster")), ("Space", L("Hızlı Bakış")),
                                         ("⌘⌫", L("Çöp Sepetine taşı")), ("Tab", scope == nil ? L("Bu klasör") : L("Tüm Mac"))]
        let s = NSMutableAttributedString()
        for (i, it) in items.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "    ")) }
            s.append(NSAttributedString(string: it.0 + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]))
            s.append(NSAttributedString(string: it.1, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
        }
        hints.attributedStringValue = s
    }

    /// Fare bir satırın üstüne gelince o satır seçilir ve önizlenir
    private func hoverRow(_ row: Int) {
        guard let i = resultIndex(row: row), i != selectedIndex else { return }
        navigating = true
        let keep = scroll.contentView.bounds.origin
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scroll.contentView.scroll(to: keep)
        updatePreview()
    }

    private var previewWork: DispatchWorkItem?

    /// Seçili sonucu sağ bölmede göster (hızlı gezinirken her satırda yeniden yüklemesin)
    private func updatePreview() {
        previewWork?.cancel()
        guard let r = selected else { previewPane.show(nil); return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.previewPane.show(r) }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }

    #if SNAPSHOT
    /// Sadece ekran görüntüsü derlemesinde: örnek sonuçlarla paneli hazırla
    func snapshot(_ r: [FileResult], query: String, scopeName: String?) -> NSWindow {
        scope = scopeName
        field.stringValue = query
        updateScopeButton()
        topY = 800
        panel.setFrame(NSRect(x: 0, y: 800 - Self.barH, width: Self.width, height: Self.barH), display: false)
        show(r, query: query)
        return panel
    }
    #endif

    // MARK: Aç / kapat

    func toggle() {
        if panel.isVisible { close(restore: true) } else { show() }
    }

    func show() {
        let finder = FinderLocation.current()
        scope = finder
        if let finder { lastFolder = finder }
        field.stringValue = ""
        openedSomething = false
        browsing = false
        updateScopeButton()

        if let screen = screenUnderMouse() {
            let f = screen.visibleFrame
            var x = (f.midX - Self.width / 2).rounded()
            topY = (f.maxY - f.height * 0.24).rounded()
            // Finder penceresinin üst ortasında, araç çubuğunun hemen altında (Finder'ın kendi araması gibi)
            if let w = FinderLocation.windowFrame(), w.width > 300, f.intersects(w) {
                x = min(max(w.midX - Self.width / 2, f.minX + 8), f.maxX - Self.width - 8).rounded()
                topY = min(w.maxY - 64, f.maxY - 8).rounded()
            }
            panel.setFrame(NSRect(x: x, y: topY - Self.barH, width: Self.width, height: Self.barH), display: false)
        }
        PanelFocus.grab(panel)
        panel.makeFirstResponder(field)
        installMonitors()
        refresh()
    }

    func close(restore: Bool) {
        guard panel.isVisible else { return }
        removeMonitors()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        _ = gen.next()   // bekleyen aramaları geçersiz kıl
        PanelFocus.release(restore: restore && !openedSomething)
        FileIndex.shared.saveIfDirty()
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow || (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow) else { return e }
            return self.handleKey(e) ? nil : e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Hızlı Bakış açılırken odak bir an boşta kalır: hemen kapanma, biraz sonra bak
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    guard let self, !self.dragging, self.panel.isVisible, !self.panel.isKeyWindow else { return }
                    if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
                    self.close(restore: false)
                }
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
    }

    // MARK: Kapsam

    private func updateScopeButton() {
        // Klasörde arıyorsa büyütecin yanında klasör jetonu; tüm Mac'te ararken jeton yok
        if let sc = scope {
            scopeToken.isHidden = false
            scopeToken.set(path: sc)
            field.placeholderString = L("Bu klasörde ara")
        } else {
            scopeToken.isHidden = true
            field.placeholderString = L("Tüm Mac'te ara")
        }
        updateHints()
    }

    @objc private func toggleScope() {
        if scope != nil { scope = nil }
        else { scope = lastFolder ?? FileIndex.home }
        updateScopeButton()
        refresh()
        panel.makeFirstResponder(field)
    }

    private func enter(folder: String) {
        scope = folder
        browsing = true
        lastFolder = folder
        field.stringValue = ""
        updateScopeButton()
        refresh()
    }

    private func goUp() {
        let cur = scope ?? lastFolder ?? FileIndex.home
        let up = (cur as NSString).deletingLastPathComponent
        guard !up.isEmpty, up != cur else { NSSound.beep(); return }
        let from = cur
        enter(folder: up)
        // Çıkılan klasörü seçili getir
        if let i = results.firstIndex(where: { $0.path == from }) { select(i) }
    }

    // MARK: Arama

    private func refresh() {
        let text = field.stringValue
        let g = gen.next()
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            if !browsing {
                show([], query: "")   // Spotlight gibi: boşken sadece arama çubuğu
                return
            }
            if let s = scope {
                show(Self.listFolder(s), query: "")
            } else {
                let rec = SearchMemory.recents.filter { FileManager.default.fileExists(atPath: $0) }
                show(rec.prefix(12).map { Self.result(for: $0) }, query: "")
            }
            return
        }

        var q = FileIndex.Query(tokens: [])
        var tokens: [[UInt8]] = []
        let words = trimmed.split(whereSeparator: { $0 == " " }).map(String.init)
        for w in words {
            if w == "/" { q.dirsOnly = true; continue }
            if w.hasPrefix("."), w.count > 1, w.count <= 8, !w.dropFirst().contains(".") {
                q.ext = FileIndex.fold(String(w.dropFirst()))
                continue
            }
            if words.count > 1, Self.knownExts.contains(w.lowercased()), q.ext == nil {
                q.ext = w.lowercased()
                continue
            }
            tokens.append(Array(FileIndex.fold(w).utf8))
        }
        // Sadece uzantı yazıldıysa ("pdf") uzantıyı ad gibi ara
        if tokens.isEmpty, let e = q.ext, !q.dirsOnly {
            tokens = [Array(("." + e).utf8)]
            q.ext = nil
        }
        if tokens.isEmpty && q.dirsOnly {
            if let s = scope { show(Self.listFolder(s).filter(\.isDir), query: "") } else { show([], query: trimmed) }
            return
        }
        q.tokens = tokens
        q.scope = scope
        q.boosts = SearchMemory.boosts(for: trimmed)
        let gen = self.gen
        FileIndex.shared.queue.async {
            guard gen.isCurrent(g) else { return }
            let r = FileIndex.shared.search(q, isStale: { !gen.isCurrent(g) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen.isCurrent(g) else { return }
                    self.show(r, query: trimmed)
                }
            }
        }
        if case .scanning = indexState { updateStatus(searching: true) }
    }

    static let knownExts: Set<String> = FileIndex.docExts.union(["swift", "py", "js", "ts", "html", "css", "json", "app", "dmg", "pkg"])

    private func show(_ r0: [FileResult], query: String) {
        let prevPath = selected?.path
        currentQuery = query
        // Az önce silinen / taşınan dosyalar indeks güncellenene kadar görünmesin
        #if SNAPSHOT
        let r = r0
        #else
        let r = r0.filter { FileManager.default.fileExists(atPath: $0.path) }
        #endif
        // Spotlight gibi: aramada En İyi Sonuç + türe göre bölümler; klasörde gezinirken düz liste
        let sections = query.isEmpty ? [("", r)] : Self.sections(r)
        results = []
        rows = []
        for (title, items) in sections where !items.isEmpty {
            if !title.isEmpty { rows.append(.header(title)) }
            for it in items {
                rows.append(.item(results.count))
                results.append(it)
            }
        }
        tableRow = Array(repeating: 0, count: results.count)
        for (k, row) in rows.enumerated() { if case .item(let i) = row { tableRow[i] = k } }
        table.reloadData()
        if !results.isEmpty {
            let keep = query.isEmpty ? prevPath.flatMap { p in results.firstIndex { $0.path == p } } : nil
            select(keep ?? 0)
        }
        if results.isEmpty {
            if !query.isEmpty, case .scanning = indexState { empty.stringValue = L("Dosyalar taranıyor…") }
            else if !query.isEmpty { empty.stringValue = L("Sonuç yok") }
            else if scope != nil && browsing { empty.stringValue = L("Klasör boş") }
            else { empty.stringValue = "" }
        } else {
            empty.stringValue = ""
        }
        updateStatus(searching: false)
        divider.isHidden = results.isEmpty
        previewPane.isHidden = results.isEmpty
        resize(message: !empty.stringValue.isEmpty)
        updatePreview()
    }

    /// Sonuç türleri (Spotlight'taki bölümler)
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "svg", "psd", "raw", "dng", "cr2", "nef", "arw", "bmp", "ico", "icns"]
    private static let movieExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mxf", "braw", "r3d", "prores"]
    private static let musicExts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "caf", "logicx"]

    private static func kind(_ r: FileResult) -> String {
        let ext = (r.name as NSString).pathExtension.lowercased()
        if ext == "app" { return L("Uygulamalar") }
        if r.isDir { return L("Klasörler") }
        if imageExts.contains(ext) { return L("Görüntüler") }
        if movieExts.contains(ext) { return L("Filmler") }
        if musicExts.contains(ext) { return L("Müzik") }
        if FileIndex.docExts.contains(ext) { return L("Belgeler") }
        return L("Diğer")
    }

    /// İlk sonuç En İyi Sonuç; kalanlar türlerine göre, bölümler en alakalı üyesinin sırasına göre
    private static func sections(_ r: [FileResult]) -> [(String, [FileResult])] {
        guard let top = r.first else { return [] }
        var order: [String] = []
        var groups: [String: [FileResult]] = [:]
        for it in r.dropFirst() {
            let k = kind(it)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(it)
        }
        return [(L("En İyi Sonuç"), [top])] + order.map { ($0, groups[$0] ?? []) }
    }

    /// Sonuçlara göre paneli büyüt/küçült; üst kenar yerinde kalır. Boşken sadece arama çubuğu.
    private func resize(message: Bool) {
        var listH: CGFloat = 0
        for row in rows {
            if case .header = row { listH += Self.headerH } else { listH += Self.rowH }
        }
        if listH > 0 { listH = min(max(listH + Self.listPad * 2, Self.minListH), Self.maxListH) + Self.footerH }
        else if message { listH = 64 + Self.footerH }
        listGlass.isHidden = listH == 0
        let h = Self.barH + (listH > 0 ? Self.listGap + listH : 0)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        if topY == 0 { topY = f.maxY }
        f.origin.y = topY - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: false)
    }

    private func updateStatus(searching: Bool) {
        switch indexState {
        case .scanning(let n):
            status.stringValue = L("Taranıyor · %@", Self.formatCount(n))
        default:
            status.stringValue = ""
        }
    }

    private func indexChanged(_ s: FileIndexState) {
        let wasScanning: Bool
        if case .scanning = indexState { wasScanning = true } else { wasScanning = false }
        indexState = s
        guard panel.isVisible else { return }
        updateStatus(searching: false)
        if wasScanning, case .ready = s { refresh() }
    }

    static func formatCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = AppLanguage.active == .tr ? Locale(identifier: "tr_TR") : Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Klasörün içeriği (Finder gibi: önce klasörler, sonra ada göre)
    static func listFolder(_ path: String) -> [FileResult] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return [] }
        var out: [FileResult] = []
        out.reserveCapacity(items.count)
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            out.append(FileResult(path: u.path, name: u.lastPathComponent, isDir: dir,
                                  mtime: v?.contentModificationDate ?? .distantPast, match: nil))
        }
        out.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return out
    }

    static func result(for path: String) -> FileResult {
        let u = URL(fileURLWithPath: path)
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
        let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        return FileResult(path: path, name: u.lastPathComponent, isDir: dir, mtime: v?.contentModificationDate ?? .distantPast, match: nil)
    }

    // MARK: Seçim ve eylemler

    /// Tablo satırındaki sonuç (başlıksa nil)
    private func resultIndex(row: Int) -> Int? {
        guard rows.indices.contains(row), case .item(let i) = rows[row] else { return nil }
        return i
    }

    private var selectedIndex: Int? { resultIndex(row: table.selectedRow) }

    private var selected: FileResult? { selectedIndex.map { results[$0] } }

    private func select(_ i: Int) {
        guard !results.isEmpty else { return }
        let n = max(0, min(i, results.count - 1))
        let row = tableRow[n]
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Bölümün ilk satırıysa başlığı da göster
        table.scrollRowToVisible(row > 0 && resultIndex(row: row - 1) == nil ? row - 1 : row)
        table.scrollRowToVisible(row)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        updatePreview()
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        navigating = true
        select((selectedIndex ?? 0) + d)
    }

    /// Enter / çift tık: klasöre gir, dosyayı aç
    @objc private func activateSelected() {
        guard let r = selected else { return }
        if r.isDir { remember(r); enter(folder: r.path); return }
        open(r)
    }

    private func remember(_ r: FileResult) {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        SearchMemory.record(query: q, path: r.path)
    }

    private func open(_ r: FileResult) {
        remember(r)
        openedSomething = true
        close(restore: false)
        NSWorkspace.shared.open(URL(fileURLWithPath: r.path))
    }

    private func reveal(_ r: FileResult) {
        remember(r)
        openedSomething = true
        close(restore: false)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)])
    }

    private func copyFile(_ r: FileResult) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: r.path) as NSURL])
    }

    private func copyPath(_ r: FileResult) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r.path, forType: .string)
    }

    /// Çöp Sepetine taşı ve satırı anında listeden kaldır (seçim bir sonrakine geçer)
    private func trash(_ r: FileResult) {
        let keepIndex = selectedIndex ?? 0
        NSWorkspace.shared.recycle([URL(fileURLWithPath: r.path)]) { [weak self] _, err in
            guard err == nil else { NSSound.beep(); return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let snd = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
                NSSound(contentsOfFile: snd, byReference: true)?.play()
                let rest = self.results.filter { $0.path != r.path }
                let q = self.currentQuery
                self.show(rest, query: q)
                if !self.results.isEmpty { self.select(min(keepIndex, self.results.count - 1)) }
            }
        }
    }

    private func quickLook() {
        guard selected != nil else { return }
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible {
            ql.orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
            refocus()
        } else {
            ql.makeKeyAndOrderFront(nil)
        }
    }

    /// Arama kutusuna geri dön (Hızlı Bakış sonrası)
    func refocus() {
        guard panel.isVisible else { return }
        panel.makeFirstResponder(field)
        if let ed = panel.fieldEditor(false, for: field) as? NSTextView {
            ed.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0))
        }
    }

    /// true → tuş işlendi
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let opt = mods.contains(.option)
        let editor = panel.fieldEditor(false, for: field) as? NSTextView
        let hasTextSelection = (editor?.selectedRange().length ?? 0) > 0
        let fieldEmpty = field.stringValue.isEmpty

        switch e.keyCode {
        case 125:   // ↓
            if cmd { activateSelected() } else { move(1) }
            return true
        case 126:   // ↑
            if cmd { goUp() } else { move(-1) }
            return true
        case 121: move(8); return true      // page down
        case 116: move(-8); return true     // page up
        case 36, 76:   // return
            if cmd, let r = selected { reveal(r) } else { activateSelected() }
            return true
        case 48:   // tab
            toggleScope()
            return true
        case 53:   // esc
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().orderOut(nil)
            } else if !fieldEmpty {
                field.stringValue = ""
                refresh()
            } else {
                close(restore: true)
            }
            return true
        case 51 where cmd:   // ⌘⌫ seçili dosyayı çöpe (Finder'daki gibi)
            if let r = selected { trash(r) }
            return true
        case 49 where !cmd && !opt && (navigating || fieldEmpty) && selected != nil:   // Space: Hızlı Bakış
            quickLook()
            return true
        default:
            break
        }
        guard cmd else { return false }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch ch {
        case "y":
            quickLook(); return true
        case "o":
            if let r = selected { open(r) }
            return true
        case "r":
            if let r = selected { reveal(r) }
            return true
        case "c" where opt:
            if let r = selected { copyPath(r) }
            return true
        case "c" where !hasTextSelection:
            if let r = selected { copyFile(r) }
            return true
        // Menü çubuğu olmadığı için düzenleme kısayolları elle
        case "c": editor?.copy(nil); return true
        case "v": editor?.paste(nil); return true
        case "x": editor?.cut(nil); return true
        case "a": editor?.selectAll(nil); return true
        case "z":
            if mods.contains(.shift) { editor?.undoManager?.redo() } else { editor?.undoManager?.undo() }
            return true
        case "w":
            close(restore: true); return true
        default:
            return false
        }
    }
}

// MARK: - Metin kutusu

extension FileSearchController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        navigating = false   // yazmaya dönünce Space yine boşluk yazar
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelected(); return true
        case #selector(NSResponder.insertTab(_:)): toggleScope(); return true
        case #selector(NSResponder.cancelOperation(_:)): return true
        default: return false
        }
    }
}

// MARK: - Liste

extension FileSearchController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        resultIndex(row: row) == nil ? Self.headerH : Self.rowH
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { resultIndex(row: row) != nil }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let i = resultIndex(row: row) else {
            guard case .header(let title) = rows[row] else { return nil }
            let h = NSTextField(labelWithString: title)
            h.font = .systemFont(ofSize: 11.5, weight: .semibold)
            h.textColor = .white.withAlphaComponent(0.5)
            let v = NSView()
            h.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
                h.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            ])
            return v
        }
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let r = results[i]
        let showPath = !(field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && scope != nil)
        cell.configure(r, showPath: showPath)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        updatePreview()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let i = resultIndex(row: row) else { return nil }
        return URL(fileURLWithPath: results[i].path) as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragging = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragging = false
        if operation != [] { openedSomething = true; close(restore: false) }
        else if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    }
}

// MARK: - Sağ tık menüsü

extension FileSearchController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let i = resultIndex(row: row) else { return }
        select(i)
        let r = results[i]
        func item(_ t: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ act: @escaping () -> Void) {
            let i = ClosureMenuItem(title: t, key: key, action: act)
            i.keyEquivalentModifierMask = mods
            menu.addItem(i)
        }
        item(L("Aç"), "o", .command) { [weak self] in self?.open(r) }
        if r.isDir { item(L("İçine gir"), "", []) { [weak self] in self?.enter(folder: r.path) } }
        item(L("Finder'da göster"), "r", .command) { [weak self] in self?.reveal(r) }
        item(L("Hızlı Bakış"), "y", .command) { [weak self] in self?.quickLook() }
        menu.addItem(.separator())
        item(L("Kopyala"), "c", .command) { [weak self] in self?.copyFile(r) }
        item(L("Yolu kopyala"), "c", [.command, .option]) { [weak self] in self?.copyPath(r) }
        menu.addItem(.separator())
        item(L("Çöp Sepetine taşı"), "\u{8}", .command) { [weak self] in self?.trash(r) }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, key: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - Hızlı Bakış

extension FileSearchController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selected == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard let r = selected else { return nil }
            return URL(fileURLWithPath: r.path) as NSURL
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            switch event.keyCode {
            case 125: move(1); return true
            case 126: move(-1); return true
            default: return false
            }
        }
    }
}

// MARK: - Satır görünümü

private final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        path.fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

private final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("result")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private var subHeight: NSLayoutConstraint!
    private var nameTop: NSLayoutConstraint!
    private var current: FileResult?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13.5, weight: .regular)
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.font = .systemFont(ofSize: 12)
        sub.lineBreakMode = .byTruncatingHead
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        date.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        date.alignment = .right
        date.translatesAutoresizingMaskIntoConstraints = false
        date.setContentHuggingPriority(.required, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, name, sub, date] { addSubview(v) }
        // Spotlight satırı: ikon · ad (solda) · bulunduğu klasör (sağda, soluk), tek satır
        date.isHidden = true
        sub.alignment = .right
        sub.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameTop = name.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameTop,
            sub.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sub.centerYAnchor.constraint(equalTo: centerYAnchor),
            sub.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.42),
        ])
        subHeight = name.centerYAnchor.constraint(equalTo: centerYAnchor)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let c = current { apply(c) } }
    }

    private var showPath = true

    func configure(_ r: FileResult, showPath: Bool) {
        current = r
        self.showPath = showPath
        icon.image = NSWorkspace.shared.icon(forFile: r.path)
        #if SNAPSHOT
        if !FileManager.default.fileExists(atPath: r.path) {
            let ext = (r.name as NSString).pathExtension
            if r.isDir { icon.image = NSWorkspace.shared.icon(for: .folder) }
            else if let t = UTType(filenameExtension: ext) { icon.image = NSWorkspace.shared.icon(for: t) }
        }
        #endif
        sub.isHidden = !showPath
        apply(r)
    }

    private func apply(_ r: FileResult) {
        let sel = backgroundStyle == .emphasized
        let main: NSColor = .white
        let dim: NSColor = sel ? .white.withAlphaComponent(0.78) : .white.withAlphaComponent(0.48)
        let s = NSMutableAttributedString(string: r.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .regular), .foregroundColor: main,
        ])
        if let m = r.match, m.location + m.length <= (r.name as NSString).length {
            s.addAttributes([.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)], range: m)
            if !sel { s.addAttribute(.foregroundColor, value: NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? main, range: m) }
        }
        name.attributedStringValue = s
        let parentPath = ((r.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        sub.stringValue = parentPath
        sub.textColor = dim
        date.stringValue = Self.format(r.mtime)
        date.textColor = dim
    }

    static func format(_ d: Date) -> String {
        if d == .distantPast || d.timeIntervalSinceReferenceDate <= 0 { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = AppLanguage.active == .tr ? Locale(identifier: "tr_TR") : Locale(identifier: "en_US")
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return L("Dün") }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            f.dateFormat = "EEEE"
            return f.string(from: d)
        }
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}


// MARK: - Fareyle gezinilen tablo

/// Fare bir satırın üstüne gelince haber verir (Spotlight gibi: üstüne gelinen önizlenir)
final class HoverTableView: NSTableView {
    var onHoverRow: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0 { onHoverRow?(r) }
    }
}

// MARK: - Klasör jetonu

/// Büyütecin yanında: gerçek klasör ikonu ve adı. Tıklayınca (ya da Tab) tüm Mac'e geçer.
final class ScopeTokenView: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        chevron.contentTintColor = .white.withAlphaComponent(0.5)
        let row = NSStackView(views: [icon, label, chevron])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = L("Tab: tüm Mac'te ara")
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(path: String) {
        label.stringValue = path == "/" ? "/" : FileManager.default.displayName(atPath: path)
        icon.image = NSWorkspace.shared.icon(forFile: path)
        #if SNAPSHOT
        if !FileManager.default.fileExists(atPath: path) { icon.image = NSWorkspace.shared.icon(for: .folder) }
        #endif
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Önizleme bölmesi

/// Sağ bölme: dosyanın Hızlı Bakış önizlemesi, adı, türü, boyutu, tarihi ve eylem düğmeleri
final class SearchPreviewPane: NSView {
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?

    private let ql: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
    private let bigIcon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private var buttons: NSStackView!
    private var current: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        ql.translatesAutoresizingMaskIntoConstraints = false
        ql.shouldCloseWithWindow = false
        ql.autostarts = false   // video / ses kendiliğinden oynamasın (Space ile Hızlı Bakış'ta oynar)
        ql.wantsLayer = true
        ql.layer?.cornerRadius = 10
        ql.layer?.masksToBounds = true
        addSubview(ql)

        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        bigIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bigIcon)

        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingMiddle
        name.alignment = .center
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        info.font = .systemFont(ofSize: 11.5)
        info.textColor = .white.withAlphaComponent(0.55)
        info.alignment = .center
        info.maximumNumberOfLines = 3
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(info)

        buttons = NSStackView(views: [Self.button("arrow.up.forward.app", L("Aç"), self, #selector(openTap)),
                                      Self.button("folder", L("Finder'da göster"), self, #selector(revealTap)),
                                      Self.button("trash", L("Çöp Sepetine taşı"), self, #selector(trashTap))])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            ql.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            ql.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ql.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            ql.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -12),

            bigIcon.centerXAnchor.constraint(equalTo: ql.centerXAnchor),
            bigIcon.centerYAnchor.constraint(equalTo: ql.centerYAnchor),
            bigIcon.widthAnchor.constraint(equalToConstant: 96),
            bigIcon.heightAnchor.constraint(equalToConstant: 96),

            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            name.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -4),

            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            info.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ tip: String, _ target: AnyObject, _ sel: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage(), target: target, action: sel)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 15
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        b.contentTintColor = symbol == "trash" ? Brand.nsRed.blended(withFraction: 0.25, of: .white) : .white
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 30)])
        return b
    }

    @objc private func openTap() { onOpen?() }
    @objc private func revealTap() { onReveal?() }
    @objc private func trashTap() { onTrash?() }

    func show(_ r: FileResult?) {
        guard let r else {
            current = nil
            ql.previewItem = nil
            ql.isHidden = true
            bigIcon.isHidden = true
            name.stringValue = ""
            info.stringValue = ""
            buttons.isHidden = true
            return
        }
        buttons.isHidden = false
        name.stringValue = r.name
        info.stringValue = Self.describe(r)
        guard current != r.path else { return }
        current = r.path
        let exists = FileManager.default.fileExists(atPath: r.path)
        // Klasör ve uygulamalarda büyük ikon; dosyalarda gerçek önizleme
        if r.isDir || !exists {
            ql.previewItem = nil
            ql.isHidden = true
            bigIcon.isHidden = false
            var img = NSWorkspace.shared.icon(forFile: r.path)
            if !exists {
                let ext = (r.name as NSString).pathExtension
                img = r.isDir ? NSWorkspace.shared.icon(for: .folder)
                    : (UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? img)
            }
            img.size = NSSize(width: 256, height: 256)
            bigIcon.image = img
        } else {
            bigIcon.isHidden = true
            ql.isHidden = false
            ql.previewItem = URL(fileURLWithPath: r.path) as NSURL
        }
    }

    /// "PDF belgesi · 2,4 MB · 3 Kas 2026"
    private static func describe(_ r: FileResult) -> String {
        let url = URL(fileURLWithPath: r.path)
        let v = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey])
        var parts: [String] = []
        if let k = v?.localizedTypeDescription { parts.append(k) }
        else if r.isDir { parts.append(L("Klasör")) }
        if !r.isDir, let size = v?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        let date = v?.contentModificationDate ?? r.mtime
        if date > Date.distantPast {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.locale = AppLanguage.active == .tr ? Locale(identifier: "tr_TR") : Locale(identifier: "en_US")
            parts.append(f.string(from: date))
        }
        let folder = ((r.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return parts.joined(separator: " · ") + "\n" + folder
    }
}


// MARK: - Finder'ın kendi arama kutusu

/// Finder'ın sağ üstteki arama kutusuna tıklanınca Finder'ın aramasını bırakıp bizimkini açar.
/// Sadece Finder öndeyken, odak değişikliklerini dinler (AXObserver).
@MainActor final class FinderSearchHook {
    var onSearch: () -> Void = {}
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var running = false
    private var lastFire = Date.distantPast

    func start() {
        guard !running else { return }
        running = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        appChanged()
    }

    func stop() {
        running = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detach()
    }

    @objc private func appChanged() {
        guard running, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.finder" else { return }
        attach(app.processIdentifier)
    }

    private func attach(_ p: pid_t) {
        guard pid != p else { return }
        detach()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FinderSearchHook>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.focusChanged(element) }
        }
        guard AXObserverCreate(p, cb, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(p)
        AXObserverAddNotification(obs, app, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        pid = p
    }

    private func detach() {
        if let obs = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes) }
        observer = nil
        pid = 0
    }

    private func focusChanged(_ el: AXUIElement) {
        guard FileSearchSettings.enabled, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let role: String = AX.attr(el, kAXRoleAttribute) ?? ""
        let sub: String = AX.attr(el, kAXSubroleAttribute) ?? ""
        guard role == kAXTextFieldRole as String, sub == kAXSearchFieldSubrole as String else { return }
        guard Date().timeIntervalSince(lastFire) > 0.6 else { return }
        lastFire = Date()
        // Finder'ın aramasını bırak (Esc): odak dosya listesine döner, kutuya bir dahaki tıklama yine yakalanır
        Self.sendEscape(to: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.onSearch() }
        }
    }

    private static func sendEscape(to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.postToPid(pid)
        }
    }
}
