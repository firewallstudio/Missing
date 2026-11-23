import Cocoa
import SwiftUI
import Combine
import Quartz
import UniformTypeIdentifiers

// MARK: - Sekme

@MainActor final class FilesTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var error: Error?
    @Published private(set) var loaded = false
    @Published private(set) var freeSpace: Int64?
    @Published var filter = "" { didSet { if filter != oldValue { applyFilter() } } }
    /// İndeks araması sürüyor / sonuçlarda alt klasörlerden gelenler var
    @Published private(set) var searching = false
    @Published private(set) var deepSearch = false
    private var searchGen = 0
    private let searchToken = SearchToken()
    /// Seçili öğeler (görünümden gelir)
    @Published var selection: [URL] = []
    /// Bir etiketin dosyaları gösteriliyorsa o etiket (adres yine son klasörde kalır)
    @Published private(set) var tag: FinderTag?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// Yüklemeden sonra seçilecek / adı düzenlenecek öğeler
    var pendingSelect: [URL]?
    var pendingRename: URL?
    /// Sekmeye dönünce kaldığı yerden devam
    var scrollY: CGFloat?

    private(set) var sortKey: FilesSortKey = .name
    private(set) var ascending = true
    private var back: [URL] = []
    private var forward: [URL] = []
    private var all: [FileItem] = []
    private let watcher = DirectoryWatcher()
    private var generation = 0
    var showHidden: () -> Bool = { FilesSettings.showHidden }

    init(url: URL) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path)
        watcher.onChange = { [weak self] in self?.reload() }
        load()
    }

    var title: String {
        if let tag { return tag.name }
        return url.path == "/" ? (FilesPlaces.shared.volumes.first { $0.url.path == "/" }?.title ?? "/")
            : FileManager.default.displayName(atPath: url.path)
    }

    func go(_ target: URL, record: Bool = true) {
        let target = URL(fileURLWithPath: target.standardizedFileURL.path)
        guard target.fileKey != url.fileKey || tag != nil else { return }
        tag = nil
        // Finder gibi: başka klasöre geçince arama biter
        if !filter.isEmpty { filter = "" }
        if record {
            back.append(url)
            forward.removeAll()
        }
        // Üst klasöre çıkınca geldiğimiz klasör seçili olsun (Finder gibi)
        if pendingSelect == nil, url.path.hasPrefix(target.path == "/" ? "/" : target.path + "/") {
            let rest = url.path.dropFirst(target.path == "/" ? 1 : target.path.count + 1)
            if let first = rest.split(separator: "/").first {
                pendingSelect = [target.appendingPathComponent(String(first))]
            }
        }
        url = target
        filter = ""
        selection = []
        scrollY = nil
        updateHistory()
        load()
    }

    func goBack() {
        guard let u = back.popLast() else { return }
        forward.append(url)
        go(u, record: false)
    }

    func goForward() {
        guard let u = forward.popLast() else { return }
        back.append(url)
        go(u, record: false)
    }

    func goUp() {
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return }
        go(parent)
    }

    var canGoUp: Bool { url.path != "/" && tag == nil }

    /// Etiketin dosyaları (Finder'daki gibi bütün Mac'ten)
    func showTag(_ t: FinderTag) {
        guard tag != t else { return }
        if !filter.isEmpty { filter = "" }
        back.append(url)
        forward.removeAll()
        tag = t
        selection = []
        scrollY = nil
        updateHistory()
        load()
    }

    private func updateHistory() {
        canGoBack = !back.isEmpty
        canGoForward = !forward.isEmpty
    }

    func reload() { load() }

    private func load() {
        generation += 1
        let gen = generation
        let target = url
        if let t = tag {
            watcher.stop()
            let hidden = showHidden()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let list = FinderTags.files(tagged: t.name).compactMap { FileItem(url: $0) }.filter { hidden || !$0.isHidden }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, gen == self.generation else { return }
                        self.error = nil
                        self.all = list
                        self.loaded = true
                        self.freeSpace = nil
                        self.resort()
                    }
                }
            }
            return
        }
        watcher.watch(target)
        DirectoryLoader.load(target, showHidden: showHidden()) { [weak self] r in
            guard let self, gen == self.generation else { return }
            switch r {
            case .success(let list):
                self.error = nil
                self.all = list
            case .failure(let e):
                self.error = e
                self.all = []
            }
            self.loaded = true
            self.freeSpace = (try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            self.resort()
        }
    }

    func setSort(_ key: FilesSortKey, ascending: Bool) {
        sortKey = key
        self.ascending = ascending
        resort()
    }

    private func resort() {
        let key = sortKey, asc = ascending
        all.sort { a, b in
            let r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .modified: r = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .size: r = Self.compare(a.size ?? -1, b.size ?? -1)
            case .kind:
                let k = a.kind.localizedStandardCompare(b.kind)
                r = k == .orderedSame ? a.name.localizedStandardCompare(b.name) : k
            }
            if r == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        totalCount = all.count
        applyFilter()
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// Önce bu klasörde anında süzer; ⌘Space aramasının indeksi açıksa ardından bütün alt klasörlerde arar
    /// (aynı sorgu dili: ".pdf rapor", "/" yalnız klasörler, daha önce seçilenler üste çıkar)
    private func applyFilter() {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let local = f.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(f) }
        items = local
        searchGen += 1
        guard !f.isEmpty, tag == nil, FileSearchSettings.enabled,
              let q0 = FileSearchController.makeQuery(f, scope: url.path) else {
            if deepSearch { deepSearch = false }
            if searching { searching = false }
            return
        }
        var q = q0
        q.limit = 300
        let g = searchGen
        let gen = searchToken
        gen.bump(g)
        searching = true
        // Yazarken her harfte değil, kısa bir duraksamada ara
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.searchGen == g else { return }
            FileIndex.shared.queue.async {
                guard gen.isCurrent(g) else { return }
                let r = FileIndex.shared.search(q, isStale: { !gen.isCurrent(g) })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.searchGen == g else { return }
                        self.searching = false
                        self.mergeDeep(r, local: local)
                    }
                }
            }
        }
    }

    private func mergeDeep(_ r: [FileResult], local: [FileItem]) {
        let showHidden = showHidden()
        var seen = Set(local.map(\.url.fileKey))
        var extra: [FileItem] = []
        for hit in r {
            let u = URL(fileURLWithPath: hit.path)
            guard !seen.contains(u.fileKey), let it = FileItem(url: u), showHidden || !it.isHidden else { continue }
            seen.insert(u.fileKey)
            extra.append(it)
        }
        deepSearch = !extra.isEmpty
        if !extra.isEmpty { items = local + extra }
    }

    /// Alt klasördeki sonucun bu klasöre göre yeri ("Projeler › a"); doğrudan içindeyse nil
    func relativeFolder(of item: FileItem) -> String? {
        let parent = item.url.deletingLastPathComponent()
        if tag != nil { return (parent.path as NSString).abbreviatingWithTildeInPath }
        guard parent.fileKey != url.fileKey else { return nil }
        let base = url.path == "/" ? "/" : url.path + "/"
        let p = parent.path
        guard p.hasPrefix(base) else { return p }
        return p.dropFirst(base.count).split(separator: "/").joined(separator: " › ")
    }

    func stop() { watcher.stop() }
}

/// Arka plandaki indeks aramasına "daha yenisi başladı" demek için
final class SearchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == v }
}

// MARK: - Pencere modeli

