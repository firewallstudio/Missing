import AppKit

// MARK: - Kenar çubuğu: açılır klasörler ve kullanıcı başlıkları
//
// Sık kullanılanlardaki (ve başlıklardaki) bir klasör ok ile açılıp alt klasörleri
// girintili gösterilir. Kullanıcı kendi başlıklarını açıp altına istediği klasörleri koyabilir.

struct SidebarGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var paths: [String] = []
    var collapsed = false
}

@MainActor final class FilesSidebarState: ObservableObject {
    static let shared = FilesSidebarState()

    @Published private(set) var groups: [SidebarGroup]
    /// Açık klasörler: "bölüm|yol" (alt klasörde bölüm, üst klasörün anahtarıdır)
    @Published private(set) var expanded: Set<String>
    /// Kapalı hazır bölümler ("fav", "pin", "loc", "tags")
    @Published private(set) var collapsedSections: Set<String>
    /// Açık klasörlerin alt klasörleri (yol → alt klasörler)
    @Published private(set) var children: [String: [URL]] = [:]
    /// Her klasörde gösterilecek alt klasörler (üst yol → alt yollar). Varsayılan: hiçbiri; kullanıcı seçer
    @Published private(set) var shown: [String: Set<String>]
    /// Adı yazılmakta olan başlık
    @Published var editing: UUID?
    /// Bölümlerin sırası: hazır bölümler ("fav", "pin", "loc", "tags") ve başlıkların UUID'leri
    @Published private(set) var order: [String] = []
    /// Sürüklenen bölüm (bırakma çizgisi için)
    @Published var draggingSection: String?

    private static let d = UserDefaults.standard
    private static let groupsKey = "files.sidebarGroups"
    private static let expandedKey = "files.sidebarExpanded"
    private static let sectionsKey = "files.sidebarCollapsedSections"
    private static let shownKey = "files.sidebarShownChildren"
    private static let orderKey = "files.sidebarOrder"
    static let builtinSections = ["fav", "pin", "loc", "tags"]

