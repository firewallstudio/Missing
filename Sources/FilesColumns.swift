import Cocoa

// MARK: - Sütunlar görünümü (Finder'daki gibi)
//
// Her klasör bir sütun; seçilen klasörün içi hemen sağında açılır. Sütunlar Files'ın kendi satırlarını
// kullanır, böylece dört temada da aynı görünür. Sekmenin adresi, seçimin bulunduğu sütunun klasörüdür:
// yol çubuğu, yeni klasör, yapıştır ve durum çubuğu oraya göre çalışır.

@MainActor final class FilesColumnsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var browser: FilesBrowser?
    /// Kullanıcı bir sütunda seçim yaptı: (o sütunun klasörü, seçilenler)
    var onSelect: (URL, [URL]) -> Void = { _, _ in }
    var itemMenu: NSMenu?

    final class Column {
        let dir: URL
        var items: [FileItem] = []
        let table = FilesColumnTable()
        let scroll = NSScrollView()
        var generation = 0
        init(dir: URL) { self.dir = dir }
    }

    private(set) var columns: [Column] = []
    private let hScroll = NSScrollView()
    private let doc = FilesColumnsDocument()
    private var syncing = false
    private var showHidden = FilesSettings.showHidden
    /// Klavyenin çalıştığı sütun
    private(set) var active = 0

    static let width: CGFloat = 240
    private static let colID = NSUserInterfaceItemIdentifier("column")

    override init(frame: NSRect) {
        super.init(frame: frame)
        hScroll.documentView = doc
        hScroll.hasHorizontalScroller = true
        hScroll.hasVerticalScroller = false
        hScroll.autohidesScrollers = true
        hScroll.scrollerStyle = .overlay
        hScroll.drawsBackground = false
        hScroll.contentView.drawsBackground = false
        addSubview(hScroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        hScroll.frame = bounds
        layoutColumns()
    }

    private func layoutColumns() {
        let h = hScroll.contentSize.height
        let w = max(CGFloat(columns.count) * Self.width, hScroll.contentSize.width)
        doc.frame = NSRect(x: 0, y: 0, width: w, height: h)
        doc.columnCount = columns.count
        for (i, c) in columns.enumerated() {
            c.scroll.frame = NSRect(x: CGFloat(i) * Self.width, y: 0, width: Self.width - 1, height: h)
        }
        doc.needsDisplay = true
    }

    private func scrollToEnd() {
        layoutColumns()
        guard let last = columns.last else { return }
        doc.scrollToVisible(last.scroll.frame)
    }

    // MARK: Sekmeyle eşitleme

    /// Sekmenin klasörü ve içeriği değişti (yükleme, yenileme, başka yere gitme)
    func update(dir: URL, items: [FileItem], hidden: Bool) {
        if hidden != showHidden {
            showHidden = hidden
            removeColumns(after: -1)
        }
        let sorted = Self.sort(items)
        if let k = index(of: dir) {
            let c = columns[k]
            if c.items.map(\.url.fileKey) != sorted.map(\.url.fileKey) {
                let keep = selectedURLs(in: k)
                c.items = sorted
                reload(c, select: keep)
            }
        } else {
            rebuild(to: dir, items: sorted)
        }
    }

    /// Sekmenin klasöründeki seçim (dışarıdan: geri gelince, yeni klasör, yapıştırma…)
    func select(_ urls: [URL], in dir: URL, scroll: Bool) {
        guard let k = index(of: dir) else { return }
        let c = columns[k]
        let set = Set(urls.map(\.fileKey))
        let idx = IndexSet(c.items.indices.filter { set.contains(c.items[$0].url.fileKey) })
        syncing = true
        c.table.selectRowIndexes(idx, byExtendingSelection: false)
        syncing = false
        if scroll, let f = idx.first { c.table.scrollRowToVisible(f) }
        active = k
        openChild(of: k)
    }

    /// Sekmenin klasöründe seçili olanlar
    func selectedItems(in dir: URL) -> [FileItem] {
        guard let k = index(of: dir) else { return [] }
        let c = columns[k]
        return c.table.selectedRowIndexes.compactMap { c.items.indices.contains($0) ? c.items[$0] : nil }
    }

    private func selectedURLs(in k: Int) -> [URL] {
        let c = columns[k]
        return c.table.selectedRowIndexes.compactMap { c.items.indices.contains($0) ? c.items[$0].url : nil }
    }

    func focus() {
        guard !columns.isEmpty else { return }
        window?.makeFirstResponder(columns[min(active, columns.count - 1)].table)
    }

    func screenFrame(of url: URL, in dir: URL) -> NSRect? {
        guard let k = index(of: dir), let window else { return nil }
        let c = columns[k]
        guard let i = c.items.firstIndex(where: { $0.url.fileKey == url.fileKey }) else { return nil }
        let row = c.table.rect(ofRow: i)
        let r = c.table.convert(NSRect(x: row.minX + 6, y: row.minY + 2, width: 20, height: 20), to: nil)
        return window.convertToScreen(r)
    }

    func forwardKey(_ e: NSEvent) -> Bool {
        guard [123, 124, 125, 126].contains(e.keyCode), !columns.isEmpty else { return false }
        columns[min(active, columns.count - 1)].table.keyDown(with: e)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLook()
        for c in columns { c.table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<c.table.numberOfRows), columnIndexes: [0]) }
    }

    func refreshLook() {
        let p = FilesPalette.current(for: window?.appearance ?? effectiveAppearance)
        for c in columns {
            c.table.rowHeight = p.rowHeight
            c.table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true; (row as? FilesRowView)?.refreshStyle() }
        }
        doc.needsDisplay = true
    }

    private func index(of dir: URL) -> Int? {
        let key = dir.fileKey
        return columns.firstIndex { $0.dir.fileKey == key }
    }

    // MARK: Sütun kurma

    /// Klasör önceki kökün içindeyse zincir korunur; değilse bir üst klasörden başlar (Finder'daki gibi)
    private func rebuild(to dir: URL, items: [FileItem]) {
        let target = URL(fileURLWithPath: dir.standardizedFileURL.path)
        var root: URL
        if let first = columns.first?.dir, first.fileKey != target.fileKey,
           target.path.hasPrefix(first.path == "/" ? "/" : first.path + "/") {
            root = first
        } else {
            let isVolume = (try? target.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            root = (target.path == "/" || isVolume) ? target : target.deletingLastPathComponent()
        }
        var chain = [target]
        var cur = target
        while cur.fileKey != root.fileKey, cur.path != "/" {
            cur = cur.deletingLastPathComponent()
            chain.insert(cur, at: 0)
        }
        if chain.first?.fileKey != root.fileKey { chain = [target]; root = target }
        removeColumns(after: -1)
        for (i, d) in chain.enumerated() {
            let c = addColumn(d)
            let next = i + 1 < chain.count ? chain[i + 1] : nil
            if d.fileKey == target.fileKey {
                c.items = items
                reload(c, select: [])
            } else {
                load(c, select: next)
            }
        }
        active = chain.count - 1
        scrollToEnd()
    }

    @discardableResult
    private func addColumn(_ dir: URL) -> Column {
        let c = Column(dir: dir)
        let t = c.table
        t.owner = self
        let col = NSTableColumn(identifier: Self.colID)
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.headerView = nil
        t.style = .fullWidth
        t.rowHeight = FilesPalette.current(for: window?.appearance ?? effectiveAppearance).rowHeight
        t.intercellSpacing = NSSize(width: 0, height: 0)
        t.backgroundColor = .clear
        t.allowsMultipleSelection = true
        t.allowsEmptySelection = true
        t.allowsTypeSelect = true
        t.focusRingType = .none
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(doubleClicked(_:))
        t.registerForDraggedTypes([.fileURL])
        t.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        t.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        t.menu = itemMenu
        c.scroll.documentView = t
        c.scroll.hasVerticalScroller = true
        c.scroll.autohidesScrollers = true
        c.scroll.drawsBackground = false
        c.scroll.scrollerStyle = .overlay
        c.scroll.contentView.drawsBackground = false
        doc.addSubview(c.scroll)
        columns.append(c)
        layoutColumns()
        col.width = Self.width - 1
        return c
    }

    private func removeColumns(after k: Int) {
        guard columns.count > k + 1 else { return }
        for c in columns[(k + 1)...] {
            c.generation += 1
            c.scroll.removeFromSuperview()
        }
        columns.removeLast(columns.count - (k + 1))
        layoutColumns()
    }

    /// Sütunun içeriğini arka planda oku; gelince `select` seçilir (zincirdeki bir sonraki klasör)
    private func load(_ c: Column, select next: URL?) {
        c.generation += 1
        let gen = c.generation
        DirectoryLoader.load(c.dir, showHidden: showHidden) { [weak self, weak c] r in
            guard let self, let c, c.generation == gen else { return }
            c.items = Self.sort((try? r.get()) ?? [])
            self.reload(c, select: next.map { [$0] } ?? [])
            if let next, let i = c.items.firstIndex(where: { $0.url.fileKey == next.fileKey }) {
                c.table.scrollRowToVisible(i)
            }
        }
    }

    private func reload(_ c: Column, select urls: [URL]) {
        syncing = true
        c.table.reloadData()
        let set = Set(urls.map(\.fileKey))
        c.table.selectRowIndexes(IndexSet(c.items.indices.filter { set.contains(c.items[$0].url.fileKey) }),
                                 byExtendingSelection: false)
        syncing = false
    }

    /// Finder gibi: ada göre, klasörler ve dosyalar karışık
    private static func sort(_ items: [FileItem]) -> [FileItem] {
        items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Sütun k'de tek klasör seçiliyse içi sağında açılsın; değilse sağdaki sütunlar kapansın
    private func openChild(of k: Int) {
        let sel = columns[k].table.selectedRowIndexes.compactMap { columns[k].items.indices.contains($0) ? columns[k].items[$0] : nil }
        if sel.count == 1, sel[0].opensAsFolder {
            let target = sel[0].folderTarget
            if columns.count > k + 1, columns[k + 1].dir.fileKey == target.fileKey {
                removeColumns(after: k + 1)
                let next = columns[k + 1]
                syncing = true
                next.table.deselectAll(nil)
                syncing = false
            } else {
                removeColumns(after: k)
                load(addColumn(target), select: nil)
            }
        } else {
            removeColumns(after: k)
        }
        scrollToEnd()
    }

    // MARK: Kullanıcının seçimi

    fileprivate func userSelected(in table: NSTableView) {
        guard let k = columns.firstIndex(where: { $0.table === table }) else { return }
        active = k
        openChild(of: k)
        onSelect(columns[k].dir, selectedURLs(in: k))
    }

    /// ← bir üst sütuna, → seçili klasörün içine
    fileprivate func moveLeft(from table: NSTableView) {
        guard let k = columns.firstIndex(where: { $0.table === table }), k > 0 else { return }
        syncing = true
        table.deselectAll(nil)
        syncing = false
        removeColumns(after: k)
        active = k - 1
        window?.makeFirstResponder(columns[k - 1].table)
        onSelect(columns[k - 1].dir, selectedURLs(in: k - 1))
    }

    fileprivate func moveRight(from table: NSTableView) {
        guard let k = columns.firstIndex(where: { $0.table === table }), k + 1 < columns.count else { return }
        let next = columns[k + 1]
        guard !next.items.isEmpty else { return }
        window?.makeFirstResponder(next.table)
        next.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)   // seçim değişikliği bildirir
        next.table.scrollRowToVisible(0)
    }

    /// Sağ tık: tıklanan satır seçili değilse onu seç
    fileprivate func contextClick(in table: NSTableView, row: Int) {
        guard let k = columns.firstIndex(where: { $0.table === table }) else { return }
        if row < 0 {
            syncing = true
            table.deselectAll(nil)
            syncing = false
        } else if !table.selectedRowIndexes.contains(row) {
            syncing = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            syncing = false
        }
        active = k
        openChild(of: k)
        onSelect(columns[k].dir, selectedURLs(in: k))
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        browser?.openSelected()
    }

    // MARK: Tablo verisi

    private func column(for tv: NSTableView) -> Column? { columns.first { $0.table === tv } }

    func numberOfRows(in tv: NSTableView) -> Int { column(for: tv)?.items.count ?? 0 }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let c = column(for: tv), c.items.indices.contains(row) else { return nil }
        let item = c.items[row]
        let cell = (tv.makeView(withIdentifier: Self.colID, owner: nil) as? FilesColumnCell) ?? FilesColumnCell()
        cell.identifier = Self.colID
        cell.textField?.stringValue = item.name
        cell.imageView?.image = FileIcons.shared.icon(item.url)
        cell.arrow.isHidden = !item.opensAsFolder
        cell.alphaValue = item.isHidden ? 0.5 : 1
        return cell
    }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FilesRowView() }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !syncing, let tv = n.object as? NSTableView else { return }
        userSelected(in: tv)
    }

    func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
        guard let c = column(for: tv), c.items.indices.contains(row) else { return nil }
        return c.items[row].name
    }

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let c = column(for: tv), c.items.indices.contains(row) else { return nil }
        return c.items[row].url as NSURL
    }

    /// Klasör satırına bırakınca içine; boş yere bırakınca sütunun klasörüne
    private func dropTarget(_ c: Column, row: Int, op: NSTableView.DropOperation) -> URL? {
        if op == .on, c.items.indices.contains(row), c.items[row].opensAsFolder { return c.items[row].folderTarget }
        return nil
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let c = column(for: tv), let browser else { return [] }
        let dest = dropTarget(c, row: row, op: op)
        if dest == nil { tv.setDropRow(-1, dropOperation: .on) }
        return browser.dragOperation(info, dest: dest ?? c.dir)
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let c = column(for: tv), let browser else { return false }
        return browser.performDrop(info, dest: dropTarget(c, row: row, op: op) ?? c.dir)
    }
}