@MainActor final class FilesWindowModel: ObservableObject {
    @Published var tabs: [FilesTab]
    @Published var currentID: UUID
    @Published var viewMode = FilesSettings.viewMode
    @Published var showHidden = FilesSettings.showHidden
    @Published var sidebarVisible = FilesSettings.sidebarVisible
    @Published var previewVisible = FilesSettings.previewVisible
    /// Arama kutusuna odaklan (her artışta)
    @Published var searchFocus = 0
    /// Yol çubuğunu yazılabilir yap (her artışta, ⌘L)
    @Published var pathEdit = 0
    /// Sekmelerin pencere içindeki yerleri (orta tıkla kapatmak için)
    var tabFrames: [UUID: CGRect] = [:]

    init(urls: [URL], selected: Int) {
        let t = urls.map { FilesTab(url: $0) }
        tabs = t
        currentID = t[min(max(0, selected), t.count - 1)].id
    }

    var current: FilesTab { tabs.first { $0.id == currentID } ?? tabs[0] }
    var currentIndex: Int { tabs.firstIndex { $0.id == currentID } ?? 0 }

    @discardableResult
    func addTab(_ url: URL, select: Bool = true) -> FilesTab {
        let t = FilesTab(url: url)
        tabs.insert(t, at: min(currentIndex + 1, tabs.count))
        if select { currentID = t.id }
        return t
    }

    /// Son sekmeyse false döner (pencere kapanmalı)
    func closeTab(_ id: UUID) -> Bool {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs[i].stop()
        tabs.remove(at: i)
        if currentID == id { currentID = tabs[min(i, tabs.count - 1)].id }
        return true
    }

    func moveTab(_ id: UUID, by delta: Int) {
        guard delta != 0, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(0, i + delta), tabs.count - 1)
        guard i != j else { return }
        let t = tabs.remove(at: i)
        tabs.insert(t, at: j)
    }
}

// MARK: - Pencere

