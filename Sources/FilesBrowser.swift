import Cocoa
import Combine
import Quartz

// MARK: - Dosya görünümü (liste + simgeler)
//
// AppKit ile: çoklu seçim, klavye, yazarak seçme, sürükle-bırak ve yerinde yeniden adlandırma
// SwiftUI'dakinden çok daha sağlam. Pencere (FilesWindowController) eylemleri yönetir; burası sadece gösterir.

@MainActor final class FilesBrowser: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                     NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    weak var owner: FilesWindowController?
    private(set) var tab: FilesTab?
    private(set) var mode: FilesViewMode = .list
    private(set) var items: [FileItem] = []
    /// Tarihe göre gruplanmışsa başlıklar ve her başlığın öğe aralığı (items bu sıradadır)
    private var groups: [(title: String, range: Range<Int>)] = []
    /// Liste satırı → öğe sırası (başlık satırında -1)
    private var rowItem: [Int] = []
    /// Öğe sırası → liste satırı
    private var itemRow: [Int] = []
    private var bag = Set<AnyCancellable>()
    private var zoomSub: AnyCancellable?
    private var thumbBucket = FilesGridZoom.shared.thumbSize
    private var syncing = false

    private let listScroll = NSScrollView()
    private let table = FilesTableView()
    private let gridScroll = NSScrollView()
    private let grid = FilesCollectionView()
    private let menuForItems = NSMenu()
    private let columnsView = FilesColumnsView()

    private static let colName = NSUserInterfaceItemIdentifier("name")
    private static let colDate = NSUserInterfaceItemIdentifier("modified")
    private static let colAdded = NSUserInterfaceItemIdentifier("added")
    private static let colSize = NSUserInterfaceItemIdentifier("size")
    private static let colKind = NSUserInterfaceItemIdentifier("kind")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTable()
        setupGrid()
        menuForItems.delegate = self
        table.menu = menuForItems
        grid.menu = menuForItems
        addSubview(listScroll)
        addSubview(gridScroll)
        gridScroll.isHidden = true
        columnsView.browser = self
        columnsView.itemMenu = menuForItems
        columnsView.onSelect = { [weak self] dir, urls in self?.columnSelected(dir, urls) }
        addSubview(columnsView)
        columnsView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        listScroll.frame = bounds
        gridScroll.frame = bounds
        columnsView.frame = bounds
    }

    // MARK: Kurulum

    private func setupTable() {
        table.owner = self
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, key: FilesSortKey,
                    ascending: Bool = true) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: ascending)
            return c
        }
        let name = column(Self.colName, L("Ad"), width: 320, min: 160, key: .name)
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(name)
        table.addTableColumn(column(Self.colDate, L("Değiştirilme tarihi"), width: 170, min: 90, key: .modified, ascending: false))
        table.addTableColumn(column(Self.colAdded, L("Eklenme tarihi"), width: 160, min: 90, key: .added, ascending: false))
        let size = column(Self.colSize, L("Boyut"), width: 80, min: 50, key: .size, ascending: false)
        size.headerCell.alignment = .right
        table.addTableColumn(size)
        table.addTableColumn(column(Self.colKind, L("Tür"), width: 150, min: 60, key: .kind))
        table.autosaveName = "MissingFilesColumns"
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: FilesSortKey.name.rawValue, ascending: true)]
        table.floatsGroupRows = false

        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.scrollerStyle = .overlay
        listScroll.contentView.drawsBackground = false
    }

    private func setupGrid() {
        grid.owner = self
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = FilesGridZoom.shared.itemSize
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(FilesGridItem.self, forItemWithIdentifier: FilesGridItem.id)
        grid.register(FilesGridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: FilesGridHeader.id)
        grid.register(FilesGridGap.self, forSupplementaryViewOfKind: NSCollectionView.elementKindInterItemGapIndicator,
                      withIdentifier: FilesGridGap.id)
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)

        gridScroll.documentView = grid
        zoomSub = FilesGridZoom.shared.$size.dropFirst().sink { [weak self] v in self?.applyZoom(v) }
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = false
        gridScroll.scrollerStyle = .overlay
        gridScroll.contentView.drawsBackground = false
    }

    // MARK: Gösterilen sekme

    func show(_ t: FilesTab) {
        guard t !== tab else { return }
        tab.map { saveScroll(of: $0) }
        tab = t
        bag.removeAll()
        syncSortHeader()
        // @Published yeni değeri atamadan önce yayar: değeri doğrudan kullan
        t.$items.sink { [weak self] new in self?.update(new, restoreScroll: false) }.store(in: &bag)
        update(t.items, restoreScroll: true)
    }

    /// Tema değişince satır yüksekliği, seçim renkleri ve köşeler
    func applyTheme() {
        let p = FilesPalette.current(for: window?.appearance ?? effectiveAppearance)
        table.rowHeight = p.rowHeight
        table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true; (row as? FilesRowView)?.refreshStyle() }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        for case let item as FilesGridItem in grid.visibleItems() { item.refreshLook() }
        columnsView.refreshLook()
        // Cam temasında içerik kartın üst köşelerine uysun
        wantsLayer = true
        layer?.cornerRadius = p.theme == .glass ? 14 : 0
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = p.theme == .glass
    }

    func setMode(_ m: FilesViewMode) {
        let sel = selectedURLs
        mode = m
        listScroll.isHidden = m != .list
        gridScroll.isHidden = m != .grid
        columnsView.isHidden = m != .columns
        reloadViews()
        select(sel, scroll: true)
        if sel.isEmpty { scrollToTop() }
        focus()
    }

    private func saveScroll(of t: FilesTab) {
        guard mode != .columns else { return }
        t.scrollY = (mode == .list ? listScroll : gridScroll).contentView.bounds.origin.y
    }

    private func update(_ new: [FileItem], restoreScroll: Bool) {
        guard let tab else { return }
        let keep = tab.pendingSelect ?? (restoreScroll ? tab.selection : selectedURLs)
        let navigated = items.first.map { $0.url.deletingLastPathComponent().fileKey != tab.url.fileKey } ?? true
        setItems(new, grouped: tab.grouped)
        syncSortHeader()
        reloadViews()
        let newKeys = Set(new.map(\.url.fileKey))
        let toSelect = keep.filter { newKeys.contains($0.fileKey) }
        select(toSelect, scroll: tab.pendingSelect != nil)
        if tab.pendingSelect != nil, tab.loaded { tab.pendingSelect = nil }
        if restoreScroll {
            if let y = tab.scrollY { scroll(to: y) } else { scrollToTop() }
        } else if navigated && toSelect.isEmpty {
            scrollToTop()
        }
        if let r = tab.pendingRename, newKeys.contains(r.fileKey) {
            tab.pendingRename = nil
            DispatchQueue.main.async { self.beginRename(r) }
        }
    }

    /// Gruplu ise öğeleri başlık sırasına dizer ve satır eşlemelerini kurar
    private func setItems(_ new: [FileItem], grouped: Bool) {
        guard grouped, let tab, !new.isEmpty else {
            items = new
            groups = []
            rowItem = Array(new.indices)
            itemRow = Array(new.indices)
            return
        }
        let g = FilesDateGroups.group(new, by: tab.sortKey, ascending: tab.ascending)
        var ordered: [FileItem] = []
        ordered.reserveCapacity(new.count)
        groups = []
        for x in g {
            let start = ordered.count
            ordered.append(contentsOf: x.indices.map { new[$0] })
            groups.append((x.title, start..<ordered.count))
        }
        items = ordered
        rowItem = []
        itemRow = Array(repeating: 0, count: ordered.count)
        for x in groups {
            rowItem.append(-1)
            for i in x.range {
                itemRow[i] = rowItem.count
                rowItem.append(i)
            }
        }
    }

    /// Liste başlığındaki sıralama oku ve "Eklenme tarihi" sütunu sekmenin sıralamasına uysun
    private func syncSortHeader() {
        guard let tab else { return }
        let d = table.sortDescriptors.first
        syncing = true
        if d?.key != tab.sortKey.rawValue || d?.ascending != tab.ascending {
            table.sortDescriptors = [NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.ascending)]
        }
        if let c = table.tableColumn(withIdentifier: Self.colAdded) {
            let hide = tab.sortKey != .added
            if c.isHidden != hide { c.isHidden = hide }
        }
        syncing = false
    }

    private func item(atRow row: Int) -> FileItem? {
        guard rowItem.indices.contains(row) else { return nil }
        let i = rowItem[row]
        return i >= 0 ? items[i] : nil
    }

    private func itemIndex(atRow row: Int) -> Int? {
        guard rowItem.indices.contains(row), rowItem[row] >= 0 else { return nil }
        return rowItem[row]
    }

    /// Simgelerde: IndexPath ↔ öğe sırası
    func itemIndex(of ip: IndexPath) -> Int? {
        let i: Int
        if groups.isEmpty {
            guard ip.section == 0 else { return nil }
            i = ip.item
        } else {
            guard groups.indices.contains(ip.section) else { return nil }
            i = groups[ip.section].range.lowerBound + ip.item
            guard groups[ip.section].range.contains(i) else { return nil }
        }
        return items.indices.contains(i) ? i : nil
    }

    func indexPath(ofItem i: Int) -> IndexPath {
        guard !groups.isEmpty else { return IndexPath(item: i, section: 0) }
        for (s, g) in groups.enumerated() where g.range.contains(i) {
            return IndexPath(item: i - g.range.lowerBound, section: s)
        }
        return IndexPath(item: i, section: 0)
    }

    var itemCount: Int { items.count }

    private func scroll(to y: CGFloat) {
        guard mode != .columns else { return }
        let s = mode == .list ? listScroll : gridScroll
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
    }

    /// En üst: liste başlığı kaydırma alanının üstünde yüzer, payı içerik boşluğundadır
    private func scrollToTop() {
        guard mode != .columns else { return }
        let s = mode == .list ? listScroll : gridScroll
        scroll(to: -s.contentView.contentInsets.top)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window, w.firstResponder === w { focus() }
    }

    private func reloadViews() {
        syncing = true
        switch mode {
        case .list: table.reloadData()
        case .grid:
            if let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.headerReferenceSize = groups.isEmpty ? .zero : NSSize(width: 0, height: 36)
                layout.sectionInset = NSEdgeInsets(top: groups.isEmpty ? 12 : 2, left: 12, bottom: 12, right: 12)
            }
            grid.reloadData()
        case .columns:
            if let tab { columnsView.update(dir: tab.url, items: items, hidden: tab.showHidden()) }
        }
        syncing = false
    }

    func focus() {
        switch mode {
        case .list: window?.makeFirstResponder(table)
        case .grid: window?.makeFirstResponder(grid)
        case .columns: columnsView.focus()
        }
    }

    /// Sütunlarda başka klasörde seçim yapıldı: sekme o klasöre geçer (geçmişe yazılmaz)
    private func columnSelected(_ dir: URL, _ urls: [URL]) {
        guard let tab else { return }
        if dir.fileKey != tab.url.fileKey {
            tab.pendingSelect = urls
            tab.go(dir, record: false)
        } else if tab.selection != urls {
            tab.selection = urls
        }
    }

    // MARK: Seçim

    var selectedIndexes: IndexSet {
        switch mode {
        case .list: return IndexSet(table.selectedRowIndexes.compactMap { itemIndex(atRow: $0) })
        case .grid: return IndexSet(grid.selectionIndexPaths.compactMap { itemIndex(of: $0) })
        case .columns:
            guard let tab else { return [] }
            let set = Set(columnsView.selectedItems(in: tab.url).map(\.url.fileKey))
            return IndexSet(items.indices.filter { set.contains(items[$0].url.fileKey) })
        }
    }

    var selectedItems: [FileItem] { selectedIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    func select(_ urls: [URL], scroll: Bool) {
        let set = Set(urls.map(\.fileKey))
        let idx = IndexSet(items.indices.filter { set.contains(items[$0].url.fileKey) })
        syncing = true
        switch mode {
        case .list:
            let rows = IndexSet(idx.map { itemRow[$0] })
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if scroll, let f = rows.first { table.scrollRowToVisible(f) }
        case .grid:
            grid.selectionIndexPaths = Set(idx.map { indexPath(ofItem: $0) })
            if scroll, let f = idx.first { grid.scrollToItems(at: [indexPath(ofItem: f)], scrollPosition: .nearestHorizontalEdge) }
        case .columns:
            if let tab { columnsView.select(idx.map { items[$0].url }, in: tab.url, scroll: scroll) }
        }
        syncing = false
        pushSelection()
    }

    private func pushSelection() {
        guard let tab else { return }
        let s = selectedURLs
        if tab.selection != s { tab.selection = s }
    }

    /// Silinenlerden sonra seçilecek öğe
    func itemAfter(_ urls: [URL]) -> URL? {
        let set = Set(urls.map(\.fileKey))
        guard let last = items.lastIndex(where: { set.contains($0.url.fileKey) }) else { return nil }
        if let next = items[(last + 1)...].first(where: { !set.contains($0.url.fileKey) }) { return next.url }
        return items[..<last].last { !set.contains($0.url.fileKey) }?.url
    }

    func screenFrame(of url: URL) -> NSRect? {
        if mode == .columns, let tab { return columnsView.screenFrame(of: url, in: tab.url) }
        guard let i = items.firstIndex(where: { $0.url.fileKey == url.fileKey }), let window else { return nil }
        let r: NSRect
        if mode == .list {
            let row = table.rect(ofRow: itemRow[i])
            r = table.convert(NSRect(x: row.minX + 6, y: row.minY + 2, width: 20, height: 20), to: nil)
        } else {
            guard let item = grid.item(at: indexPath(ofItem: i)) as? FilesGridItem else { return nil }
            r = item.iconView.convert(item.iconView.bounds, to: nil)
        }
        return window.convertToScreen(r)
    }

    /// Quick Look açıkken gelen tuşlar
    func forwardKey(_ e: NSEvent) -> Bool {
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        guard arrows.contains(e.keyCode) else { return false }
        if mode == .columns { return columnsView.forwardKey(e) }
        if mode == .list { table.keyDown(with: e) } else { grid.keyDown(with: e) }
        return true
    }

    @objc private func doubleClicked() {
        guard item(atRow: table.clickedRow) != nil else { return }
        owner?.open(selectedItems)
    }

    func openSelected() { owner?.open(selectedItems) }

    // MARK: Liste: veri

    func numberOfRows(in tableView: NSTableView) -> Int { rowItem.count }

    func tableView(_ tv: NSTableView, isGroupRow row: Int) -> Bool { rowItem.indices.contains(row) && rowItem[row] < 0 }

    func tableView(_ tv: NSTableView, shouldSelectRow row: Int) -> Bool { itemIndex(atRow: row) != nil }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        itemIndex(atRow: row) == nil && rowItem.indices.contains(row) ? 34 : tv.rowHeight
    }

    func tableView(_ tv: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if rowItem.indices.contains(row), rowItem[row] < 0 {
            let h = (tv.makeView(withIdentifier: FilesGroupHeaderView.id, owner: nil) as? FilesGroupHeaderView) ?? FilesGroupHeaderView()
            let n = rowItem[..<row].filter { $0 < 0 }.count
            if groups.indices.contains(n) { h.configure(groups[n].title, count: groups[n].range.count, inset: 10) }
            return h
        }
        guard let column, let item = item(atRow: row) else { return nil }
        let id = column.identifier
        let cell = (tv.makeView(withIdentifier: id, owner: nil) as? FilesCell) ?? FilesCell(id: id, withIcon: id == Self.colName)
        cell.alphaValue = item.isHidden ? 0.5 : 1
        switch id {
        case Self.colName:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = FileIcons.shared.icon(item.url)
            cell.textField?.textColor = .labelColor
            cell.textField?.delegate = self
        case Self.colDate:
            cell.textField?.stringValue = item.modified.map { FilesFormat.date.string(from: $0) } ?? "—"
            cell.textField?.textColor = .secondaryLabelColor
        case Self.colAdded:
            cell.textField?.stringValue = item.added.map { FilesFormat.date.string(from: $0) } ?? "—"
            cell.textField?.textColor = .secondaryLabelColor
        case Self.colSize:
            cell.textField?.stringValue = FilesFormat.size(item.size)
            cell.textField?.alignment = .right
            cell.textField?.textColor = .secondaryLabelColor
        default:
            // Alt klasörden gelen arama sonucu: türün yerine nerede olduğu
            if let rel = tab?.relativeFolder(of: item) {
                cell.textField?.stringValue = "↳ " + rel
                cell.toolTip = item.url.deletingLastPathComponent().path
            } else {
                cell.textField?.stringValue = item.kind
                cell.toolTip = nil
            }
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        itemIndex(atRow: row) == nil && rowItem.indices.contains(row) ? FilesHeaderRowView() : FilesRowView()
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        if !syncing { pushSelection() }
    }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !syncing, let d = tv.sortDescriptors.first, let key = FilesSortKey(rawValue: d.key ?? "") else { return }
        tab?.setSort(key, ascending: d.ascending)
    }

    func tableView(_ tv: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        column?.identifier == Self.colName ? item(atRow: row)?.name : nil
    }

    // MARK: Liste: sürükle-bırak

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(atRow: row).map { $0.url as NSURL }
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        var target: FileItem?
        if op == .on, let it = item(atRow: row), it.opensAsFolder {
            target = it
        } else {
            tv.setDropRow(-1, dropOperation: .on)
        }
        return dropOperation(info, into: target)
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = item(atRow: row).flatMap { $0.opensAsFolder ? $0 : nil }
        return performDrop(info, into: target)
    }

    /// Simge boyutu değişince: hücre boyu, simge kutusu; eşik aşılırsa küçük resimler yeni boyda
    private func applyZoom(_ v: Double) {
        guard let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.itemSize = FilesGridZoom.itemSize(for: v)
        for case let item as FilesGridItem in grid.visibleItems() { item.setIconSize(v) }
        layout.invalidateLayout()
        let bucket = FilesGridZoom.thumbSize(for: v)
        guard bucket != thumbBucket else { return }
        thumbBucket = bucket
        for ip in grid.indexPathsForVisibleItems() {
            guard let i = itemIndex(of: ip), let cell = grid.item(at: ip) as? FilesGridItem else { continue }
            let item = items[i]
            if let t = FileIcons.shared.thumbnail(item, size: bucket, ready: { [weak self] in self?.thumbReady(item.url) }) {
                cell.configure(item, thumb: t)
            }
        }
    }

    private func thumbReady(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url }) else { return }
        if let cell = grid.item(at: indexPath(ofItem: i)) as? FilesGridItem {
            cell.configure(items[i], thumb: nil, refreshThumb: true)
        }
    }

    // MARK: Simgeler: veri

    func numberOfSections(in cv: NSCollectionView) -> Int { groups.isEmpty ? 1 : groups.count }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups.isEmpty ? items.count : (groups.indices.contains(section) ? groups[section].range.count : 0)
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at ip: IndexPath) -> NSView {
        // Bırakırken AppKit simgelerin arasına "boşluk göstergesi" ister. Başlık nib'i olarak aranırsa
        // istisna atar ve sürükleme düşer (⌘ / ⌥'ye basınca bırakma işlemi değişip gösterge istenince)
        guard kind == NSCollectionView.elementKindSectionHeader else {
            return cv.makeSupplementaryView(ofKind: kind, withIdentifier: FilesGridGap.id, for: ip)
        }
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: FilesGridHeader.id, for: ip)
        if let h = v as? FilesGridHeader, groups.indices.contains(ip.section) {
            h.header.configure(groups[ip.section].title, count: groups[ip.section].range.count, inset: 14)
        }
        return v
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let v = cv.makeItem(withIdentifier: FilesGridItem.id, for: ip) as! FilesGridItem
        guard let i = itemIndex(of: ip) else { return v }
        let item = items[i]
        v.configure(item, thumb: FileIcons.shared.thumbnail(item, size: FilesGridZoom.shared.thumbSize) { [weak self] in
            self?.thumbReady(item.url)
        })
        return v
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ip: Set<IndexPath>) { if !syncing { pushSelection() } }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ip: Set<IndexPath>) { if !syncing { pushSelection() } }

    func collectionView(_ cv: NSCollectionView, canDragItemsAt ip: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        itemIndex(of: ip).map { items[$0].url as NSURL }
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        var target: FileItem?
        if op.pointee == .on, let i = itemIndex(of: ip.pointee as IndexPath), items[i].opensAsFolder {
            target = items[i]
        } else {
            // Klasör olmayan yere bırakma: açık klasörün kendisine
            op.pointee = .before
            let last = max(0, (groups.isEmpty ? 1 : groups.count) - 1)
            ip.pointee = NSIndexPath(forItem: groups.isEmpty ? items.count : groups[last].range.count, inSection: last)
        }
        return dropOperation(info, into: target)
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let target = op == .on ? itemIndex(of: ip).flatMap { items[$0].opensAsFolder ? items[$0] : nil } : nil
        return performDrop(info, into: target)
    }

    // MARK: Ortak bırakma

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Sütunlar için: hedef klasör doğrudan verilir
    func dragOperation(_ info: NSDraggingInfo, dest: URL) -> NSDragOperation {
        Self.operation(draggedURLs(info), mask: info.draggingSourceOperationMask, dest: dest)
    }

    /// Finder gibi: ⌘ her zaman taşır, ⌥ her zaman kopyalar; tuş yoksa aynı diskte taşı, başka diske kopyala.
    /// Aynı klasöre taşımanın anlamı yok (⌥ ile aynı klasöre bırakmak kopya çıkarır)
    static func operation(_ urls: [URL], mask: NSDragOperation, dest: URL) -> NSDragOperation {
        guard !urls.isEmpty, !urls.contains(where: { FileOps.isInside(dest, $0) }) else { return [] }
        let sameFolder = urls.allSatisfy { $0.deletingLastPathComponent().fileKey == dest.fileKey }
        if mask == .generic { return sameFolder ? [] : .move }          // ⌘
        if mask == .copy { return .copy }                                // ⌥
        let sameVolume = urls.allSatisfy { FileOps.sameVolume($0, dest) }
        if sameVolume && mask.contains(.move) { return sameFolder ? [] : .move }
        return mask.contains(.copy) && !sameFolder ? .copy : []
    }

    func performDrop(_ info: NSDraggingInfo, dest: URL) -> Bool {
        guard let owner else { return false }
        let op = dragOperation(info, dest: dest)
        guard !op.isEmpty else { return false }
        owner.drop(draggedURLs(info), into: dest, mode: op == .copy ? .copy : .move)
        return true
    }

    private func dropOperation(_ info: NSDraggingInfo, into target: FileItem?) -> NSDragOperation {
        guard let tab else { return [] }
        return Self.operation(draggedURLs(info), mask: info.draggingSourceOperationMask, dest: target?.folderTarget ?? tab.url)
    }

    private func performDrop(_ info: NSDraggingInfo, into target: FileItem?) -> Bool {
        guard let tab, let owner else { return false }
        let urls = draggedURLs(info)
        let dest = target?.folderTarget ?? tab.url
        let op = dropOperation(info, into: target)
        guard !op.isEmpty else { return false }
        owner.drop(urls, into: dest, mode: op == .copy ? .copy : .move)
        return true
    }

    // MARK: Yeniden adlandırma

    private var renaming: URL?

    func beginRename(_ url: URL) {
        guard let i = items.firstIndex(where: { $0.url.fileKey == url.fileKey }) else { return }
        let url = items[i].url
        select([url], scroll: true)
        if mode != .list {
            renameWithSheet(items[i])
            return
        }
        let col = table.column(withIdentifier: Self.colName)
        guard col >= 0, let cell = table.view(atColumn: col, row: itemRow[i], makeIfNecessary: true) as? FilesCell,
              let field = cell.textField else { return }
        renaming = url
        field.stringValue = url.lastPathComponent
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = FilesPalette.current(for: effectiveAppearance).renameBack
        window?.makeFirstResponder(field)
        // Uzantı hariç seç (Finder gibi)
        if let editor = field.currentEditor() {
            let name = url.lastPathComponent as NSString
            let ext = name.pathExtension
            let len = (items[i].isFolder || ext.isEmpty) ? name.length : name.length - ext.count - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, len))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renaming = nil
            endEditing(control as? NSTextField, commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
        endEditing(field, commit: true)
    }

    private func endEditing(_ field: NSTextField?, commit: Bool) {
        guard let field, field.isEditable else { return }
        let newName = field.stringValue
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        let target = renaming
        renaming = nil
        if commit, let target, let owner,
           let dest = FileOps.rename(target, to: newName, undo: owner.window?.undoManager, window: owner.window) {
            tab?.pendingSelect = [dest]
            tab?.reload()
        } else if let target, let item = items.first(where: { $0.url.fileKey == target.fileKey }) {
            field.stringValue = item.name
        }
        DispatchQueue.main.async { self.focus() }
    }

    private func renameWithSheet(_ item: FileItem) {
        guard let window, let owner else { return }
        let a = NSAlert()
        a.messageText = L("Yeniden adlandır")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.url.lastPathComponent
        a.accessoryView = field
        a.addButton(withTitle: L("Yeniden adlandır"))
        a.addButton(withTitle: L("Vazgeç"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn,
                  let dest = FileOps.rename(item.url, to: field.stringValue, undo: owner.window?.undoManager, window: window) else { return }
            self?.tab?.pendingSelect = [dest]
            self?.tab?.reload()
        }
    }

    // MARK: Sağ tık menüsü

    /// Sağ tıklanan öğe seçili değilse önce onu seç
    func prepareContextClick(at index: Int?) {
        guard let index, items.indices.contains(index) else {
            select([], scroll: false)
            return
        }
        if !selectedIndexes.contains(index) { select([items[index].url], scroll: false) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let owner, let tab else { return }
        if mode == .list { prepareContextClick(at: itemIndex(atRow: table.clickedRow)) }
        let sel = selectedItems

        func add(_ title: String, _ action: Selector, _ target: AnyObject? = nil, obj: Any? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target ?? owner
            i.representedObject = obj
            menu.addItem(i)
        }

        if sel.isEmpty {
            add(L("Yeni klasör"), #selector(FilesWindowController.newFolder(_:)))
            if !FilesWindowController.pasteboardURLs().isEmpty {
                add(L("Yapıştır"), #selector(FilesWindowController.paste(_:)))
                add(L("Öğeyi buraya taşı"), #selector(FilesWindowController.moveHere(_:)))
            }
            menu.addItem(.separator())
            let list = NSMenuItem(title: L("Liste"), action: #selector(FilesWindowController.showList(_:)), keyEquivalent: "")
            list.target = owner
            list.state = mode == .list ? .on : .off
            menu.addItem(list)
            let grid = NSMenuItem(title: L("Simgeler"), action: #selector(FilesWindowController.showGrid(_:)), keyEquivalent: "")
            grid.target = owner
            grid.state = mode == .grid ? .on : .off
            menu.addItem(grid)
            let cols = NSMenuItem(title: L("Sütunlar"), action: #selector(FilesWindowController.showColumns(_:)), keyEquivalent: "")
            cols.target = owner
            cols.state = mode == .columns ? .on : .off
            menu.addItem(cols)
            menu.addItem(sortMenuItem(for: tab))
            let hidden = NSMenuItem(title: L("Gizli dosyaları göster"), action: #selector(FilesWindowController.toggleHidden(_:)), keyEquivalent: "")
            hidden.target = owner
            hidden.state = owner.model.showHidden ? .on : .off
            menu.addItem(hidden)
            menu.addItem(.separator())
            add(L("Terminal'de aç"), #selector(openInTerminal(_:)), self, obj: tab.url)
            add(L("Yolu kopyala"), #selector(FilesWindowController.copyPath(_:)))
            add(L("Kenar çubuğuna ekle"), #selector(FilesWindowController.pinSelection(_:)))
            add(L("Finder'da göster"), #selector(FilesWindowController.revealInFinder(_:)))
            return
        }

        add(L("Aç"), #selector(FilesWindowController.openSelection(_:)))
        if sel.allSatisfy(\.opensAsFolder) {
            add(L("Yeni sekmede aç"), #selector(FilesWindowController.openSelectionInTab(_:)))
        }
        if let first = sel.first, !first.opensAsFolder {
            menu.addItem(openWithItem(for: sel.map(\.url)))
        }
        menu.addItem(.separator())
        add(L("Quick Look"), #selector(FilesWindowController.toggleQuickLook(_:)))
        if sel.count == 1 { add(L("Yeniden adlandır"), #selector(FilesWindowController.renameSelection(_:))) }
        add(L("Çoğalt"), #selector(FilesWindowController.duplicateSelection(_:)))
        add(L("Kopyala"), #selector(FilesWindowController.copy(_:)))
        add(L("Yolu kopyala"), #selector(FilesWindowController.copyPath(_:)))
        let share = NSSharingServicePicker(items: sel.map { $0.url as NSURL }).standardShareMenuItem
        share.title = L("Paylaş")
        menu.addItem(share)
        menu.addItem(.separator())
        if sel.allSatisfy(\.opensAsFolder) {
            add(L("Kenar çubuğuna ekle"), #selector(FilesWindowController.pinSelection(_:)))
            if sel.count == 1 { add(L("Terminal'de aç"), #selector(openInTerminal(_:)), self, obj: sel[0].folderTarget) }
        }
        add(L("Finder'da göster"), #selector(FilesWindowController.revealInFinder(_:)))
        menu.addItem(.separator())
        let urls = sel.map(\.url)
        menu.addItem(TagColorMenuRow.menuItem(for: urls) { [weak owner] in owner?.colorsChanged(urls) })
        menu.addItem(.separator())
        add(L("Çöp sepetine taşı"), #selector(FilesWindowController.trashSelection(_:)))
    }

    /// "Sırala" alt menüsü: anahtar, yön ve tarihe göre gruplama (bu klasör için hatırlanır)
    private func sortMenuItem(for tab: FilesTab) -> NSMenuItem {
        let top = NSMenuItem(title: L("Sırala"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for k in FilesSortKey.allCases {
            let it = NSMenuItem(title: k.title, action: #selector(sortBy(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = k.rawValue
            it.state = tab.sortKey == k ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        for (asc, title) in [(true, L("Artan")), (false, L("Azalan"))] {
            let it = NSMenuItem(title: title, action: #selector(sortDirection(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = asc
            it.state = tab.ascending == asc ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let g = NSMenuItem(title: L("Tarihe göre grupla"), action: #selector(toggleGrouped(_:)), keyEquivalent: "")
        g.target = self
        g.state = tab.grouped ? .on : .off
        sub.addItem(g)
        top.submenu = sub
        return top
    }

    @objc private func sortBy(_ sender: NSMenuItem) {
        guard let tab, let raw = sender.representedObject as? String, let k = FilesSortKey(rawValue: raw) else { return }
        tab.setSort(k, ascending: k == tab.sortKey ? tab.ascending : !(k.isDate || k == .size))
    }

    @objc private func sortDirection(_ sender: NSMenuItem) {
        guard let tab, let asc = sender.representedObject as? Bool else { return }
        tab.setSort(tab.sortKey, ascending: asc)
    }

    @objc private func toggleGrouped(_ sender: NSMenuItem) {
        guard let tab else { return }
        tab.setGrouped(!tab.grouped)
    }

    private func openWithItem(for urls: [URL]) -> NSMenuItem {
        let top = NSMenuItem(title: L("Birlikte aç"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let ws = NSWorkspace.shared
        let first = urls[0]
        let def = ws.urlForApplication(toOpen: first)
        var apps = ws.urlsForApplications(toOpen: first)
        if let def { apps.removeAll { $0 == def }; apps.insert(def, at: 0) }
        var seen = Set<String>()
        for (i, app) in apps.enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            guard seen.insert(name).inserted else { continue }
            let it = NSMenuItem(title: i == 0 && def != nil ? L("%@ (varsayılan)", name) : name,
                                action: #selector(openWith(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = OpenWith(urls: urls, app: app)
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            it.image = icon
            sub.addItem(it)
            if i == 0 && def != nil && apps.count > 1 { sub.addItem(.separator()) }
        }
        sub.addItem(.separator())
        let other = NSMenuItem(title: L("Diğer…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = urls
        sub.addItem(other)
        top.submenu = sub
        return top
    }

    private final class OpenWith: NSObject {
        let urls: [URL], app: URL
        init(urls: [URL], app: URL) { self.urls = urls; self.app = app }
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? OpenWith else { return }
        owner?.openWith(o.urls, app: o.app)
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], let window else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = L("Aç")
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let app = p.url else { return }
            self?.owner?.openWith(urls, app: app)
        }
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        owner?.openInTerminal(u)
    }
}

// MARK: - Liste parçaları

/// Fareyle üstüne gelinen satırı hafif gri gösterir (Dosyalar'ın liste ve sütun tabloları)
class FilesHoverTable: NSTableView {
    private var hoverRow = -1
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHover(nil)
    }

    override func reloadData() {
        setHover(-1)
        super.reloadData()
    }

    private func updateHover(_ event: NSEvent?) {
        guard let window else { return setHover(-1) }
        let loc = event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream
        let p = convert(loc, from: nil)
        setHover(visibleRect.contains(p) ? row(at: p) : -1)
    }

    private func setHover(_ r: Int) {
        guard r != hoverRow else { return }
        if hoverRow >= 0, hoverRow < numberOfRows { (rowView(atRow: hoverRow, makeIfNecessary: false) as? FilesRowView)?.hovered = false }
        hoverRow = r
        if r >= 0 { (rowView(atRow: r, makeIfNecessary: false) as? FilesRowView)?.hovered = true }
    }
}

final class FilesTableView: FilesHoverTable {
    weak var owner: FilesBrowser?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 36 where mods.isEmpty, 76 where mods.isEmpty:   // Return: yeniden adlandır
            if selectedRowIndexes.count == 1 { owner?.owner?.renameSelection(nil) } else { NSSound.beep() }
        case 49 where mods.isEmpty:   // Boşluk: Quick Look
            owner?.owner?.toggleQuickLook(nil)
        default:
            super.keyDown(with: e)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }

    /// Boş alana tıklayınca seçim kalksın, sürükleyerek çoklu seçim olsun
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Ad hücresi tek tıkla düzenlemeye geçmesin (sadece Return ile)
        if let f = responder as? NSTextField, !f.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

final class FilesCell: NSTableCellView {
    init(id: NSUserInterfaceItemIdentifier, withIcon: Bool) {
        super.init(frame: .zero)
        identifier = id
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 12.5)
        t.lineBreakMode = .byTruncatingMiddle
        t.cell?.truncatesLastVisibleLine = true
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isEditable = false
        t.isSelectable = false
        t.focusRingType = .none
        addSubview(t)
        textField = t
        if withIcon {
            let i = FilesIconView()
            i.imageScaling = .scaleProportionallyUpOrDown
            i.translatesAutoresizingMaskIntoConstraints = false
            addSubview(i)
            imageView = i
            NSLayoutConstraint.activate([
                i.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                i.centerYAnchor.constraint(equalTo: centerYAnchor),
                i.widthAnchor.constraint(equalToConstant: 18),
                i.heightAnchor.constraint(equalToConstant: 18),
                t.leadingAnchor.constraint(equalTo: i.trailingAnchor, constant: 6),
            ])
        } else {
            t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            t.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            t.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Seçili satırda ikincil metinler de okunaklı kalsın
            guard identifier?.rawValue != "name" else { return }
            textField?.textColor = backgroundStyle == .emphasized ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        }
    }
}

/// Seçili satır: temanın vurgusu, yuvarlak köşe
final class FilesRowView: NSTableRowView {
    private var palette: FilesPalette { FilesPalette.current(for: effectiveAppearance) }
    /// Fare üstünde: hafif gri
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovered, !isSelected else { return }
        let p = palette
        let r = bounds.insetBy(dx: p.rowInset, dy: 1)
        p.nsHover.setFill()
        NSBezierPath(roundedRect: r, xRadius: p.rowRadius, yRadius: p.rowRadius).fill()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    func refreshStyle() {
        // Dolu vurgu yoksa metin normal renginde kalsın
        for i in 0..<numberOfColumns { (view(atColumn: i) as? NSTableCellView)?.backgroundStyle = interiorBackgroundStyle }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized && palette.selectionInvertsText ? .emphasized : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let p = palette
        let r = bounds.insetBy(dx: p.rowInset, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: p.rowRadius, yRadius: p.rowRadius)
        p.rowSelection(emphasized: isEmphasized).setFill()
        path.fill()
        if let stroke = p.rowStroke {
            stroke.setStroke()
            let inner = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: p.rowRadius, yRadius: p.rowRadius)
            inner.lineWidth = 1
            inner.stroke()
        }
        // Windows: seçili satırın solunda vurgu çizgisi
        if p.theme == .windows, isEmphasized {
            p.nsAccent.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY - 7, width: 3, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        let p = palette
        let r = bounds.insetBy(dx: p.rowInset, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: p.rowRadius, yRadius: p.rowRadius)
        p.nsAccent.withAlphaComponent(0.45).setFill()
        path.fill()
    }
}

// MARK: - Simge parçaları

final class FilesCollectionView: NSCollectionView {
    weak var owner: FilesBrowser?
    private var hoverPath: IndexPath?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHover(nil)
    }

    override func reloadData() {
        setHover(nil)
        super.reloadData()
    }

    private func updateHover(_ event: NSEvent?) {
        guard let window else { return setHover(nil) }
        let p = convert(event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(p), let ip = indexPathForItem(at: p),
              let item = item(at: ip), item.view.frame.contains(p) else { return setHover(nil) }
        setHover(ip)
    }

    private func setHover(_ ip: IndexPath?) {
        guard ip != hoverPath else { return }
        if let old = hoverPath { (item(at: old) as? FilesGridItem)?.hovered = false }
        hoverPath = ip
        if let ip { (item(at: ip) as? FilesGridItem)?.hovered = true }
    }

    /// İzleme dörtgeninde kıstırma: simgeleri büyüt / küçült
    override func magnify(with event: NSEvent) {
        let z = FilesGridZoom.shared
        z.size = z.size * (1 + Double(event.magnification))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            if indexPathForItem(at: p) != nil { owner?.openSelected() }
        }
    }

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 36 where mods.isEmpty, 76 where mods.isEmpty:
            if selectionIndexPaths.count == 1 { owner?.owner?.renameSelection(nil) } else { NSSound.beep() }
        case 49 where mods.isEmpty:
            owner?.owner?.toggleQuickLook(nil)
        case 123 where mods.isEmpty || mods == .shift, 124 where mods.isEmpty || mods == .shift:
            stepLinear(by: e.keyCode == 123 ? -1 : 1, extend: mods == .shift)
        default:
            super.keyDown(with: e)
        }
    }

    /// Sağ / sol oklar satır sonunda alt / üst satıra geçer (sıra boyunca bir sonraki öğe)
    private func stepLinear(by d: Int, extend: Bool) {
        guard let owner else { return }
        let n = owner.itemCount
        guard n > 0 else { return }
        let sel = selectionIndexPaths.compactMap { owner.itemIndex(of: $0) }.sorted()
        let target: Int
        if sel.isEmpty {
            target = d > 0 ? 0 : n - 1
        } else {
            target = d > 0 ? sel.last! + 1 : sel.first! - 1
        }
        guard target >= 0, target < n else { NSSound.beep(); return }
        let ip = owner.indexPath(ofItem: target)
        if extend {
            selectItems(at: [ip], scrollPosition: [])
            delegate?.collectionView?(self, didSelectItemsAt: [ip])
        } else {
            let old = selectionIndexPaths
            deselectItems(at: old)
            selectItems(at: [ip], scrollPosition: [])
            delegate?.collectionView?(self, didDeselectItemsAt: old)
            delegate?.collectionView?(self, didSelectItemsAt: [ip])
        }
        scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        owner?.prepareContextClick(at: indexPathForItem(at: p).flatMap { owner?.itemIndex(of: $0) })
        return super.menu(for: event)
    }
}

final class FilesGridItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FilesGridItem")
    let iconView = FilesIconView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let back = NSView()
    private var url: URL?
    private var iconW: NSLayoutConstraint!
    private var iconH: NSLayoutConstraint!

    override func loadView() {
        let v = NSView()
        back.wantsLayer = true
        back.layer?.cornerRadius = 9
        back.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        v.addSubview(back)
        v.addSubview(iconView)
        v.addSubview(label)
        let size = CGFloat(FilesGridZoom.shared.size)
        iconW = iconView.widthAnchor.constraint(equalToConstant: size)
        iconH = iconView.heightAnchor.constraint(equalToConstant: size)
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            back.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            back.topAnchor.constraint(equalTo: v.topAnchor),
            back.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            iconView.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iconW, iconH,
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
        ])
        view = v
    }

    func configure(_ item: FileItem, thumb: NSImage?, refreshThumb: Bool = false) {
        url = item.url
        label.stringValue = item.name
        view.alphaValue = item.isHidden ? 0.5 : 1
        if refreshThumb {
            iconView.image = FileIcons.shared.thumbnail(item, size: FilesGridZoom.shared.thumbSize) {} ?? FileIcons.shared.icon(item.url)
        } else {
            iconView.image = thumb ?? FileIcons.shared.icon(item.url)
        }
        updateLook()
    }

    override var isSelected: Bool { didSet { updateLook() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateLook() } }
    /// Fare üstünde: hafif gri zemin
    var hovered = false { didSet { if hovered != oldValue { updateLook() } } }

    func refreshLook() { updateLook() }

    func setIconSize(_ v: Double) {
        guard isViewLoaded else { return }
        iconW.constant = CGFloat(v)
        iconH.constant = CGFloat(v)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        setIconSize(FilesGridZoom.shared.size)
    }

    private func updateLook() {
        let p = FilesPalette.current(for: view.effectiveAppearance)
        let dropping = highlightState == .forSelection && !isSelected
        let on = isSelected || dropping
        back.layer?.cornerRadius = p.rowRadius + 3
        back.layer?.backgroundColor = on ? p.gridBack.cgColor : (hovered ? p.nsHover.cgColor : NSColor.clear.cgColor)
        back.layer?.borderWidth = on && p.gridStroke != nil ? 1 : 0
        back.layer?.borderColor = p.gridStroke?.cgColor
        let labelBack = on ? p.gridLabelBack : nil
        label.layer?.backgroundColor = labelBack?.cgColor ?? NSColor.clear.cgColor
        label.textColor = labelBack != nil ? .white : p.nsFG.withAlphaComponent(0.9)
    }
}

// MARK: - Tarih başlıkları (Bugün, Dün, 22 Kasım Pazartesi, Ekim…)

/// Başlık: kalın ad, sağda sayı, altında ince çizgi
final class FilesGroupHeaderView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FilesGroupHeader")
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let line = NSView()
    private var leading: NSLayoutConstraint!
    private var lineLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: 12.5, weight: .bold)
        count.font = .systemFont(ofSize: 11, weight: .medium)
        line.wantsLayer = true
        for v in [title, count, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        leading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        lineLeading = line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            leading,
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            lineLeading,
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, count n: Int, inset: CGFloat) {
        title.stringValue = text
        count.stringValue = String(n)
        leading.constant = inset
        lineLeading.constant = inset
        refreshLook()
    }

    private func refreshLook() {
        let p = FilesPalette.current(for: effectiveAppearance)
        title.textColor = p.nsFG.withAlphaComponent(0.85)
        count.textColor = p.nsFG.withAlphaComponent(0.4)
        line.layer?.backgroundColor = p.nsFG.withAlphaComponent(p.dark ? 0.12 : 0.1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLook()
    }
}

/// Başlık satırı: arka plan ve seçim çizilmez
final class FilesHeaderRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// Simgelerde bölüm başlığı
/// Bırakma boşluğu göstergesi: boş; dosyalar açık klasörün kendisine bırakılır, araya değil
final class FilesGridGap: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("FilesGridGap")
}

final class FilesGridHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("FilesGridHeader")
    let header = FilesGroupHeaderView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.autoresizingMask = [.width, .height]
        header.frame = bounds
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Dosya simgesi: NSImageView kendini sürükle-bırak hedefi olarak kaydeder ve düzenlenemezken bırakmayı
/// reddeder; bu yüzden klasörün simgesinin üstüne bırakılan dosyalar ızgaraya / tabloya ulaşmıyordu.
final class FilesIconView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        unregisterDraggedTypes()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
    }
    override var isEditable: Bool {
        didSet { unregisterDraggedTypes() }
    }
}