    private init() {
        groups = (Self.d.data(forKey: Self.groupsKey)).flatMap { try? JSONDecoder().decode([SidebarGroup].self, from: $0) } ?? []
        expanded = Set(Self.d.stringArray(forKey: Self.expandedKey) ?? [])
        collapsedSections = Set(Self.d.stringArray(forKey: Self.sectionsKey) ?? [])
        shown = ((Self.d.dictionary(forKey: Self.shownKey) as? [String: [String]]) ?? [:]).mapValues(Set.init)
        order = Self.d.stringArray(forKey: Self.orderKey) ?? []
        normalizeOrder()
        reloadChildren()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadChildren() }
        }
    }

    // MARK: Açılır klasörler

    static func key(_ scope: String, _ url: URL) -> String { scope + "|" + url.standardizedFileURL.path }

    func isExpanded(_ scope: String, _ url: URL) -> Bool { expanded.contains(Self.key(scope, url)) }

    func toggle(_ scope: String, _ url: URL) {
        let k = Self.key(scope, url)
        if expanded.contains(k) {
            expanded.remove(k)
        } else {
            expanded.insert(k)
            load(url)
        }
        Self.d.set(expanded.sorted(), forKey: Self.expandedKey)
    }

    /// Açık değilse açar (alt klasörleri de okur)
    func expand(_ scope: String, _ url: URL) {
        let k = Self.key(scope, url)
        if !expanded.contains(k) {
            expanded.insert(k)
            Self.d.set(expanded.sorted(), forKey: Self.expandedKey)
        }
        load(url)
    }

    // MARK: Gösterilecek alt klasörler

    func shownChildren(of parent: URL) -> Set<String> { shown[parent.standardizedFileURL.path] ?? [] }

    func isShown(_ child: URL, in parent: URL) -> Bool {
        shownChildren(of: parent).contains(child.standardizedFileURL.path)
    }

    func setShown(_ children: [URL], in parent: URL, _ on: Bool) {
        let p = parent.standardizedFileURL.path
        var set = shown[p] ?? []
        for c in children {
            if on { set.insert(c.standardizedFileURL.path) } else { set.remove(c.standardizedFileURL.path) }
        }
        shown[p] = set.isEmpty ? nil : set
        Self.d.set(shown.mapValues { $0.sorted() }, forKey: Self.shownKey)
    }

    /// nil: henüz okunmadı
    func subfolders(_ url: URL) -> [URL]? { children[url.standardizedFileURL.path] }

    private func load(_ url: URL) {
        let path = url.standardizedFileURL.path
        let list = Self.readSubfolders(url)
        if children[path] != list { children[path] = list }
    }

    /// Açık klasörleri yeniden okur (yeni klasör, silinen klasör…)
    func reloadChildren() {
        var paths = Set<String>()
        for k in expanded {
            guard let bar = k.lastIndex(of: "|") else { continue }
            paths.insert(String(k[k.index(after: bar)...]))
        }
        var c: [String: [URL]] = [:]
        for p in paths { c[p] = Self.readSubfolders(URL(fileURLWithPath: p)) }
        if c != children { children = c }
    }

    static func readSubfolders(_ url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return list.filter { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .prefix(300).map { $0 }
    }

    // MARK: Hazır bölümler

    func isCollapsed(section: String) -> Bool { collapsedSections.contains(section) }

    func toggle(section: String) {
        if collapsedSections.contains(section) { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        Self.d.set(collapsedSections.sorted(), forKey: Self.sectionsKey)
    }

    // MARK: Bölüm sırası

    /// Eksik bölümleri ekler, silinmiş başlıkları çıkarır. İlk açılışta eski düzen:
    /// sık kullanılanlar, sabitlenenler, başlıklar, konumlar, etiketler
    private func normalizeOrder() {
        let ids = groups.map(\.id.uuidString)
        var o = order.filter { Self.builtinSections.contains($0) || ids.contains($0) }
        for b in ["fav", "pin"] where !o.contains(b) { o.append(b) }
        for id in ids where !o.contains(id) {
            if let i = o.firstIndex(of: "loc") { o.insert(id, at: i) } else { o.append(id) }
        }
        for b in ["loc", "tags"] where !o.contains(b) { o.append(b) }
        if o != order { order = o }
    }

    private func saveOrder() { Self.d.set(order, forKey: Self.orderKey) }

    /// Bölümü `target`'ın önüne taşır (nil: en sona)
    func moveSection(_ key: String, before target: String?) {
        guard key != target, let from = order.firstIndex(of: key) else { return }
        var o = order
        o.remove(at: from)
        if let target, let to = o.firstIndex(of: target) { o.insert(key, at: to) } else { o.append(key) }
        guard o != order else { return }
        order = o
        saveOrder()
    }

    /// Görünen bölümler arasında bir yukarı / aşağı (boş, gizli bölümler atlanır)
    func moveSection(_ key: String, by offset: Int, among visible: [String]) {
        guard let i = visible.firstIndex(of: key) else { return }
        let j = i + offset
        guard visible.indices.contains(j) else { return }
        if offset < 0 {
            moveSection(key, before: visible[j])
        } else {
            moveSection(key, before: visible.indices.contains(j + 1) ? visible[j + 1] : nil)
        }
    }

    // MARK: ⌘Tab paneli ve Ayarlar için

    /// ⌘Tab'da gösterilebilecek bölümler, kenar çubuğundaki sırayla: sık kullanılanlar, sabitlenenler ve başlıklar
    func switcherSections() -> [(key: String, title: String, places: [SidebarPlace])] {
        let pl = FilesPlaces.shared
        return order.compactMap { key in
            switch key {
            case "fav": return (key, L("Sık kullanılanlar"), pl.shownFavorites)
            case "pin": return (key, L("Sabitlenenler"), pl.pinned)
            case "loc", "tags": return nil
            default:
                guard let g = groups.first(where: { $0.id.uuidString == key }) else { return nil }
                return (key, g.title, places(g))
            }
        }
    }

    /// Bölümün görünen adı
    func title(ofSection key: String) -> String {
        switch key {
        case "fav": return L("Sık kullanılanlar")
        case "pin": return L("Sabitlenenler")
        case "loc": return L("Konumlar")
        case "tags": return L("Etiketler")
        default: return groups.first { $0.id.uuidString == key }?.title ?? ""
        }
    }

    // MARK: Başlıklar

    private func save() {
        if let data = try? JSONEncoder().encode(groups) { Self.d.set(data, forKey: Self.groupsKey) }
    }

    /// Yeni başlık ekler ve adı yazılsın diye düzenlemeye açar
    @discardableResult func addGroup(with urls: [URL] = []) -> UUID {
        var g = SidebarGroup(title: L("Yeni başlık"))
        g.paths = Self.folders(urls).map(\.path)
        groups.append(g)
        save()
        normalizeOrder()
        saveOrder()
        editing = g.id
        return g.id
    }

    func rename(_ id: UUID, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = groups.firstIndex(where: { $0.id == id }), !t.isEmpty, groups[i].title != t else { return }
        groups[i].title = t
        save()
    }

    func remove(_ id: UUID) {
        groups.removeAll { $0.id == id }
        order.removeAll { $0 == id.uuidString }
        saveOrder()
        let prefix = id.uuidString + "|"
        let e = expanded.filter { !$0.hasPrefix(prefix) }
        if e != expanded { expanded = e; Self.d.set(expanded.sorted(), forKey: Self.expandedKey) }
        save()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].collapsed.toggle()
        save()
    }

    /// Klasörleri başlığa ekler (başka başlıktaysa oradan taşınmaz; aynı klasör iki başlıkta olabilir)
    func add(_ urls: [URL], to id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        for u in Self.folders(urls) where !groups[i].paths.contains(u.path) {
            groups[i].paths.append(u.path)
            changed = true
        }
        if groups[i].collapsed && changed { groups[i].collapsed = false }
        if changed { save() }
    }

    func move(_ url: URL, from source: UUID, to dest: UUID) {
        removeItem(url, from: source)
        add([url], to: dest)
    }

    func removeItem(_ url: URL, from id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let path = url.standardizedFileURL.path
        groups[i].paths.removeAll { $0 == path }
        save()
    }

    func moveItem(_ url: URL, in id: UUID, by offset: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }),
              let a = groups[i].paths.firstIndex(of: url.standardizedFileURL.path) else { return }
        let b = a + offset
        guard groups[i].paths.indices.contains(b) else { return }
        groups[i].paths.swapAt(a, b)
        save()
    }

    /// Başlıktaki (hâlâ var olan) klasörler
    func places(_ g: SidebarGroup) -> [SidebarPlace] {
        let fm = FileManager.default
        return g.paths.compactMap { p in
            guard fm.fileExists(atPath: p) else { return nil }
            let u = URL(fileURLWithPath: p)
            return SidebarPlace(url: u, title: fm.displayName(atPath: p), symbol: FilesPlaces.symbol(for: u))
        }
    }

    private static func folders(_ urls: [URL]) -> [URL] {
        urls.map(\.standardizedFileURL).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Klasör seçtirip başlığa ekler
    func chooseFolders(for id: UUID, window: NSWindow?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = L("Ekle")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            self?.add(p.urls, to: id)
        }
        if let window { p.beginSheetModal(for: window, completionHandler: done) } else { done(p.runModal()) }
    }
}