private final class FilesNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class FilesWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
                                              QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: FilesWindowModel
    let browser = FilesBrowser()
    private var bag = Set<AnyCancellable>()
    private var tabBag = Set<AnyCancellable>()

    init(urls: [URL], selected: Int, cascadeFrom: NSWindow?) {
        model = FilesWindowModel(urls: urls, selected: selected)
        let w = FilesNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 560, height: 340)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: w)
        w.delegate = self
        browser.owner = self
        w.contentView = NSHostingView(rootView: FilesRootView(model: model, controller: self))
        if let prev = cascadeFrom {
            w.setFrame(prev.frame, display: false)
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY)))
        } else if !w.setFrameUsingName("MissingFiles") {
            w.center()
        }
        w.setFrameAutosaveName("MissingFiles")

        model.$currentID.sink { [weak self] _ in
            DispatchQueue.main.async { self?.currentTabChanged() }
        }.store(in: &bag)
        model.$viewMode.dropFirst().sink { [weak self] m in
            FilesSettings.viewMode = m
            DispatchQueue.main.async { self?.browser.setMode(m) }
        }.store(in: &bag)
        browser.setMode(model.viewMode)
        applyTheme()
        currentTabChanged()
    }

    /// Tema değişince: Missing ve Cam koyu görünümü dayatır, Finder ve Windows sistemi izler
    func applyTheme() {
        let t = FilesThemeStore.shared.theme
        window?.appearance = t.forcesDark ? NSAppearance(named: .darkAqua) : nil
        browser.applyTheme()
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = FilesTheme(rawValue: raw) else { return }
        FilesThemeStore.shared.theme = t
    }

    required init?(coder: NSCoder) { fatalError() }

    private func currentTabChanged() {
        let tab = model.current
        browser.show(tab)
        tabBag.removeAll()
        tab.$url.sink { [weak self] _ in
            DispatchQueue.main.async { self?.window?.title = tab.title }
        }.store(in: &tabBag)
        tab.$selection.sink { _ in
            DispatchQueue.main.async {
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                    QLPreviewPanel.shared().reloadData()
                }
            }
        }.store(in: &tabBag)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.browser.focus() }
    }

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible, QLPreviewPanel.shared().dataSource === self {
            QLPreviewPanel.shared().orderOut(nil)
        }
        model.tabs.forEach { $0.stop() }
        FilesManager.shared.closed(self)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    private let undo = UndoManager()

    var tab: FilesTab { model.current }

    // MARK: Gezinme

    func navigate(_ url: URL, newTab: Bool = false) {
        if newTab || NSEvent.modifierFlags.contains(.command) {
            model.addTab(url)
        } else {
            tab.go(url)
        }
        browser.focus()
    }

    func openTab(_ url: URL) { model.addTab(url) }

    /// Kenar çubuğundaki etiket: o etiketi taşıyan bütün dosyalar
    func showTag(_ t: FinderTag, newTab: Bool = false) {
        // Etiket sonuçları farklı klasörlerden gelir: sütunlarda değil listede gösterilir
        if model.viewMode == .columns { model.viewMode = .list }
        if newTab || NSEvent.modifierFlags.contains(.command) {
            model.addTab(tab.url).showTag(t)
        } else {
            tab.showTag(t)
        }
        browser.focus()
    }

    /// Çift tık / ⌘↓: klasöre gir, dosyayı aç
    func open(_ items: [FileItem], newTab: Bool = false) {
        // Aramadan açılanı hatırla: aynı aramada bir dahaki sefere üstte gelsin (⌘Space ile ortak)
        let query = tab.filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, items.count == 1 { SearchMemory.record(query: query, path: items[0].url.path) }
        let folders = items.filter(\.opensAsFolder)
        let files = items.filter { !$0.opensAsFolder }
        let wantTab = newTab || NSEvent.modifierFlags.contains(.command)
        if folders.count == 1 && files.isEmpty && !wantTab {
            tab.go(folders[0].folderTarget)
        } else {
            for f in folders { model.addTab(f.folderTarget, select: folders.count == 1) }
        }
        for f in files { NSWorkspace.shared.open(f.url) }
    }

    func middleClick(_ e: NSEvent) -> Bool {
        guard let host = window?.contentView else { return false }
        let p = host.convert(e.locationInWindow, from: nil)
        let y = host.isFlipped ? p.y : host.bounds.height - p.y
        guard let id = model.tabFrames.first(where: { $0.value.contains(CGPoint(x: p.x, y: y)) })?.key else { return false }
        close(tabID: id)
        return true
    }

    func close(tabID: UUID) {
        if !model.closeTab(tabID) { window?.performClose(nil) }
    }

    // MARK: Menü eylemleri

    private var selectedItems: [FileItem] { browser.selectedItems }
    private var selectedURLs: [URL] { selectedItems.map(\.url) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let sel = selectedItems
        switch item.action {
        case #selector(openSelection(_:)), #selector(trashSelection(_:)), #selector(duplicateSelection(_:)),
             #selector(copy(_:)), #selector(revealInFinder(_:)), #selector(toggleQuickLook(_:)):
            return !sel.isEmpty || item.action == #selector(revealInFinder(_:)) || item.action == #selector(toggleQuickLook(_:))
        case #selector(openSelectionInTab(_:)):
            return !sel.isEmpty && sel.allSatisfy(\.opensAsFolder)
        case #selector(renameSelection(_:)):
            return sel.count == 1
        case #selector(paste(_:)), #selector(moveHere(_:)):
            return !Self.pasteboardURLs().isEmpty
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(goUp(_:)): return tab.canGoUp
        case #selector(showList(_:)):
            item.state = model.viewMode == .list ? .on : .off
        case #selector(showGrid(_:)):
            item.state = model.viewMode == .grid ? .on : .off
        case #selector(showColumns(_:)):
            item.state = model.viewMode == .columns ? .on : .off
        case #selector(toggleHidden(_:)):
            item.state = model.showHidden ? .on : .off
        case #selector(toggleSidebar(_:)):
            item.state = model.sidebarVisible ? .on : .off
        case #selector(togglePreview(_:)):
            item.state = model.previewVisible ? .on : .off
        case #selector(setTheme(_:)):
            item.state = (item.representedObject as? String) == FilesThemeStore.shared.theme.rawValue ? .on : .off
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return model.tabs.count > 1
        default: break
        }
        return true
    }

    @objc func newWindow(_ sender: Any?) { FilesManager.shared.open(newWindow: true) }
    @objc func newTab(_ sender: Any?) {
        model.addTab(tab.url)
        browser.focus()
    }
    @objc func closeTab(_ sender: Any?) { close(tabID: model.currentID) }

    @objc func newFolder(_ sender: Any?) {
        guard let dest = FileOps.newFolder(in: tab.url, undo: undo, window: window) else { return }
        tab.filter = ""
        tab.pendingSelect = [dest]
        tab.pendingRename = dest
        tab.reload()
    }

    @objc func openSelection(_ sender: Any?) { open(selectedItems) }
    @objc func openSelectionInTab(_ sender: Any?) { open(selectedItems, newTab: true) }

    @objc func renameSelection(_ sender: Any?) {
        guard selectedItems.count == 1, let u = selectedURLs.first else { return }
        browser.beginRename(u)
    }

    @objc func duplicateSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let t = tab
        FileOps.duplicate(urls, undo: undo, window: window) { copies in
            t.pendingSelect = copies
            t.reload()
        }
    }

    @objc func trashSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        // Seçim, silinenlerden sonraki öğeye geçsin
        if let next = browser.itemAfter(urls) { tab.pendingSelect = [next] }
        FileOps.trash(urls, undo: undo, window: window)
        tab.reload()
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = selectedURLs
        if urls.isEmpty { NSWorkspace.shared.open(tab.url) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func pinSelection(_ sender: Any?) {
        let folders = selectedItems.filter(\.opensAsFolder).map(\.folderTarget)
        if folders.isEmpty { FilesPlaces.shared.pin(tab.url) } else { folders.forEach(FilesPlaces.shared.pin) }
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedURLs.isEmpty ? [tab.url.path] : selectedURLs.map(\.path)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func paste(_ sender: Any?) { pasteFiles(move: false) }
    @objc func moveHere(_ sender: Any?) { pasteFiles(move: true) }

    private func pasteFiles(move: Bool) {
        let urls = Self.pasteboardURLs()
        guard !urls.isEmpty else { return }
        let t = tab
        FileOps.transfer(urls, to: t.url, mode: move ? .move : .copy, undo: undo, window: window) { done in
            t.pendingSelect = done
            t.reload()
        }
    }

    static func pasteboardURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Sürükle-bırak ve kenar çubuğuna bırakma: aynı diskte taşı, başka diske kopyala (⌥ ile her zaman kopyala)
    func drop(_ urls: [URL], into dir: URL, forceCopy: Bool = false) {
        let copy = forceCopy || NSEvent.modifierFlags.contains(.option) || !urls.allSatisfy { FileOps.sameVolume($0, dir) }
        let t = tab
        FileOps.transfer(urls, to: dir, mode: copy ? .copy : .move, undo: undo, window: window) { done in
            if t.url.fileKey == dir.fileKey { t.pendingSelect = done }
            t.reload()
        }
    }

    @objc func focusSearch(_ sender: Any?) { model.searchFocus += 1 }
    @objc func editPath(_ sender: Any?) { model.pathEdit += 1 }
    @objc func showList(_ sender: Any?) { model.viewMode = .list }
    @objc func showGrid(_ sender: Any?) { model.viewMode = .grid }
    @objc func showColumns(_ sender: Any?) { model.viewMode = .columns }

    @objc func toggleHidden(_ sender: Any?) {
        model.showHidden.toggle()
        FilesSettings.showHidden = model.showHidden
        for w in FilesManager.shared.windows {
            w.model.showHidden = model.showHidden
            w.model.tabs.forEach { $0.reload() }
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        withAnimation(.easeOut(duration: 0.18)) { model.sidebarVisible.toggle() }
        FilesSettings.sidebarVisible = model.sidebarVisible
    }

    @objc func togglePreview(_ sender: Any?) {
        withAnimation(.easeOut(duration: 0.18)) { model.previewVisible.toggle() }
        FilesSettings.previewVisible = model.previewVisible
    }

    @objc func reload(_ sender: Any?) { tab.reload() }
    @objc func goBack(_ sender: Any?) { tab.goBack(); browser.focus() }
    @objc func goForward(_ sender: Any?) { tab.goForward(); browser.focus() }
    @objc func goUp(_ sender: Any?) { tab.goUp(); browser.focus() }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, FileManager.default.fileExists(atPath: u.path) else { NSSound.beep(); return }
        tab.go(u)
        browser.focus()
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = L("Klasöre git")
        a.informativeText = L("Bir yol yaz; ~ ev klasörün demek.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = (tab.url.path as NSString).abbreviatingWithTildeInPath
        field.placeholderString = "~/Documents"
        a.accessoryView = field
        a.addButton(withTitle: L("Git"))
        a.addButton(withTitle: L("Vazgeç"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let path = (field.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            let u = URL(fileURLWithPath: path)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { NSSound.beep(); return }
            if dir.boolValue {
                self.tab.go(u)
            } else {
                self.tab.pendingSelect = [u]
                self.tab.go(u.deletingLastPathComponent())
            }
            self.browser.focus()
        }
    }

    @objc func nextTab(_ sender: Any?) {
        let i = model.currentIndex
        model.currentID = model.tabs[(i + 1) % model.tabs.count].id
    }

    @objc func previousTab(_ sender: Any?) {
        let i = model.currentIndex
        model.currentID = model.tabs[(i - 1 + model.tabs.count) % model.tabs.count].id
    }

    func openWith(_ urls: [URL], app: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: cfg) { _, _ in }
    }

    func openInTerminal(_ dir: URL) {
        guard let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        openWith([dir], app: term)
    }

    // MARK: Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        let p = QLPreviewPanel.shared()!
        if p.isVisible { p.orderOut(nil) } else { p.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            let u = quickLookURLs
            return u.indices.contains(index) ? u[index] as NSURL : nil
        }
    }

    private var quickLookURLs: [URL] {
        let s = selectedURLs
        return s.isEmpty ? [] : s
    }

    /// Önizleme açıkken ok tuşları seçimi değiştirsin
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        return MainActor.assumeIsolated { browser.forwardKey(event) }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard let u = item.previewItemURL else { return .zero }
            return browser.screenFrame(of: u) ?? .zero
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated {
            guard let u = item.previewItemURL else { return nil }
            return FileIcons.shared.icon(u)
        }
    }
}

// MARK: - Görünüm

struct FilesRootView: View {
    @ObservedObject var model: FilesWindowModel
    @ObservedObject var store = FilesThemeStore.shared
    let controller: FilesWindowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = FilesPalette(theme: store.theme, dark: store.theme.forcesDark || scheme == .dark)
        Group {
            switch p.theme {
            case .missing: missingLayout(p)
            case .glass: glassLayout(p)
            case .finder: finderLayout(p)
            case .windows: windowsLayout(p)
            }
        }
        .coordinateSpace(name: "files")
        .foregroundStyle(p.fg)
        .environment(\.filesPalette, p)
        .environment(\.colorScheme, p.dark ? .dark : .light)
        .ignoresSafeArea()
    }

    private var tab: FilesTab { model.current }

    private var content: some View {
        HStack(spacing: 0) {
            ZStack {
                BrowserHost(view: controller.browser)
                FilesEmptyState(tab: tab)
            }
            if model.previewVisible {
                Rectangle().fill(FilesPalette(theme: store.theme, dark: store.theme.forcesDark || scheme == .dark).divider)
                    .frame(width: 1)
                FilesPreviewPane(tab: tab)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func sidebar(_ width: CGFloat = 196) -> some View {
        FilesSidebar(tab: tab, controller: controller)
            .frame(width: width)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    // Missing: koyu cam, sekmeler en üstte
    private func missingLayout(_ p: FilesPalette) -> some View {
        VStack(spacing: 0) {
            FilesTabStrip(model: model, controller: controller).frame(height: 30)
            FilesToolbar(model: model, tab: tab, controller: controller).frame(height: 42)
            Rectangle().fill(p.divider).frame(height: 1)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    sidebar().background(Color.black.opacity(0.10))
                    Rectangle().fill(p.divider).frame(width: 1)
                }
                VStack(spacing: 0) {
                    content.background(Color.black.opacity(0.18))
                    Rectangle().fill(p.divider).frame(height: 1)
                    FilesStatusBar(tab: tab, activity: FilesActivity.shared).frame(height: 26)
                }
            }
        }
        .background(ZStack { GlassBlur(material: .hudWindow); Color.black.opacity(0.42) }.ignoresSafeArea())
    }

    // Cam: renkli bulanık zemin, yüzen kartlar
    private func glassLayout(_ p: FilesPalette) -> some View {
        VStack(spacing: 0) {
            FilesTabStrip(model: model, controller: controller).frame(height: 34)
            FilesToolbar(model: model, tab: tab, controller: controller).frame(height: 44)
            HStack(spacing: 10) {
                if model.sidebarVisible {
                    sidebar(190).modifier(GlassCard())
                }
                VStack(spacing: 0) {
                    content
                    Rectangle().fill(p.divider).frame(height: 1)
                    FilesStatusBar(tab: tab, activity: FilesActivity.shared).frame(height: 26)
                }
                .modifier(GlassCard())
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, 2)
        }
        .background(GlassmorphBackground().ignoresSafeArea())
    }

    // Finder: tam boy kenar çubuğu, sekmeler araç çubuğunun altında, yol alt çubukta
    private func finderLayout(_ p: FilesPalette) -> some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 46)
                    FilesSidebar(tab: tab, controller: controller)
                }
                .frame(width: 200)
                .background(GlassBlur(material: .sidebar, appearance: p.dark ? .darkAqua : .aqua))
                .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(p.divider).frame(width: 1)
            }
            VStack(spacing: 0) {
                FilesToolbar(model: model, tab: tab, controller: controller,
                             lead: model.sidebarVisible ? 10 : 80)
                    .frame(height: 52)
                    .background(p.finderChrome)
                Rectangle().fill(p.divider).frame(height: 1)
                if model.tabs.count > 1 {
                    FilesTabStrip(model: model, controller: controller).frame(height: 28)
                        .background(p.finderTabBar)
                    Rectangle().fill(p.divider).frame(height: 1)
                }
                content.background(p.finderContent)
                Rectangle().fill(p.divider).frame(height: 1)
                FilesStatusBar(tab: tab, activity: FilesActivity.shared, controller: controller)
                    .frame(height: 26)
                    .background(p.finderChrome)
            }
        }
        .background(p.finderChrome.ignoresSafeArea())
    }

    // Windows 11 Gezgini: sekmeler, adres satırı, komut çubuğu
    private func windowsLayout(_ p: FilesPalette) -> some View {
        VStack(spacing: 0) {
            FilesTabStrip(model: model, controller: controller).frame(height: 38)
                .background(p.winTabBar)
            WindowsAddressRow(model: model, tab: tab, controller: controller)
                .frame(height: 44)
                .background(p.winChrome)
            WindowsCommandBar(model: model, tab: tab, controller: controller)
                .frame(height: 40)
                .background(p.winChrome)
            Rectangle().fill(p.divider).frame(height: 1)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    sidebar(200)
                    Rectangle().fill(p.divider).frame(width: 1)
                }
                VStack(spacing: 0) {
                    content
                    Rectangle().fill(p.divider).frame(height: 1)
                    FilesStatusBar(tab: tab, activity: FilesActivity.shared).frame(height: 24)
                }
            }
            .background(p.winContent)
        }
        .background(p.winTabBar.ignoresSafeArea())
    }
}