/// Sütunların taşıyıcısı: aralarına ince çizgi
final class FilesColumnsDocument: NSView {
    var columnCount = 0
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = FilesPalette.current(for: effectiveAppearance)
        p.nsFG.withAlphaComponent(p.dark ? 0.10 : 0.08).setFill()
        for i in 1...max(1, columnCount) {
            let x = CGFloat(i) * FilesColumnsView.width - 1
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

final class FilesColumnTable: FilesHoverTable {
    weak var owner: FilesColumnsView?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 123 where mods.isEmpty: owner?.moveLeft(from: self)
        case 124 where mods.isEmpty: owner?.moveRight(from: self)
        case 36 where mods.isEmpty, 76 where mods.isEmpty:   // Return: yeniden adlandır
            if selectedRowIndexes.count == 1 { owner?.browser?.owner?.renameSelection(nil) } else { NSSound.beep() }
        case 49 where mods.isEmpty:   // Boşluk: Quick Look
            owner?.browser?.owner?.toggleQuickLook(nil)
        default:
            super.keyDown(with: e)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let before = selectedRowIndexes
        super.mouseDown(with: event)
        // Zaten seçili klasöre yeniden tıklayınca seçim bu sütuna döner (sağdaki seçim kalkar)
        if selectedRowIndexes == before, clickedRow >= 0 { owner?.userSelected(in: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        owner?.contextClick(in: self, row: row(at: p))
        guard let m = super.menu(for: event), let browser = owner?.browser else { return nil }
        browser.showContextMenu(m, event: event)
        return nil
    }
}

/// Simge, ad ve klasörse sağda ok
final class FilesColumnCell: NSTableCellView {
    let arrow = FilesIconView()

    init() {
        super.init(frame: .zero)
        let i = FilesIconView()
        i.imageScaling = .scaleProportionallyUpOrDown
        i.translatesAutoresizingMaskIntoConstraints = false
        addSubview(i)
        imageView = i
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 12.5)
        t.lineBreakMode = .byTruncatingMiddle
        t.translatesAutoresizingMaskIntoConstraints = false
        addSubview(t)
        textField = t
        arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        arrow.contentTintColor = .secondaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrow)
        NSLayoutConstraint.activate([
            i.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            i.centerYAnchor.constraint(equalTo: centerYAnchor),
            i.widthAnchor.constraint(equalToConstant: 18),
            i.heightAnchor.constraint(equalToConstant: 18),
            t.leadingAnchor.constraint(equalTo: i.trailingAnchor, constant: 6),
            t.centerYAnchor.constraint(equalTo: centerYAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -4),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { arrow.contentTintColor = backgroundStyle == .emphasized ? .white.withAlphaComponent(0.85) : .secondaryLabelColor }
    }
}