/// Tarayıcı tek bir NSView; tema değişince yeni kaba taşınır, eski kap onu söküp atmasın
private struct BrowserHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(to: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if view.superview !== box { attach(to: box) }
    }

    static func dismantleNSView(_ box: NSView, coordinator: ()) {
        // Yeni kap almışsa dokunma
        for v in box.subviews where v.superview === box { v.removeFromSuperview() }
    }

    private func attach(to box: NSView) {
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
    }
}

/// Boş klasör, açılamayan klasör, aramada sonuç yok
private struct FilesEmptyState: View {
    @ObservedObject var tab: FilesTab
    @Environment(\.filesPalette) private var p

    var body: some View {
        Group {
            if let e = tab.error {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(p.fg.opacity(0.4))
                    Text(L("Bu klasör açılamadı")).font(.system(size: 14, weight: .semibold))
                    Text(e.localizedDescription).font(.system(size: 11.5)).foregroundStyle(p.fg.opacity(0.55))
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                    if (e as NSError).code == NSFileReadNoPermissionError {
                        Button(L("Tam Disk Erişimi ver")) { SettingsModel.open("Privacy_AllFiles") }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
            } else if tab.loaded && tab.items.isEmpty {
                Text(tab.filter.isEmpty ? L("Klasör boş") : L("“%@” için sonuç yok", tab.filter))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.fg.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .padding(20)
    }
}

// MARK: Sekme şeridi

private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Üst köşeleri yuvarlak dikdörtgen (Windows sekmesi)
private struct TopRounded: Shape {
    var radius: CGFloat
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

struct FilesTabStrip: View {
    @ObservedObject var model: FilesWindowModel
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p

    private struct Metrics { var lead: CGFloat; var spacing: CGFloat; var maxW: CGFloat; var minW: CGFloat; var chipH: CGFloat }

    private var m: Metrics {
        switch p.theme {
        case .missing: return Metrics(lead: 80, spacing: 4, maxW: 220, minW: 110, chipH: 26)
        case .glass: return Metrics(lead: 80, spacing: 6, maxW: 220, minW: 110, chipH: 28)
        case .windows: return Metrics(lead: 80, spacing: 2, maxW: 240, minW: 110, chipH: 32)
        case .finder: return Metrics(lead: 0, spacing: 0, maxW: .infinity, minW: 120, chipH: 28)
        }
    }

    var body: some View {
        let m = m
        GeometryReader { geo in
            let plusW: CGFloat = p.theme == .finder ? 30 : 34
            let avail = geo.size.width - m.lead - plusW - (p.theme == .finder ? 0 : 10)
            let n = CGFloat(max(1, model.tabs.count))
            let w = min(m.maxW, max(m.minW, (avail - (n - 1) * m.spacing) / n))
            HStack(spacing: 0) {
                Color.clear.frame(width: m.lead)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: m.spacing) {
                            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { i, t in
                                FilesTabChip(tab: t, index: i, width: w, height: m.chipH, step: w + m.spacing,
                                             model: model, controller: controller)
                                    .id(t.id)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: p.theme == .windows ? .bottom : .center)
                    }
                    .frame(maxWidth: min(avail, n * (w + m.spacing)), alignment: .leading)
                    .onChange(of: model.currentID) { id in withAnimation { proxy.scrollTo(id) } }
                }
                Button { controller.newTab(nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: plusW - 6, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolButtonStyle())
                .foregroundStyle(p.fg.opacity(0.6))
                .help(L("Yeni sekme") + "  ⌘T")
                .padding(.leading, p.theme == .finder ? 2 : 4)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .onPreferenceChange(TabFramesKey.self) { model.tabFrames = $0 }
    }
}

private struct FilesTabChip: View {
    @ObservedObject var tab: FilesTab
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let step: CGFloat
    @ObservedObject var model: FilesWindowModel
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p
    @State private var hover = false
    @State private var dropTarget = false
    @State private var drag: CGFloat = 0

    var body: some View {
        let selected = model.currentID == tab.id
        let showClose = hover || (selected && p.theme != .finder)
        let finder = p.theme == .finder
        HStack(spacing: 6) {
            if finder { Spacer(minLength: 0) }
            if !finder {
                Image(nsImage: FileIcons.shared.icon(tab.url)).resizable().frame(width: 15, height: 15)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: selected && !finder ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(p.fg.opacity(selected ? 1 : (finder ? 0.7 : 0.6)))
        .padding(.leading, finder ? 26 : 10)
        .padding(.trailing, finder ? 26 : (showClose ? 26 : 10))
        .frame(width: width, height: height)
        .background(background(selected))
        .overlay(alignment: .bottom) {
            if selected && p.theme == .missing { Capsule().fill(p.accent).frame(height: 2).padding(.horizontal, 10) }
        }
        .overlay(alignment: .trailing) {
            // Finder ve Windows: sekmeler arası ince çizgi
            if (finder || (p.theme == .windows && !selected)) && index < model.tabs.count - 1 {
                Rectangle().fill(p.fg.opacity(finder ? 0.12 : 0.15)).frame(width: 1, height: finder ? height : 16)
            }
        }
        .overlay(alignment: finder ? .leading : .trailing) {
            if showClose {
                Button { controller.close(tabID: tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(p.fg.opacity(hover ? 0.12 : 0)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.fg.opacity(0.7))
                .padding(finder ? .leading : .trailing, 6)
                .help(L("Sekmeyi kapat") + "  ⌘W")
            }
        }
        .contentShape(Rectangle())
        .offset(x: drag)
        .zIndex(drag != 0 ? 1 : (selected ? 0.5 : 0))
        .background(GeometryReader { g in
            Color.clear.preference(key: TabFramesKey.self, value: [tab.id: g.frame(in: .named("files"))])
        })
        .onHover { hover = $0 }
        .onTapGesture { model.currentID = tab.id }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    model.currentID = tab.id
                    drag = v.translation.width
                    if drag > step * 0.6, index < model.tabs.count - 1 {
                        model.moveTab(tab.id, by: 1)
                        drag -= step
                    } else if drag < -step * 0.6, index > 0 {
                        model.moveTab(tab.id, by: -1)
                        drag += step
                    }
                }
                .onEnded { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { drag = 0 } }
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            let dest = tab.url
            loadFileURLs(providers) { urls in controller.drop(urls, into: dest) }
            return true
        }
        .help(tab.url.path)
        .contextMenu {
            Button(L("Sekmeyi kapat")) { controller.close(tabID: tab.id) }
            Button(L("Diğer sekmeleri kapat")) {
                for t in model.tabs where t.id != tab.id { _ = model.closeTab(t.id) }
            }
            .disabled(model.tabs.count < 2)
            Divider()
            Button(L("Yeni pencerede aç")) {
                let u = tab.url
                if model.tabs.count > 1 { _ = model.closeTab(tab.id) }
                FilesManager.shared.open(u, newWindow: true)
            }
            Button(L("Kenar çubuğuna ekle")) { FilesPlaces.shared.pin(tab.url) }
            Button(L("Finder'da göster")) { NSWorkspace.shared.open(tab.url) }
        }
    }

    @ViewBuilder private func background(_ selected: Bool) -> some View {
        let drop = p.accent.opacity(0.45)
        switch p.theme {
        case .missing:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dropTarget ? drop : p.fg.opacity(selected ? 0.16 : (hover ? 0.07 : 0)))
        case .glass:
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape.fill(dropTarget ? drop : .white.opacity(selected ? 0.18 : (hover ? 0.08 : 0)))
                .overlay(shape.strokeBorder(.white.opacity(selected ? 0.32 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(selected ? 0.2 : 0), radius: 6, y: 2)
        case .windows:
            TopRounded(radius: 7)
                .fill(dropTarget ? drop : selected ? p.winChrome : p.fg.opacity(hover ? 0.05 : 0))
        case .finder:
            Rectangle()
                .fill(dropTarget ? drop : selected ? p.finderChrome : p.fg.opacity(hover ? 0.05 : 0))
        }
    }
}

/// SwiftUI bırakmalarından dosya adreslerini al
func loadFileURLs(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u, u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
}

// MARK: Araç çubuğu (Missing, Cam, Finder)

private struct FilesToolbar: View {
    @ObservedObject var model: FilesWindowModel
    @ObservedObject var tab: FilesTab
    let controller: FilesWindowController
    var lead: CGFloat = 10
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 6) {
            FilesToolButton(symbol: "sidebar.left", help: L("Kenar çubuğu") + "  ⌥⌘S", on: model.sidebarVisible) { controller.toggleSidebar(nil) }
            if p.theme == .finder {
                HStack(spacing: 0) {
                    FilesToolButton(symbol: "chevron.left", help: L("Geri") + "  ⌘[", enabled: tab.canGoBack) { controller.goBack(nil) }
                    FilesToolButton(symbol: "chevron.right", help: L("İleri") + "  ⌘]", enabled: tab.canGoForward) { controller.goForward(nil) }
                }
                .padding(.leading, 4)
                Text(tab.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
            } else {
                FilesToolButton(symbol: "chevron.left", help: L("Geri") + "  ⌘[", enabled: tab.canGoBack) { controller.goBack(nil) }
                FilesToolButton(symbol: "chevron.right", help: L("İleri") + "  ⌘]", enabled: tab.canGoForward) { controller.goForward(nil) }
                FilesPathBar(tab: tab, controller: controller)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            if p.theme != .finder {
                FilesToolButton(symbol: "folder.badge.plus", help: L("Yeni klasör") + "  ⇧⌘N") { controller.newFolder(nil) }
            }
            FilesModePicker(model: model)
            FilesToolButton(symbol: "sidebar.right", help: L("Önizleme bölmesi") + "  ⇧⌘P", on: model.previewVisible) {
                controller.togglePreview(nil)
            }
            if p.theme == .finder {
                FilesToolButton(symbol: "folder.badge.plus", help: L("Yeni klasör") + "  ⇧⌘N") { controller.newFolder(nil) }
            }
            FilesSearchField(model: model, tab: tab, controller: controller, width: p.theme == .finder ? 180 : 200)
        }
        .padding(.leading, lead)
        .padding(.trailing, 10)
    }
}

/// Liste / simge geçişi
private struct FilesModePicker: View {
    @ObservedObject var model: FilesWindowModel
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 2) {
            button(.list, "list.bullet", L("Liste") + "  ⌘1")
            button(.grid, "square.grid.2x2", L("Simgeler") + "  ⌘2")
            button(.columns, "rectangle.split.3x1", L("Sütunlar") + "  ⌘3")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: p.radius, style: .continuous).fill(p.controlFill))
        .overlay(RoundedRectangle(cornerRadius: p.radius, style: .continuous)
            .strokeBorder(p.theme == .glass ? Color.white.opacity(0.15) : .clear, lineWidth: 1))
    }

    private func button(_ m: FilesViewMode, _ symbol: String, _ help: String) -> some View {
        let on = model.viewMode == m
        // Missing'de dolu vurgu; diğerlerinde hafif dolgu
        let fill: Color = !on ? .clear : (p.theme == .missing ? p.accent : p.fg.opacity(p.dark ? 0.18 : 0.12))
        return Button { model.viewMode = m } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: max(3, p.radius - 2), style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.theme == .missing && on ? .white : p.fg.opacity(on ? 1 : 0.6))
        .help(help)
    }
}

/// "Bu klasörde ara" kutusu (bütün temalar)
private struct FilesSearchField: View {
    @ObservedObject var model: FilesWindowModel
    @ObservedObject var tab: FilesTab
    let controller: FilesWindowController
    var width: CGFloat = 200
    var height: CGFloat = 26
    @Environment(\.filesPalette) private var p
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: p.radius, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.fg.opacity(0.5))
            TextField(L("Bu klasörde ara"), text: $tab.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onExitCommand {
                    tab.filter = ""
                    focused = false
                    controller.browser.focus()
                }
                .onSubmit { controller.browser.focus() }
            if !tab.filter.isEmpty {
                Button { tab.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(p.fg.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height)
        .background(shape.fill(p.theme == .windows ? p.controlFill : p.fg.opacity(focused ? 0.12 : 0.07)))
        .overlay(border(shape))
        .overlay(alignment: .bottom) {
            // Windows: odakta altta vurgu çizgisi
            if p.theme == .windows {
                Rectangle().fill(focused ? p.accent : p.fg.opacity(0.25)).frame(height: focused ? 2 : 1)
                    .padding(.horizontal, 1)
                    .clipShape(shape)
            }
        }
        .onChange(of: model.searchFocus) { _ in focused = true }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch p.theme {
        case .missing: shape.strokeBorder(focused ? p.accent.opacity(0.8) : .clear, lineWidth: 1)
        case .glass: shape.strokeBorder(.white.opacity(focused ? 0.45 : 0.15), lineWidth: 1)
        case .finder: shape.strokeBorder(focused ? p.accent.opacity(0.7) : p.fg.opacity(0.08), lineWidth: focused ? 2 : 1)
        case .windows: shape.strokeBorder(p.fg.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct FilesToolButton: View {
    let symbol: String
    let help: String
    var label: String? = nil
    var enabled = true
    var on = false
    let action: () -> Void
    @Environment(\.filesPalette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if let label { Text(label).font(.system(size: 12)) }
            }
            .padding(.horizontal, label == nil ? 0 : 8)
            .frame(minWidth: 28, minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle())
        .foregroundStyle(p.fg.opacity(enabled ? (on ? 0.95 : 0.75) : 0.25))
        .disabled(!enabled)
        .help(help)
    }
}

private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ToolButtonBody(configuration: configuration) }
    private struct ToolButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.filesPalette) private var p
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: max(4, p.radius - 1), style: .continuous)
                    .fill(configuration.isPressed ? p.pressFill : (hover ? p.hoverFill : .clear)))
                .onHover { hover = $0 }
        }
    }
}

// MARK: Windows: adres satırı ve komut çubuğu

private struct WindowsAddressRow: View {
    @ObservedObject var model: FilesWindowModel
    @ObservedObject var tab: FilesTab
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 4) {
            FilesToolButton(symbol: "arrow.left", help: L("Geri") + "  ⌘[", enabled: tab.canGoBack) { controller.goBack(nil) }
            FilesToolButton(symbol: "arrow.right", help: L("İleri") + "  ⌘]", enabled: tab.canGoForward) { controller.goForward(nil) }
            FilesToolButton(symbol: "arrow.up", help: L("Üst klasör") + "  ⌘↑", enabled: tab.canGoUp) { controller.goUp(nil) }
            FilesToolButton(symbol: "arrow.clockwise", help: L("Yenile") + "  ⌘R") { controller.reload(nil) }
            HStack(spacing: 4) {
                FilesPathBar(tab: tab, controller: controller)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(p.fg.opacity(0.10), lineWidth: 1))
            .padding(.leading, 6)
            FilesSearchField(model: model, tab: tab, controller: controller, width: 240, height: 30)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
    }
}

private struct WindowsCommandBar: View {
    @ObservedObject var model: FilesWindowModel
    @ObservedObject var tab: FilesTab
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p

    var body: some View {
        let none = tab.selection.isEmpty
        HStack(spacing: 2) {
            FilesToolButton(symbol: "folder.badge.plus", help: L("Yeni klasör") + "  ⇧⌘N", label: L("Yeni klasör")) {
                controller.newFolder(nil)
            }
            separator
            FilesToolButton(symbol: "doc.on.doc", help: L("Kopyala") + "  ⌘C", enabled: !none) { controller.copy(nil) }
            FilesToolButton(symbol: "doc.on.clipboard", help: L("Yapıştır") + "  ⌘V") { controller.paste(nil) }
            FilesToolButton(symbol: "character.cursor.ibeam", help: L("Yeniden adlandır") + "  ↩",
                            enabled: tab.selection.count == 1) { controller.renameSelection(nil) }
            FilesToolButton(symbol: "trash", help: L("Çöp sepetine taşı") + "  ⌘⌫", enabled: !none) { controller.trashSelection(nil) }
            separator
            FilesToolButton(symbol: "eye", help: L("Quick Look") + "  Space", enabled: !none) { controller.toggleQuickLook(nil) }
            Spacer(minLength: 8)
            FilesToolButton(symbol: model.showHidden ? "eye.slash" : "eye.slash", help: L("Gizli dosyaları göster") + "  ⇧⌘.",
                            label: L("Gizli"), on: model.showHidden) { controller.toggleHidden(nil) }
                .background(RoundedRectangle(cornerRadius: 4).fill(model.showHidden ? p.fg.opacity(0.08) : .clear))
            separator
            FilesModePicker(model: model)
            separator
            FilesToolButton(symbol: "sidebar.right", help: L("Önizleme bölmesi") + "  ⇧⌘P", label: L("Önizleme"),
                            on: model.previewVisible) { controller.togglePreview(nil) }
                .background(RoundedRectangle(cornerRadius: 4).fill(model.previewVisible ? p.fg.opacity(0.08) : .clear))
            FilesToolButton(symbol: "sidebar.left", help: L("Kenar çubuğu") + "  ⌥⌘S", on: model.sidebarVisible) {
                controller.toggleSidebar(nil)
            }
        }
        .padding(.horizontal, 10)
    }

    private var separator: some View {
        Rectangle().fill(p.fg.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 6)
    }
}

/// Yol çubuğu: Disk › Kullanıcılar › ahmet › Belgeler; parçaya tıklayınca oraya gider
/// Boş yere ya da son parçaya tıklayınca (veya ⌘L) Windows'taki gibi yazılabilir adrese döner; sağ tıkta Yolu kopyala.
private struct FilesPathBar: View {
    @ObservedObject var tab: FilesTab
    let controller: FilesWindowController
    var maxParts = 4
    @ObservedObject private var model: FilesWindowModel
    @Environment(\.filesPalette) private var p
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    init(tab: FilesTab, controller: FilesWindowController, maxParts: Int = 4) {
        self.tab = tab
        self.controller = controller
        self.maxParts = maxParts
        model = controller.model
    }

    var body: some View {
        Group {
            if editing { editor } else { crumbs }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.pathEdit) { _ in beginEdit() }
        .onChange(of: tab.url) { _ in editing = false }
        .onChange(of: tab.tag) { _ in editing = false }
    }

    private var editor: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focused)
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: max(3, p.radius - 2), style: .continuous)
                .fill(p.theme == .windows ? Color.clear : p.fg.opacity(0.08)))
            .onSubmit(commit)
            .onExitCommand { endEdit() }
            .onChange(of: focused) { f in if !f { editing = false } }
            .contextMenu { copyButton(tab.url) }
    }

    private func beginEdit() {
        text = tab.url.path
        editing = true
        // Odaklanınca AppKit metnin tamamını seçer (Windows gibi: yazınca yerine geçer)
        DispatchQueue.main.async { focused = true }
    }

    private func endEdit() {
        editing = false
        controller.browser.focus()
    }

    private func commit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !raw.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path) {
            controller.navigate(url)
        } else {
            // Dosya yazıldıysa klasörüne git ve onu seç
            tab.pendingSelect = [url]
            controller.navigate(url.deletingLastPathComponent())
        }
        endEdit()
    }

    private func copyButton(_ url: URL) -> some View {
        Button(L("Yolu kopyala")) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
        }
    }

    @ViewBuilder private var crumbs: some View {
        if let t = tab.tag {
            HStack(spacing: 6) {
                TagDot(tag: t, size: 9)
                Text(t.name).font(.system(size: 12, weight: p.theme != .windows ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 22)
        } else {
            pathCrumbs
        }
    }

    @ViewBuilder private var pathCrumbs: some View {
        let parts = Self.components(tab.url)
        let shown = parts.count > maxParts ? Array(parts.suffix(maxParts)) : parts
        let hidden = parts.count > maxParts ? Array(parts.prefix(parts.count - maxParts)) : []
        HStack(spacing: 2) {
            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden.reversed(), id: \.url) { part in
                        Button(part.name) { controller.navigate(part.url) }
                    }
                } label: {
                    Text("…").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                chevron
            }
            ForEach(Array(shown.enumerated()), id: \.element.url) { i, part in
                let last = i == shown.count - 1
                Button { if last { beginEdit() } else { controller.navigate(part.url) } } label: {
                    HStack(spacing: 4) {
                        if i == 0 && hidden.isEmpty {
                            Image(nsImage: FileIcons.shared.icon(part.url)).resizable().frame(width: 14, height: 14)
                        }
                        Text(part.name)
                            .font(.system(size: 12, weight: last && p.theme != .windows ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ToolButtonStyle())
                .foregroundStyle(p.fg.opacity(last ? 1 : (p.theme == .windows ? 0.85 : 0.6)))
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    let dest = part.url
                    loadFileURLs(providers) { urls in controller.drop(urls, into: dest) }
                    return true
                }
                .contextMenu {
                    copyButton(part.url)
                    Button(L("Yolu düzenle")) { beginEdit() }
                    Divider()
                    Button(L("Yeni sekmede aç")) { controller.navigate(part.url, newTab: true) }
                }
                if !last { chevron }
            }
            // Boş yere tıklayınca adres yazılabilir olur
            Color.clear
                .frame(minWidth: 16, maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
                .onTapGesture { beginEdit() }
                .contextMenu {
                    copyButton(tab.url)
                    Button(L("Yolu düzenle")) { beginEdit() }
                }
                .help(L("Adresi yazmak için tıkla") + "  ⌘L")
        }
        .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: p.theme == .windows ? "chevron.right" : "chevron.compact.right")
            .font(.system(size: p.theme == .windows ? 8.5 : 10, weight: .semibold))
            .foregroundStyle(p.fg.opacity(p.theme == .windows ? 0.5 : 0.3))
    }

    struct Part { let url: URL; let name: String }

    static func components(_ url: URL) -> [Part] {
        var parts: [Part] = []
        var u = url.standardizedFileURL
        let fm = FileManager.default
        while true {
            let isRoot = u.path == "/"
            let isVolume = (try? u.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            let name = isRoot ? (FilesPlaces.shared.volumes.first { $0.url.path == "/" }?.title ?? "/") : fm.displayName(atPath: u.path)
            parts.insert(Part(url: u, name: name), at: 0)
            if isRoot || isVolume { break }
            let parent = u.deletingLastPathComponent()
            if parent.path == u.path { break }
            u = parent
        }
        return parts
    }
}

// MARK: Kenar çubuğu

private struct FilesSidebar: View {
    @ObservedObject var tab: FilesTab
    @ObservedObject var places = FilesPlaces.shared
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: p.theme == .windows ? 0 : 1) {
                let favs = places.shownFavorites
                if !favs.isEmpty {
                    section(L("Sık kullanılanlar"))
                    ForEach(favs) { row($0, removable: places.isFinderFavorite($0.url)) }
                }
                if !places.pinned.isEmpty {
                    section(L("Sabitlenenler"))
                    ForEach(places.pinned) { row($0, removable: true) }
                }
                let locs = places.shownLocations
                if !locs.isEmpty {
                    section(L("Konumlar"))
                    ForEach(locs) { row($0) }
                }
                let tags = places.shownTags
                if !tags.isEmpty {
                    section(L("Etiketler"))
                    ForEach(tags) { t in
                        TagRow(tag: t, selected: tab.tag == t, controller: controller)
                    }
                }
            }
            .padding(.horizontal, p.theme == .windows ? 4 : 8)
            .padding(.vertical, 8)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            // Boş yere bırakılan klasörler sık kullanılanlara eklenir (Finder'a da gider)
            loadFileURLs(providers) { urls in
                for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    FilesPlaces.shared.pin(u)
                }
            }
            return true
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: p.theme == .finder ? 11 : 10.5, weight: p.theme == .finder ? .semibold : .bold))
            .foregroundStyle(p.fg.opacity(p.theme == .finder ? 0.45 : 0.4))
            .padding(.leading, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private func row(_ place: SidebarPlace, removable: Bool = false) -> some View {
        SidebarRow(place: place, selected: tab.tag == nil && place.special != .airdrop && place.special != .network
                   && tab.url.fileKey == place.url.fileKey, removable: removable,
                   controller: controller)
    }
}

private struct SidebarRow: View {
    let place: SidebarPlace
    let selected: Bool
    let removable: Bool
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p
    @State private var hover = false
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: place.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(iconColor)
            Text(place.title)
                .font(.system(size: 12.5, weight: selected && p.theme != .finder ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if place.ejectable {
                Button { FilesPlaces.shared.eject(place, window: controller.window) } label: {
                    Image(systemName: "eject.fill").font(.system(size: 9.5)).foregroundStyle(p.fg.opacity(0.5))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Çıkar"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: p.theme == .windows ? 30 : 26)
        .background(background)
        .overlay(alignment: .leading) {
            if selected && p.theme == .windows {
                Capsule().fill(p.accent).frame(width: 3, height: 16)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { FilesPlaces.shared.open(place, in: controller) }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            // AirDrop / Ağ klasör değil; Çöp Sepeti'ne bırakmak çöpe atmak demek
            guard place.special != .airdrop, place.special != .network else { return false }
            let dest = place.url
            loadFileURLs(providers) { urls in controller.drop(urls, into: dest) }
            return true
        }
        .help(place.url.path)
        .contextMenu {
            if place.special == nil || place.special == .trash {
                Button(L("Yeni sekmede aç")) { FilesPlaces.shared.open(place, in: controller, newTab: true) }
                if place.special == nil {
                    Button(L("Yeni pencerede aç")) { FilesManager.shared.open(place.url, newWindow: true) }
                }
            }
            Button(L("Finder'da göster")) { NSWorkspace.shared.open(place.url) }
            if removable {
                Divider()
                Button(L("Kenar çubuğundan kaldır")) { FilesPlaces.shared.unpin(place.url) }
            }
            if place.ejectable {
                Divider()
                Button(L("Çıkar")) { FilesPlaces.shared.eject(place, window: controller.window) }
            }
            Divider()
            if let key = place.hideKey {
                Button(L("Kenar çubuğundan gizle")) { FilesPlaces.shared.setVisible(key, false) }
            }
            Button(L("Kenar çubuğu ayarları…")) { FilesSettingsWindow.shared.show(tab: .sidebar) }
        }
    }

    private var iconColor: Color {
        switch p.theme {
        case .missing: return selected ? p.accent : p.fg.opacity(0.7)
        case .finder: return p.accent
        case .windows: return selected ? p.fg.opacity(0.95) : p.fg.opacity(0.75)
        case .glass: return selected ? .white : .white.opacity(0.75)
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, p.radius - 1), style: .continuous)
        if dropTarget {
            shape.fill(p.accent.opacity(0.45))
        } else {
            switch p.theme {
            case .glass:
                shape.fill(.white.opacity(selected ? 0.18 : (hover ? 0.07 : 0)))
                    .overlay(shape.strokeBorder(.white.opacity(selected ? 0.28 : 0), lineWidth: 1))
            case .finder:
                shape.fill(p.fg.opacity(selected ? (p.dark ? 0.14 : 0.10) : (hover ? 0.04 : 0)))
            case .windows:
                shape.fill(p.fg.opacity(selected ? (p.dark ? 0.09 : 0.06) : (hover ? 0.04 : 0)))
            case .missing:
                shape.fill(p.fg.opacity(selected ? 0.13 : (hover ? 0.06 : 0)))
            }
        }
    }
}

// MARK: Durum çubuğu

private struct FilesStatusBar: View {
    @ObservedObject var tab: FilesTab
    @ObservedObject var activity: FilesActivity
    /// Verilirse (Finder teması) solda yol çubuğu gösterilir
    var controller: FilesWindowController? = nil
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 6) {
            if let controller {
                FilesPathBar(tab: tab, controller: controller, maxParts: 6)
                    .font(.system(size: 11))
                    .scaleEffect(0.92, anchor: .leading)
                Spacer(minLength: 8)
            }
            if activity.copying > 0 {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(L("Kopyalanıyor…"))
                Text("·").foregroundStyle(p.fg.opacity(0.3))
            }
            if tab.searching {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            }
            Text(countText)
            if tab.deepSearch {
                Text("·").foregroundStyle(p.fg.opacity(0.3))
                Text(L("alt klasörler dahil"))
            }
            if let free = tab.freeSpace {
                Text("·").foregroundStyle(p.fg.opacity(0.3))
                Text(L("%@ boş", FilesFormat.size(free)))
            }
            if controller == nil { Spacer() }
        }
        .font(.system(size: 11))
        .foregroundStyle(p.fg.opacity(0.5))
        .padding(.horizontal, 12)
    }

    private var countText: String {
        let n = tab.items.count
        let s = tab.selection.count
        let base = tab.filter.isEmpty ? L("%d öğe", n) : (tab.deepSearch ? L("%d sonuç", n) : L("%d / %d öğe", n, tab.totalCount))
        return s > 0 ? L("%d seçili", s) + " · " + base : base
    }
}

// MARK: Önizleme bölmesi

/// Sağdaki önizleme: tek dosya seçiliyse Quick Look görünümü ve bilgileri
private struct FilesPreviewPane: View {
    @ObservedObject var tab: FilesTab
    @Environment(\.filesPalette) private var p

    var body: some View {
        let sel = tab.selection
        Group {
            if sel.count == 1, let item = tab.items.first(where: { $0.url.fileKey == sel[0].fileKey }) ?? FileItem(url: sel[0]) {
                VStack(spacing: 0) {
                    if item.opensAsFolder || item.isApp {
                        Image(nsImage: FileIcons.shared.icon(item.url)).resizable().scaledToFit()
                            .frame(width: 128, height: 128)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        QuickLookView(url: item.url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    info(item)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: sel.count > 1 ? "square.on.square" : "eye")
                        .font(.system(size: 26)).foregroundStyle(p.fg.opacity(0.3))
                    Text(sel.count > 1 ? L("%d öğe seçili", sel.count) : L("Önizlemek için bir dosya seç"))
                        .font(.system(size: 12)).foregroundStyle(p.fg.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func info(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .truncationMode(.middle)
            Text(item.kind).font(.system(size: 11)).foregroundStyle(p.fg.opacity(0.55))
            Rectangle().fill(p.divider).frame(height: 1).padding(.vertical, 2)
            if let s = item.size { row(L("Boyut"), FilesFormat.size(s)) }
            if let m = item.modified { row(L("Değiştirilme tarihi"), FilesFormat.date.string(from: m)) }
            if let rel = tab.relativeFolder(of: item) { row(L("Konum"), rel) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(p.fg.opacity(0.5))
            Spacer(minLength: 8)
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
    }
}

/// Quick Look'un gömülü önizlemesi (resim, PDF, video, metin…)
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.autostarts = true
        v.shouldCloseWithWindow = false
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem?.previewItemURL).map({ $0 != url }) ?? true { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

// MARK: Etiket satırı

private struct TagRow: View {
    let tag: FinderTag
    let selected: Bool
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            TagDot(tag: tag, size: 10).frame(width: 18)
            Text(tag.name)
                .font(.system(size: 12.5, weight: selected && p.theme != .finder ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: p.theme == .windows ? 30 : 26)
        .background(RoundedRectangle(cornerRadius: max(4, p.radius - 1), style: .continuous)
            .fill(p.fg.opacity(selected ? (p.dark ? 0.14 : 0.10) : (hover ? 0.05 : 0))))
        .overlay(alignment: .leading) {
            if selected && p.theme == .windows {
                Capsule().fill(p.accent).frame(width: 3, height: 16)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { controller.showTag(tag) }
        .contextMenu {
            Button(L("Yeni sekmede aç")) { controller.showTag(tag, newTab: true) }
            Divider()
            Button(L("Kenar çubuğundan gizle")) { FilesPlaces.shared.setVisible(FilesPlaces.tagKey(tag), false) }
            Button(L("Etiketleri gizle")) { FilesPlaces.shared.setVisible("tags", false) }
            Button(L("Kenar çubuğu ayarları…")) { FilesSettingsWindow.shared.show(tab: .sidebar) }
        }
    }
}

/// Etiketin rengi; renksiz etiket için boş halka
struct TagDot: View {
    let tag: FinderTag
    var size: CGFloat = 10

    var body: some View {
        if let c = tag.color {
            Circle().fill(c).frame(width: size, height: size)
        } else {
            Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: size, height: size)
        }
    }
}
