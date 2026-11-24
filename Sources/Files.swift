import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Missing Dosyalar
//
// Finder'a dokunmayan, tamamen bizim dosya penceremiz: sekmeler, kenar çubuğu, liste ve simge görünümü,
// Quick Look, sürükle-bırak ve geri alınabilir dosya işlemleri. Pencere açıkken Missing Dock'ta görünür;
// Dock'ta tutulursa simgeye tıklamak pencereyi açar. Son pencere kapanınca Missing yine menü çubuğuna çekilir.

/// Simge görünümünde simge boyutu (Finder'daki sağ alt kaydırıcı gibi); bütün pencereler ortak
@MainActor final class FilesGridZoom: ObservableObject {
    static let shared = FilesGridZoom()
    static let range: ClosedRange<Double> = 32...256

    @Published var size: Double {
        didSet {
            let c = min(max(size, Self.range.lowerBound), Self.range.upperBound)
            if c != size { size = c; return }
            UserDefaults.standard.set(size, forKey: "files.gridIconSize")
        }
    }

    private init() {
        let v = UserDefaults.standard.double(forKey: "files.gridIconSize")
        size = v == 0 ? 64 : min(max(v, Self.range.lowerBound), Self.range.upperBound)
    }

    var itemSize: NSSize { Self.itemSize(for: size) }
    var thumbSize: CGFloat { Self.thumbSize(for: size) }

    static func itemSize(for v: Double) -> NSSize {
        NSSize(width: max(100, v + 44), height: v + 50)
    }

    /// Küçük resimler kademeli üretilir; kaydırırken her adımda yeniden üretilmesin
    static func thumbSize(for v: Double) -> CGFloat { v <= 64 ? 64 : (v <= 128 ? 128 : 256) }
}

enum FilesSettings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "files.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "files.enabled") }
    }
    static var showHidden: Bool {
        get { d.bool(forKey: "files.showHidden") }
        set { d.set(newValue, forKey: "files.showHidden") }
    }
    static var viewMode: FilesViewMode {
        get { FilesViewMode(rawValue: d.string(forKey: "files.viewMode") ?? "") ?? .list }
        set { d.set(newValue.rawValue, forKey: "files.viewMode") }
    }
    /// ⌘" sekme değiştirici: açık mı, liste mi kartlar mı, kartlarda klasörün içi görünsün mü
    static var tabSwitcherEnabled: Bool {
        get { d.object(forKey: "files.tabSwitcher") as? Bool ?? true }
        set { d.set(newValue, forKey: "files.tabSwitcher") }
    }
    static var tabSwitcherList: Bool {
        get { d.bool(forKey: "files.tabSwitcher.list") }
        set { d.set(newValue, forKey: "files.tabSwitcher.list") }
    }
    static var tabSwitcherFavorites: Bool {
        get { d.object(forKey: "files.tabSwitcher.favorites") as? Bool ?? true }
        set { d.set(newValue, forKey: "files.tabSwitcher.favorites") }
    }
    static var tabSwitcherContents: Bool {
        get { d.object(forKey: "files.tabSwitcher.contents") as? Bool ?? true }
        set { d.set(newValue, forKey: "files.tabSwitcher.contents") }
    }
    /// Sağdaki önizleme bölmesi (Windows Gezgini gibi)
    static var previewVisible: Bool {
        get { d.bool(forKey: "files.preview") }
        set { d.set(newValue, forKey: "files.preview") }
    }
    static var sidebarVisible: Bool {
        get { d.object(forKey: "files.sidebar") as? Bool ?? true }
        set { d.set(newValue, forKey: "files.sidebar") }
    }
    /// Son kapanan pencerenin sekmeleri (bir dahaki açılışta geri gelir)
    static var lastTabs: [String] {
        get { d.stringArray(forKey: "files.lastTabs") ?? [] }
        set { d.set(newValue, forKey: "files.lastTabs") }
    }
    static var lastSelectedTab: Int {
        get { d.integer(forKey: "files.lastSelectedTab") }
        set { d.set(newValue, forKey: "files.lastSelectedTab") }
    }
    /// Kenar çubuğunda gizlenen öğeler (SidebarPlace.hideKey / "tags" / "tag:Ad")
    static var sidebarHidden: Set<String> {
        get { Set(d.stringArray(forKey: "files.sidebarHidden") ?? []) }
        set { d.set(newValue.sorted(), forKey: "files.sidebarHidden") }
    }
    /// Kenar çubuğuna kullanıcının sabitlediği klasörler
    static var pinned: [String] {
        get { d.stringArray(forKey: "files.pinned") ?? [] }
        set { d.set(newValue, forKey: "files.pinned") }
    }
}

enum FilesViewMode: String { case list, grid, columns }

extension URL {
    /// Karşılaştırma anahtarı: klasör adreslerinin sonundaki "/" ve Unicode biçimi (ğ, ü…) farkı yok sayılır
    var fileKey: String { standardizedFileURL.path.precomposedStringWithCanonicalMapping }
}

enum FilesSortKey: String, CaseIterable {
    case name, added, modified, size, kind
    var isDate: Bool { self == .added || self == .modified }
    var title: String {
        switch self {
        case .name: return L("Ad")
        case .added: return L("Eklenme tarihi")
        case .modified: return L("Değiştirilme tarihi")
        case .size: return L("Boyut")
        case .kind: return L("Tür")
        }
    }
}

/// Her klasörün kendi sıralaması ve gruplaması (İndirilenler: en yeni üstte, günlere / aylara göre)
@MainActor enum FolderViewPrefs {
    struct Prefs: Equatable {
        var key: FilesSortKey
        var ascending: Bool
        var grouped: Bool
    }

    private static let storeKey = "files.folderView"

    static func defaults(for url: URL) -> Prefs {
        if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, dl.fileKey == url.fileKey {
            return Prefs(key: .added, ascending: false, grouped: true)
        }
        return Prefs(key: .name, ascending: true, grouped: false)
    }

    static func get(_ url: URL) -> Prefs {
        let all = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        guard let raw = all[url.fileKey] else { return defaults(for: url) }
        let parts = raw.split(separator: ",").map(String.init)
        guard parts.count == 3, let k = FilesSortKey(rawValue: parts[0]) else { return defaults(for: url) }
        return Prefs(key: k, ascending: parts[1] == "1", grouped: parts[2] == "1")
    }

    static func set(_ p: Prefs, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        if p == defaults(for: url) {
            all[url.fileKey] = nil
        } else {
            all[url.fileKey] = "\(p.key.rawValue),\(p.ascending ? 1 : 0),\(p.grouped ? 1 : 0)"
        }
        UserDefaults.standard.set(all, forKey: storeKey)
    }
}

/// Tarihe göre gruplar: bu ay ve son yedi gün günlere, daha eskisi aylara bölünür
enum FilesDateGroups {
    struct Group { let title: String; var indices: [Int] }

    static func group(_ items: [FileItem], by key: FilesSortKey, ascending: Bool, now: Date = Date()) -> [Group] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var order: [String] = []
        var groups: [String: (title: String, date: Date, indices: [Int])] = [:]
        for (i, it) in items.enumerated() {
            let date = key == .modified ? it.modified : (it.added ?? it.modified)
            let id: String, title: String, start: Date
            if let date {
                let day = cal.startOfDay(for: date)
                let ago = cal.dateComponents([.day], from: day, to: today).day ?? 0
                let sameMonth = cal.isDate(date, equalTo: now, toGranularity: .month)
                if ago <= 0 && day >= today {
                    id = "today"; title = L("Bugün"); start = today
                } else if ago == 1 {
                    id = "yesterday"; title = L("Dün"); start = day
                } else if ago < 7 || sameMonth {
                    id = "d" + String(Int(day.timeIntervalSince1970)); start = day
                    title = dayFormatter.string(from: day)
                } else {
                    let m = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? day
                    id = "m" + String(Int(m.timeIntervalSince1970)); start = m
                    title = (cal.isDate(m, equalTo: now, toGranularity: .year) ? monthFormatter : monthYearFormatter).string(from: m)
                }
            } else {
                id = "none"; title = L("Tarihsiz"); start = .distantPast
            }
            if groups[id] == nil { order.append(id); groups[id] = (title, start, []) }
            groups[id]!.indices.append(i)
        }
        let oldestFirst = key.isDate && ascending
        let sorted = order.sorted { a, b in
            let da = groups[a]!.date, db = groups[b]!.date
            if da == .distantPast || db == .distantPast { return db == .distantPast && da != .distantPast }
            return oldestFirst ? da < db : da > db
        }
        return sorted.map { Group(title: groups[$0]!.title, indices: groups[$0]!.indices) }
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        // Başlıklar uygulamanın dilinde (Bugün / Dün ile aynı dil)
        f.locale = Locale(identifier: AppLanguage.active == .tr ? "tr_TR" : "en_US")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    private static let dayFormatter = formatter("EEEEdMMMM")
    private static let monthFormatter = formatter("MMMM")
    private static let monthYearFormatter = formatter("MMMMyyyy")
}

// MARK: - Öğe

struct FileItem: Hashable {
    let url: URL
    let name: String
    /// İçine girilebilen klasör (paket değil)
    let isFolder: Bool
    let isPackage: Bool
    let isApp: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    /// Klasöre eklenme tarihi (İndirilenler'de indirilme anı)
    let added: Date?
    let kind: String
    /// Klasöre işaret eden takma ad / sembolik bağ
    let isLinkToFolder: Bool
    /// Finder etiketleri (renkler)
    let tags: [String]

    static let keys: [URLResourceKey] = [.localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey,
                                         .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey,
                                         .isSymbolicLinkKey, .isAliasFileKey, .isApplicationKey, .tagNamesKey]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        self.url = url
        name = v.localizedName ?? url.lastPathComponent
        let dir = v.isDirectory ?? false
        isPackage = v.isPackage ?? false
        isApp = v.isApplication ?? false
        isFolder = dir && !isPackage
        isHidden = v.isHidden ?? url.lastPathComponent.hasPrefix(".")
        size = isFolder ? nil : (v.fileSize.map { Int64($0) })
        modified = v.contentModificationDate
        added = v.addedToDirectoryDate
        kind = v.localizedTypeDescription ?? ""
        tags = v.tagNames ?? []
        if (v.isSymbolicLink ?? false) || (v.isAliasFile ?? false), !dir,
           let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
           (try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map({ ($0.isDirectory ?? false) && !($0.isPackage ?? false) }) == true {
            isLinkToFolder = true
        } else {
            isLinkToFolder = false
        }
    }

    var opensAsFolder: Bool { isFolder || isLinkToFolder }

    /// Klasöre girilecekse gerçek hedef
    var folderTarget: URL {
        guard isLinkToFolder else { return url }
        return (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
    }

    static func == (a: FileItem, b: FileItem) -> Bool {
        a.url == b.url && a.name == b.name && a.size == b.size && a.modified == b.modified
    }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum FilesFormat {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
    static func size(_ b: Int64?) -> String {
        guard let b else { return "—" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

// MARK: - Klasör okuma ve izleme

enum DirectoryLoader {
    private static let queue = DispatchQueue(label: "missing.files.load", qos: .userInitiated, attributes: .concurrent)

    static func load(_ url: URL, showHidden: Bool, done: @escaping (Result<[FileItem], Error>) -> Void) {
        queue.async {
            let r: Result<[FileItem], Error>
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: FileItem.keys, options: showHidden ? [] : [.skipsHiddenFiles])
                r = .success(urls.compactMap(FileItem.init(url:)).filter { showHidden || !$0.isHidden })
            } catch {
                r = .failure(error)
            }
            DispatchQueue.main.async { done(r) }
        }
    }
}

/// Bir klasördeki değişiklikleri dinler (ekleme, silme, yeniden adlandırma); kısa bir beklemeyle haber verir
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var work: DispatchWorkItem?
    var onChange: () -> Void = {}

    func watch(_ url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib],
                                                          queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.work?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.onChange() }
            self.work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func stop() {
        work?.cancel()
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

// MARK: - Simgeler ve önizlemeler

@MainActor final class FileIcons {
    static let shared = FileIcons()
    private let icons = NSCache<NSURL, NSImage>()
    private let thumbs = NSCache<NSString, NSImage>()
    private var pending = Set<String>()

    func icon(_ url: URL) -> NSImage {
        if let i = icons.object(forKey: url as NSURL) { return i }
        var i = NSWorkspace.shared.icon(forFile: url.path)
        // Renk etiketli klasör, macOS Tahoe Finder'ındaki gibi o renge boyanır
        if let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .tagNamesKey]),
           v.isDirectory == true, v.isPackage != true,
           let color = FinderTags.folderColor(v.tagNames ?? []) {
            i = Self.tintedFolder(i, color)
        }
        icons.setObject(i, forKey: url as NSURL)
        return i
    }

    /// Klasör simgesini gölgelerini koruyarak bir renge boyar
    static func tintedFolder(_ base: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSColor.gray.set(); r.fill(using: .saturation)                // renksizleştir
            NSColor(white: 1, alpha: 0.35).set(); r.fill(using: .plusLighter)  // aç
            color.set(); r.fill(using: .multiply)                         // boya
            base.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    /// Simge görünümü için küçük önizleme; hazır değilse nil döner ve hazır olunca `ready` çağrılır
    func thumbnail(_ item: FileItem, size: CGFloat, ready: @escaping () -> Void) -> NSImage? {
        guard !item.isFolder, !item.isApp else { return nil }
        let key = "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(Int(size))" as NSString
        if let t = thumbs.object(forKey: key) { return t }
        guard !pending.contains(key as String) else { return nil }
        pending.insert(key as String)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            let img = rep?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key as String)
                if let img {
                    self.thumbs.setObject(img, forKey: key)
                    ready()
                }
            }
        }
        return nil
    }

    func forget(_ url: URL) { icons.removeObject(forKey: url as NSURL) }
}

// MARK: - Dosya işlemleri (geri alınabilir)

@MainActor enum FileOps {
    private static let fm = FileManager.default

    /// Klasörde çakışmayan ad: "Ad 2.uzantı", "Ad 3.uzantı"…
    static func unique(_ name: String, in dir: URL, isDirectory: Bool = false) -> URL {
        var dest = dir.appendingPathComponent(name, isDirectory: isDirectory)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty || isDirectory ? "\(name) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate, isDirectory: isDirectory)
            n += 1
        } while fm.fileExists(atPath: dest.path)
        return dest
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        return va != nil && va == vb
    }

    static func report(_ error: Error, in window: NSWindow?) {
        let a = NSAlert(error: error)
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    /// Bir klasör kendisinin ya da alt klasörünün içine taşınamaz
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p + "/")
    }

    // Çöp sepeti

    static func trash(_ urls: [URL], undo: UndoManager?, window: NSWindow?) {
        var moved: [(from: URL, to: URL)] = []
        for u in urls {
            var result: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &result)
                if let r = result as URL? { moved.append((u, r)) }
            } catch {
                report(error, in: window)
                break
            }
        }
        guard !moved.isEmpty else { return }
        playTrashSound()
        undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated {
                restore(moved, undo: undo, window: window)
        } }
        undo?.setActionName(L("Çöp sepetine taşı"))
    }

    private static func restore(_ moved: [(from: URL, to: URL)], undo: UndoManager?, window: NSWindow?) {
        var back: [URL] = []
        for m in moved {
            do { try fm.moveItem(at: m.to, to: m.from); back.append(m.from) } catch { report(error, in: window) }
        }
        undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated { trash(back, undo: undo, window: window) } }
        undo?.setActionName(L("Çöp sepetine taşı"))
    }

    private static func playTrashSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        if let s = NSSound(contentsOfFile: path, byReference: true) { s.play() }
    }

    // Taşı / kopyala

    enum Transfer { case move, copy }

    /// Bırakılan / yapıştırılan dosyalar. Kopyalama arka planda yapılır; bitince `done` çağrılır.
    static func transfer(_ urls: [URL], to dir: URL, mode: Transfer, undo: UndoManager?, window: NSWindow?,
                         done: (([URL]) -> Void)? = nil) {
        let sources = urls.filter { u in
            // Kendi içine taşıma / aynı yere taşıma yok
            if isInside(dir, u) { return false }
            if mode == .move && u.deletingLastPathComponent().fileKey == dir.fileKey { return false }
            return true
        }
        guard !sources.isEmpty else { done?([]); return }
        // Aynı diskte taşıma anında biter; başka diske taşıma kopyala + sil olarak ilerlemeyle yapılır
        if mode == .move, sources.allSatisfy({ sameVolume($0, dir) }) {
            var moved: [(from: URL, to: URL)] = []
            for u in sources {
                let dest = unique(u.lastPathComponent, in: dir, isDirectory: u.hasDirectoryPath)
                do { try fm.moveItem(at: u, to: dest); moved.append((u, dest)) } catch { report(error, in: window); break }
            }
            registerMoveUndo(moved, undo: undo, window: window)
            done?(moved.map(\.to))
            return
        }
        // Hedef adları şimdi ayır, işi arka planda yap
        var pairs: [(URL, URL)] = []
        var reserved = Set<String>()
        for u in sources {
            var dest = unique(u.lastPathComponent, in: dir, isDirectory: u.hasDirectoryPath)
            var n = 2
            while reserved.contains(dest.path) {
                let base = (u.lastPathComponent as NSString).deletingPathExtension
                let ext = (u.lastPathComponent as NSString).pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            reserved.insert(dest.path)
            pairs.append((u, dest))
        }
        let title = sources.count == 1 ? sources[0].lastPathComponent : L("%d öğe", sources.count)
        let job = CopyJob(title: title, destination: dir)
        let isMove = mode == .move
        FilesActivity.shared.add(job)
        let counter = job.counter
        DispatchQueue.global(qos: .userInitiated).async {
            // Önce toplam boyut (ilerleme çubuğu için)
            var sizes: [Int64] = []
            var files = 0
            for (s, _) in pairs {
                let m = FileCopier.measure(s)
                sizes.append(m.bytes)
                files += m.files
            }
            let total = sizes.reduce(0, +)
            DispatchQueue.main.async {
                job.total = total
                job.itemsTotal = files
                job.measuring = false
            }
            // Ekranı ~10 kez/sn tazele
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { MainActor.assumeIsolated { job.done = counter.done } }
            timer.resume()
            var copied: [URL] = []
            var moved: [(from: URL, to: URL)] = []
            var failure: Error?
            for (i, (s, d)) in pairs.enumerated() {
                do {
                    try FileCopier.copy(s, to: d, counter: counter)
                    counter.itemFinished(sizes[i])
                    if isMove {
                        try FileManager.default.removeItem(at: s)
                        moved.append((s, d))
                    } else {
                        copied.append(d)
                    }
                    DispatchQueue.main.async { job.itemsDone += 1 }
                } catch {
                    failure = error
                    break
                }
            }
            timer.cancel()
            DispatchQueue.main.async {
                FilesActivity.shared.remove(job)
                if let failure, (failure as? CocoaError)?.code != .userCancelled { report(failure, in: window) }
                if !copied.isEmpty {
                    undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated { trashSilently(copied, undo: undo, window: window) } }
                    undo?.setActionName(L("Kopyala"))
                }
                if !moved.isEmpty { registerMoveUndo(moved, undo: undo, window: window) }
                done?(copied + moved.map(\.to))
            }
        }
    }

    private static func registerMoveUndo(_ moved: [(from: URL, to: URL)], undo: UndoManager?, window: NSWindow?) {
        guard !moved.isEmpty else { return }
        undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated {
                var back: [(from: URL, to: URL)] = []
                for m in moved {
                    do { try fm.moveItem(at: m.to, to: m.from); back.append((m.to, m.from)) } catch { report(error, in: window) }
                }
                registerMoveUndo(back, undo: undo, window: window)
        } }
        undo?.setActionName(L("Taşı"))
    }

    /// Kopyalamanın geri alınması: kopyalar sessizce çöp sepetine
    private static func trashSilently(_ urls: [URL], undo: UndoManager?, window: NSWindow?) {
        for u in urls { try? fm.trashItem(at: u, resultingItemURL: nil) }
    }

    static func duplicate(_ urls: [URL], undo: UndoManager?, window: NSWindow?, done: (([URL]) -> Void)? = nil) {
        guard let dir = urls.first?.deletingLastPathComponent() else { return }
        transfer(urls, to: dir, mode: .copy, undo: undo, window: window, done: done)
    }

    static func newFolder(in dir: URL, name: String? = nil, color: Int? = nil, undo: UndoManager?, window: NSWindow?) -> URL? {
        let clean = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        let dest = unique(clean.isEmpty ? L("adsız klasör") : clean, in: dir, isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            report(error, in: window)
            return nil
        }
        if let color { FinderTags.setOnlyColor(color, on: dest) }
        undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated { trashSilently([dest], undo: undo, window: window) } }
        undo?.setActionName(L("Yeni klasör"))
        return dest
    }

    /// Yeniden adlandır; yeni adresi döner
    @discardableResult
    static func rename(_ url: URL, to newName: String, undo: UndoManager?, window: NSWindow?) -> URL? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        guard !name.isEmpty, name != url.lastPathComponent else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path), dest.path.lowercased() != url.path.lowercased() {
            let a = NSAlert()
            a.messageText = L("“%@” adı kullanılıyor. Başka bir ad seç.", name)
            if let window { a.beginSheetModal(for: window) } else { a.runModal() }
            return nil
        }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            report(error, in: window)
            return nil
        }
        FileIcons.shared.forget(url)
        let oldName = url.lastPathComponent
        undo?.registerUndo(withTarget: UndoTarget.shared) { _ in MainActor.assumeIsolated {
                _ = rename(dest, to: oldName, undo: undo, window: window)
        } }
        undo?.setActionName(L("Yeniden adlandır"))
        return dest
    }
}

/// Geri alma kayıtlarının hedefi (dosya işlemleri bir nesneye bağlı değil)
final class UndoTarget { static let shared = UndoTarget() }

/// Arka plandaki kopyalamalar sürerken durum çubuğunda gösterilir
@MainActor final class FilesActivity: ObservableObject {
    static let shared = FilesActivity()
    @Published private(set) var jobs: [CopyJob] = []
    var copying: Int { jobs.count }

    func add(_ j: CopyJob) { jobs.append(j) }
    func remove(_ j: CopyJob) { jobs.removeAll { $0 === j } }

    /// Bütün işlerin toplamı (durum çubuğu için)
    var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.total } }
    var doneBytes: Int64 { jobs.reduce(0) { $0 + $1.done } }
}

/// Süren bir kopyalama: kaç bayt gitti, kaç kaldı, tahmini süre
@MainActor final class CopyJob: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let destination: URL
    let started = Date()
    @Published var total: Int64 = 0
    @Published var done: Int64 = 0
    @Published var itemsTotal = 0
    @Published var itemsDone = 0
    /// Toplam boyut hesaplanırken true
    @Published var measuring = true
    let counter = CopyCounter()

    init(title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// Kalan süre (saniye); yeterli veri yoksa nil
    var remaining: TimeInterval? {
        let t = Date().timeIntervalSince(started)
        guard t > 1, done > 0, total > done else { return nil }
        return Double(total - done) / (Double(done) / t)
    }

    func cancel() { counter.cancel() }
}

/// Arka plandaki kopyalamanın sayaçları (kilitli; copyfile geri çağrısından yazılır)
final class CopyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var base: Int64 = 0      // biten üst öğelerin toplamı
    private var inItem: Int64 = 0    // üzerindeki öğede biten dosyalar
    private var current: Int64 = 0   // şu an kopyalanan dosyada giden
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var done: Int64 { lock.lock(); defer { lock.unlock() }; return base + inItem + current }
    func progress(_ bytes: Int64) { lock.lock(); current = bytes; lock.unlock() }
    func fileFinished(_ size: Int64) { lock.lock(); inItem += size; current = 0; lock.unlock() }
    func itemFinished(_ size: Int64) { lock.lock(); base += size; inItem = 0; current = 0; lock.unlock() }
}

/// copyfile ilerleme geri çağrısı: bağlam CopyCounter
private let copyProgressCallback: copyfile_callback_t = { what, stage, state, src, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let c = Unmanaged<CopyCounter>.fromOpaque(ctx).takeUnretainedValue()
    if c.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 { c.progress(Int64(copied)) }
    } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH, let src {
        var st = stat()
        if lstat(src, &st) == 0 { c.fileFinished(Int64(st.st_size)) }
    }
    return COPYFILE_CONTINUE
}

enum FileCopier {
    /// Bir dosya / klasörün toplam bayt ve dosya sayısı
    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return (0, 0) }
        guard v.isDirectory == true else { return (Int64(v.fileSize ?? 0), 1) }
        var bytes: Int64 = 0, files = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL {
            guard let r = try? u.resourceValues(forKeys: Set(keys)), r.isRegularFile == true else { continue }
            bytes += Int64(r.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    /// Bir öğeyi kopyalar (klasörse içiyle); iptal ya da hatada yarım hedef silinir
    static func copy(_ src: URL, to dst: URL, counter: CopyCounter) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let ctx = Unmanaged.passUnretained(counter).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyProgressCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        // COPYFILE_ALL (ACL | STAT | XATTR | DATA) + klasörler için RECURSIVE, bağlar izlenmez
        let flags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        if copyfile(src.path, dst.path, state, flags) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: dst)
            if counter.isCancelled { throw CocoaError(.userCancelled) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: src.path])
        }
    }
}

// MARK: - Kenar çubuğu konumları

struct SidebarPlace: Identifiable, Hashable {
    let url: URL
    let title: String
    let symbol: String
    var ejectable = false
    var removable = false
    /// Klasör olarak açılmayan Finder konumları (AirDrop, Ağ) ve izin isteyebilen Çöp Sepeti
    var special: Special?
    /// Ayarlardan gizlenebilmesi için anahtar (nil: gizlenemez)
    var hideKey: String?
    var id: String { special.map { "special:\($0)" } ?? url.path }

    enum Special: Hashable { case airdrop, network, trash }
}

/// Finder etiketi (kenar çubuğundaki Etiketler)
struct FinderTag: Identifiable, Hashable {
    let name: String
    /// NSWorkspace.fileLabelColors sırası (1 gri … 7 turuncu); renksiz etiket için nil
    let colorIndex: Int?
    var id: String { name }

    var color: Color? {
        guard let i = colorIndex, NSWorkspace.shared.fileLabelColors.indices.contains(i) else { return nil }
        return Color(nsColor: NSWorkspace.shared.fileLabelColors[i])
    }
}

enum FinderTags {
    /// Finder'ın renk adları (sistem dilinde ve İngilizce) → renk sırası
    private static let englishLabels = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    static func colorIndex(for name: String) -> Int? {
        let labels = NSWorkspace.shared.fileLabels
        if let i = labels.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), i > 0 { return i }
        if let i = englishLabels.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), i > 0 { return i }
        return nil
    }

    /// Finder'ın sağ tık menüsündeki sıra: kırmızı, turuncu, sarı, yeşil, mavi, mor, gri
    static let menuOrder = [6, 7, 5, 2, 4, 3, 1]

    /// Bir renk için kullanılacak etiket adı (kullanıcının o renkteki etiketi, yoksa sistemin renk adı)
    static func name(forColor i: Int) -> String {
        if let t = favorites().first(where: { $0.colorIndex == i }) { return t.name }
        let labels = NSWorkspace.shared.fileLabels
        return labels.indices.contains(i) ? labels[i] : englishLabels[i]
    }

    /// Renk sırasının canlı sistem rengi (Finder'ın soluk etiket renkleri yerine)
    static func nsColor(_ i: Int) -> NSColor {
        switch i {
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return .systemGray
        }
    }

    /// Etiketlerden ilk renklisinin rengi (klasör boyamak için)
    static func folderColor(_ names: [String]) -> NSColor? {
        for n in names { if let i = colorIndex(for: n) { return nsColor(i) } }
        return nil
    }

    /// Seçili dosyalarda bu renk aç / kapa: hepsinde varsa kaldır, yoksa ekle
    @MainActor static func toggle(color i: Int, on urls: [URL]) {
        let all = urls.allSatisfy { u in
            ((try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil ?? []).contains { colorIndex(for: $0) == i }
        }
        for u in urls { set(color: all ? nil : i, replacing: i, on: u) }
    }

    /// Klasörün tek rengini ayarla (nil: renkleri kaldır, adsız etiketler kalır)
    static func setOnlyColor(_ i: Int?, on u: URL) {
        var names = ((try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil) ?? []
        names.removeAll { colorIndex(for: $0) != nil }
        if let i { names.insert(name(forColor: i), at: 0) }
        write(names, to: u)
    }

    private static func set(color: Int?, replacing i: Int, on u: URL) {
        var names = ((try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil) ?? []
        names.removeAll { colorIndex(for: $0) == i }
        if let color { names.append(name(forColor: color)) }
        write(names, to: u)
    }

    private static func write(_ names: [String], to u: URL) {
        try? (u as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    /// Finder kenar çubuğundaki etiketler; okunamazsa yedi renk
    static func favorites() -> [FinderTag] {
        let names = (CFPreferencesCopyAppValue("FavoriteTagNames" as CFString, "com.apple.finder" as CFString) as? [String])?
            .filter { !$0.isEmpty }
        let list = names ?? [6, 7, 5, 2, 4, 3, 1].compactMap { i in
            NSWorkspace.shared.fileLabels.indices.contains(i) ? NSWorkspace.shared.fileLabels[i] : nil
        }
        return list.map { FinderTag(name: $0, colorIndex: colorIndex(for: $0)) }
    }

    /// Bu etiketi taşıyan dosyalar (Spotlight; arka planda çağrılır)
    static func files(tagged name: String) -> [URL] {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let q = MDQueryCreate(kCFAllocatorDefault, "kMDItemUserTags == \"\(escaped)\"" as CFString, nil, nil) else { return [] }
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var out: [URL] = []
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { out.append(URL(fileURLWithPath: path)) }
        }
        return out
    }
}

@MainActor final class FilesPlaces: ObservableObject {
    static let shared = FilesPlaces()
    @Published private(set) var favorites: [SidebarPlace] = []
    @Published private(set) var pinned: [SidebarPlace] = []
    @Published private(set) var volumes: [SidebarPlace] = []
    /// Bulut klasörleri, ana klasör, AirDrop, Ağ, Çöp Sepeti
    @Published private(set) var locations: [SidebarPlace] = []
    @Published private(set) var tags: [FinderTag] = []
    /// Ayarlardan gizlenenler
    @Published private(set) var hidden = FilesSettings.sidebarHidden

    func isVisible(_ key: String?) -> Bool {
        guard let key else { return true }
        return !hidden.contains(key)
    }

    func setVisible(_ key: String, _ on: Bool) {
        var h = hidden
        if on { h.remove(key) } else { h.insert(key) }
        guard h != hidden else { return }
        hidden = h
        FilesSettings.sidebarHidden = h
    }

    var tagsVisible: Bool { isVisible("tags") }
    static func tagKey(_ t: FinderTag) -> String { "tag:" + t.name }

    // Kenar çubuğunda görünenler
    var shownFavorites: [SidebarPlace] { favorites.filter { isVisible($0.hideKey) } }
    var shownLocations: [SidebarPlace] { (volumes + locations).filter { isVisible($0.hideKey) } }
    var shownTags: [FinderTag] { tagsVisible ? tags.filter { isVisible(Self.tagKey($0)) } : [] }

    private init() {
        rebuild()
        // Finder'da etiket ya da bulut hesabı değişmiş olabilir
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildLocations() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildVolumes() }
            }
        }
    }

    /// Finder'ın listesi okunabildiyse sık kullanılanlar onunla eşit tutulur
    private(set) var finderSynced = false
    private var finderPaths = Set<String>()
    private var observing = false

    /// README görüntüleri için: kişisel Finder listesi ve harici diskler yerine varsayılanlar
    static var demo = false

    func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var f: [SidebarPlace] = []
        if !Self.demo, let list = FinderFavorites.items(), !list.isEmpty {
            finderSynced = true
            f = list.map { SidebarPlace(url: $0.url, title: $0.name, symbol: Self.symbol(for: $0.url), hideKey: "fav:" + $0.url.fileKey) }
            if !observing {
                observing = true
                FinderFavorites.observe { [weak self] in self?.rebuild() }
            }
        } else {
            finderSynced = false
            func add(_ dir: FileManager.SearchPathDirectory) {
                if let u = fm.urls(for: dir, in: .userDomainMask).first, fm.fileExists(atPath: u.path) {
                    f.append(SidebarPlace(url: u, title: fm.displayName(atPath: u.path), symbol: Self.symbol(for: u), hideKey: "fav:" + u.fileKey))
                }
            }
            f.append(SidebarPlace(url: home, title: fm.displayName(atPath: home.path), symbol: "house", hideKey: "fav:" + home.fileKey))
            add(.desktopDirectory)
            add(.documentDirectory)
            add(.downloadsDirectory)
            add(.picturesDirectory)
            let apps = URL(fileURLWithPath: "/Applications")
            f.append(SidebarPlace(url: apps, title: fm.displayName(atPath: apps.path), symbol: Self.symbol(for: apps), hideKey: "fav:" + apps.fileKey))
        }
        finderPaths = finderSynced ? Set(f.map(\.url.fileKey)) : []
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path), !f.contains(where: { $0.url.fileKey == icloud.fileKey }) {
            f.append(SidebarPlace(url: icloud, title: "iCloud Drive", symbol: "icloud", hideKey: "icloud"))
        }
        if favorites != f { favorites = f }
        let pins = FilesSettings.pinned.compactMap { p -> SidebarPlace? in
            guard fm.fileExists(atPath: p) else { return nil }
            let u = URL(fileURLWithPath: p)
            guard !finderPaths.contains(u.fileKey) else { return nil }
            return SidebarPlace(url: u, title: fm.displayName(atPath: p), symbol: "folder")
        }
        if pinned != pins { pinned = pins }
        rebuildVolumes()
        rebuildLocations()
    }

    func rebuildLocations() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var l: [SidebarPlace] = []
        // Google Drive, OneDrive, Dropbox… (File Provider klasörleri)
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        let dirs = (try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for u in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !Self.demo {
            l.append(SidebarPlace(url: u, title: Self.cloudTitle(u), symbol: "cloud", hideKey: "cloud"))
        }
        if !favorites.contains(where: { $0.url.fileKey == home.fileKey }) {
            l.append(SidebarPlace(url: home, title: fm.displayName(atPath: home.path), symbol: "house", hideKey: "home"))
        }
        l.append(SidebarPlace(url: Self.finderApp("AirDrop"), title: "AirDrop", symbol: "airplayaudio", special: .airdrop, hideKey: "airdrop"))
        l.append(SidebarPlace(url: Self.finderApp("Network"), title: L("Ağ"), symbol: "network", special: .network, hideKey: "network"))
        l.append(SidebarPlace(url: home.appendingPathComponent(".Trash"), title: L("Çöp Sepeti"), symbol: "trash", special: .trash, hideKey: "trash"))
        if locations != l { locations = l }
        let t = FinderTags.favorites()
        if tags != t { tags = t }
    }

    private static func finderApp(_ name: String) -> URL {
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/\(name).app")
    }

    /// "GoogleDrive-ad@mail.com" → "Google Drive", "OneDrive-Personal" → "OneDrive"
    static func cloudTitle(_ u: URL) -> String {
        let shown = FileManager.default.displayName(atPath: u.path)
        if shown != u.lastPathComponent { return shown }
        let provider = String(u.lastPathComponent.split(separator: "-", maxSplits: 1).first ?? "")
        switch provider {
        case "GoogleDrive": return "Google Drive"
        case "OneDrive": return "OneDrive"
        case "Dropbox": return "Dropbox"
        case "Box": return "Box"
        default:
            // CamelCase'i kelimelere ayır
            var out = ""
            for ch in provider {
                if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
                out.append(ch)
            }
            return out.isEmpty ? u.lastPathComponent : out
        }
    }

    /// AirDrop ve Ağ Finder'da açılır; Çöp Sepeti okunamıyorsa (izin) Finder'da açılır
    func open(_ place: SidebarPlace, in controller: FilesWindowController, newTab: Bool = false) {
        switch place.special {
        case .airdrop, .network:
            NSWorkspace.shared.open(place.url)
        case .trash:
            if (try? FileManager.default.contentsOfDirectory(atPath: place.url.path)) != nil {
                controller.navigate(place.url, newTab: newTab)
            } else {
                NSWorkspace.shared.open(place.url)
            }
        case nil:
            controller.navigate(place.url, newTab: newTab)
        }
    }

    func isFinderFavorite(_ url: URL) -> Bool { finderPaths.contains(url.fileKey) }

    static func symbol(for u: URL) -> String {
        let fm = FileManager.default
        let key = u.fileKey
        func dir(_ d: FileManager.SearchPathDirectory) -> String? { fm.urls(for: d, in: .userDomainMask).first?.fileKey }
        switch key {
        case fm.homeDirectoryForCurrentUser.fileKey: return "house"
        case dir(.desktopDirectory): return "menubar.dock.rectangle"
        case dir(.documentDirectory): return "doc"
        case dir(.downloadsDirectory): return "arrow.down.circle"
        case dir(.picturesDirectory): return "photo"
        case dir(.moviesDirectory): return "film"
        case dir(.musicDirectory): return "music.note"
        case URL(fileURLWithPath: "/Applications").fileKey: return "square.grid.3x3"
        default: break
        }
        let v = try? u.resourceValues(forKeys: [.isVolumeKey, .isDirectoryKey])
        if v?.isVolume == true { return "externaldrive" }
        return v?.isDirectory == false ? "doc" : "folder"
    }

    func rebuildVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.filter { !Self.demo || $0.path == "/" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let name = v?.volumeLocalizedName ?? u.lastPathComponent
            let ejectable = v?.volumeIsEjectable ?? false
            let removable = v?.volumeIsRemovable ?? false
            let internalDisk = v?.volumeIsInternal ?? true
            let symbol = (v?.volumeIsRootFileSystem ?? false) ? "internaldrive"
                : (!internalDisk || removable || ejectable) ? "externaldrive" : "internaldrive"
            let external = !(v?.volumeIsRootFileSystem ?? false) && (!internalDisk || removable || ejectable)
            return SidebarPlace(url: u, title: name, symbol: symbol, ejectable: ejectable || removable, removable: removable,
                                hideKey: external ? "external" : "disks")
        }
    }

    /// Kenar çubuğuna ekle: Finder'ın sık kullanılanlarına gider (okunamıyorsa yalnız bizde kalır)
    func pin(_ url: URL) {
        if finderSynced {
            if !isFinderFavorite(url) { FinderFavorites.add(url) }
            rebuild()
            return
        }
        var p = FilesSettings.pinned
        guard !p.contains(url.path) else { return }
        p.append(url.path)
        FilesSettings.pinned = p
        rebuild()
    }

    func unpin(_ url: URL) {
        if isFinderFavorite(url) { FinderFavorites.remove(url) }
        FilesSettings.pinned = FilesSettings.pinned.filter { $0 != url.path }
        rebuild()
    }

    func movePinned(from: Int, to: Int) {
        var p = FilesSettings.pinned
        guard p.indices.contains(from) else { return }
        let x = p.remove(at: from)
        p.insert(x, at: min(max(0, to), p.count))
        FilesSettings.pinned = p
        rebuild()
    }

    func eject(_ place: SidebarPlace, window: NSWindow?) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: place.url)
        } catch {
            FileOps.report(error, in: window)
        }
    }
}

// MARK: - Finder sık kullanılanları

/// Finder kenar çubuğundaki "Sık kullanılanlar" listesi (sharedfilelistd üzerinden okunur ve yazılır)
@MainActor enum FinderFavorites {
    private static let list: LSSharedFileList? =
        LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    private static var onChange: (() -> Void)?

    struct Entry { let name: String; let url: URL; let item: LSSharedFileListItem }

    /// Dosya adresi olan öğeler (AirDrop, Son Kullanılanlar gibi özel öğeler atlanır)
    static func items() -> [Entry]? {
        guard list != nil else { return nil }
        let snap = allItems()
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return snap.compactMap { it in
            guard let u = LSSharedFileListItemCopyResolvedURL(it, flags, nil)?.takeRetainedValue() as URL?,
                  u.isFileURL, !u.path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: u.standardizedFileURL.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let name = LSSharedFileListItemCopyDisplayName(it).takeRetainedValue() as String
            return Entry(name: name.isEmpty ? FileManager.default.displayName(atPath: url.path) : name, url: url, item: it)
        }
    }

    static func add(_ url: URL) {
        // kLSSharedFileListItemLast gerçek bir nesne değil, Swift'ten verince çöküyor: son öğenin arkasına ekle
        guard let list, let last = allItems().last else { return }
        _ = LSSharedFileListInsertItemURL(list, last, nil, nil, url as CFURL, nil, nil)
    }

    private static func allItems() -> [LSSharedFileListItem] {
        guard let list else { return [] }
        var seed: UInt32 = 0
        return LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
    }

    static func remove(_ url: URL) {
        guard let list else { return }
        for e in items() ?? [] where e.url.fileKey == url.fileKey {
            LSSharedFileListItemRemove(list, e.item)
        }
    }

    /// Finder'da liste değişince haber ver
    static func observe(_ f: @escaping () -> Void) {
        guard let list, onChange == nil else { return }
        onChange = f
        LSSharedFileListAddObserver(list, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { FinderFavorites.onChange?() } }
        }, nil)
    }
}

// MARK: - Pencereleri yöneten

@MainActor final class FilesManager: NSObject {
    static let shared = FilesManager()
    private(set) var windows: [FilesWindowController] = []
    /// Ayarlar penceresini açmak için (AppDelegate bağlar)
    var openSettings: () -> Void = {}
    private var menuInstalled = false
    private var mouseMonitor: Any?

    var hasWindows: Bool { !windows.isEmpty }

    /// Dosya penceresini aç: açık pencere varsa öne getirir (adres verildiyse yeni sekmede açar)
    func open(_ url: URL? = nil, newWindow: Bool = false) {
        guard FilesSettings.enabled else { return }
        if !newWindow, let w = frontmost {
            if let url { w.openTab(url) }
            w.bringToFront()
            return
        }
        let urls: [URL]
        var selected = 0
        if let url {
            urls = [url]
        } else if windows.isEmpty {
            let saved = FilesSettings.lastTabs.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            urls = saved.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : saved
            selected = min(max(0, FilesSettings.lastSelectedTab), urls.count - 1)
        } else {
            urls = [frontmost?.model.current.url ?? FileManager.default.homeDirectoryForCurrentUser]
        }
        let c = FilesWindowController(urls: urls, selected: selected, cascadeFrom: frontmost?.window)
        windows.append(c)
        becomeRegular()
        c.bringToFront()
    }

    /// Klasörse yeni sekmede aç, değilse içindeki klasörde seçili göster
    func reveal(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let pkg = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isDir.boolValue && !pkg {
            open(url)
        } else {
            open(url.deletingLastPathComponent())
            frontmost?.model.current.pendingSelect = [url]
        }
    }

    var frontmost: FilesWindowController? {
        if let key = NSApp.keyWindow, let c = windows.first(where: { $0.window === key }) { return c }
        let order = NSApp.orderedWindows
        return windows.min { a, b in
            (order.firstIndex { $0 === a.window } ?? .max) < (order.firstIndex { $0 === b.window } ?? .max)
        }
    }

    func windowController(number: Int) -> FilesWindowController? {
        windows.first { $0.window?.windowNumber == number }
    }

    func closed(_ c: FilesWindowController) {
        windows.removeAll { $0 === c }
        if windows.isEmpty {
            FilesSettings.lastTabs = c.model.tabs.map(\.url.path)
            FilesSettings.lastSelectedTab = c.model.tabs.firstIndex { $0.id == c.model.currentID } ?? 0
            becomeAccessory()
        }
    }

    func closeAll() {
        for w in windows { w.window?.close() }
    }

    /// Ayardan kapatılınca
    func settingsChanged() {
        if !FilesSettings.enabled { closeAll() }
    }

    // MARK: Dock'ta görünme

    private func becomeRegular() {
        installMenu()
        installMouseButtons()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // Dock'ta yaprak değil, Finder gibi klasör
        NSApp.applicationIconImage = FilesDockIcon.app
    }

    private func becomeAccessory() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        // Ayarlar ya da başka bir pencere açıkken Dock'tan çekilmek onu arkaya atmasın: biraz bekle
        DispatchQueue.main.async {
            guard self.windows.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.applicationIconImage = nil
        }
    }

    /// Farenin yan tuşları: geri / ileri; orta tuş sekmede: kapat
    private func installMouseButtons() {
        FilesTabSwitcher.shared.install()
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] e in
            guard let self, let w = e.window, let c = self.windows.first(where: { $0.window === w }) else { return e }
            switch e.buttonNumber {
            case 3: c.goBack(nil); return nil
            case 4: c.goForward(nil); return nil
            case 2: return c.middleClick(e) ? nil : e
            default: return e
            }
        }
    }

    // MARK: Menü çubuğu (pencere öndeyken)

    private func installMenu() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            top.submenu = m
            main.addItem(top)
            return top
        }

        let settingsItem = item(L("Dosyalar Ayarları…"), #selector(FilesMenuTarget.openFilesSettings), ",")
        settingsItem.target = FilesMenuTarget.shared
        let missingSettings = item(L("Missing Ayarları…"), #selector(FilesMenuTarget.openSettings), ",", [.command, .option])
        missingSettings.target = FilesMenuTarget.shared
        let quit = item(L("Missing'den Çık"), #selector(NSApplication.terminate(_:)))   // ⌘Q yok: yanlışlıkla Missing kapanmasın
        _ = submenu("Missing", [settingsItem, missingSettings, .separator(), item(L("Missing'i gizle"), #selector(NSApplication.hide(_:)), "h"),
                                .separator(), quit])

        let newWindow = item(L("Yeni pencere"), #selector(FilesWindowController.newWindow(_:)), "n")
        _ = submenu(L("Dosya"), [
            newWindow,
            item(L("Yeni sekme"), #selector(FilesWindowController.newTab(_:)), "t"),
            item(L("Yeni klasör"), #selector(FilesWindowController.newFolder(_:)), "n", [.command, .shift]),
            .separator(),
            item(L("Aç"), #selector(FilesWindowController.openSelection(_:)), "o"),
            item(L("Yeni sekmede aç"), #selector(FilesWindowController.openSelectionInTab(_:))),
            .separator(),
            item(L("Sekmeyi kapat"), #selector(FilesWindowController.closeTab(_:)), "w"),
            item(L("Pencereyi kapat"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item(L("Yeniden adlandır"), #selector(FilesWindowController.renameSelection(_:))),
            item(L("Çoğalt"), #selector(FilesWindowController.duplicateSelection(_:)), "d"),
            item(L("Çöp sepetine taşı"), #selector(FilesWindowController.trashSelection(_:)), "\u{8}"),
            .separator(),
            item(L("Quick Look"), #selector(FilesWindowController.toggleQuickLook(_:)), "y"),
            item(L("Finder'da göster"), #selector(FilesWindowController.revealInFinder(_:)), "r", [.command, .option]),
            item(L("Kenar çubuğuna ekle"), #selector(FilesWindowController.pinSelection(_:)), "t", [.command, .control]),
        ])

        _ = submenu(L("Düzen"), [
            item(L("Geri al"), Selector(("undo:")), "z"),
            item(L("Yinele"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Kes"), #selector(NSText.cut(_:)), "x"),
            item(L("Kopyala"), #selector(NSText.copy(_:)), "c"),
            item(L("Yolu kopyala"), #selector(FilesWindowController.copyPath(_:)), "c", [.command, .option]),
            item(L("Yapıştır"), #selector(NSText.paste(_:)), "v"),
            item(L("Öğeyi buraya taşı"), #selector(FilesWindowController.moveHere(_:)), "v", [.command, .option]),
            item(L("Tümünü seç"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Bul"), #selector(FilesWindowController.focusSearch(_:)), "f"),
            item(L("Yolu düzenle"), #selector(FilesWindowController.editPath(_:)), "l"),
        ])

        _ = submenu(L("Görünüm"), [
            item(L("Liste"), #selector(FilesWindowController.showList(_:)), "1"),
            item(L("Simgeler"), #selector(FilesWindowController.showGrid(_:)), "2"),
            item(L("Sütunlar"), #selector(FilesWindowController.showColumns(_:)), "3"),
            .separator(),
            item(L("Gizli dosyaları göster"), #selector(FilesWindowController.toggleHidden(_:)), ".", [.command, .shift]),
            item(L("Kenar çubuğu"), #selector(FilesWindowController.toggleSidebar(_:)), "s", [.command, .option]),
            item(L("Önizleme bölmesi"), #selector(FilesWindowController.togglePreview(_:)), "p", [.command, .shift]),
            item(L("Yenile"), #selector(FilesWindowController.reload(_:)), "r"),
            .separator(),
            themeMenu(),
        ])

        let up = item(L("Üst klasör"), #selector(FilesWindowController.goUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = item(L("Seçileni aç"), #selector(FilesWindowController.openSelection(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!))
        _ = submenu(L("Git"), [
            item(L("Geri"), #selector(FilesWindowController.goBack(_:)), "["),
            item(L("İleri"), #selector(FilesWindowController.goForward(_:)), "]"),
            up, down,
            .separator(),
            placeItem(L("Ev"), FileManager.default.homeDirectoryForCurrentUser, "h"),
            placeItem(L("Masaüstü"), dir(.desktopDirectory), "d"),
            placeItem(L("Belgeler"), dir(.documentDirectory), "o"),
            placeItem(L("İndirilenler"), dir(.downloadsDirectory), "l", [.command, .option]),
            placeItem(L("Uygulamalar"), URL(fileURLWithPath: "/Applications"), "a"),
            placeItem("iCloud Drive", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), "i"),
            .separator(),
            item(L("Klasöre git…"), #selector(FilesWindowController.goToFolder(_:)), "g", [.command, .shift]),
        ])

        let window = submenu(L("Pencere"), [
            item(L("Dock'a küçült"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Büyüt"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(L("Sonraki sekme"), #selector(FilesWindowController.nextTab(_:)), "\t", [.control]),
            item(L("Önceki sekme"), #selector(FilesWindowController.previousTab(_:)), "\t", [.control, .shift]),
            item(L("Sonraki sekme"), #selector(FilesWindowController.nextTab(_:)), "}", [.command]),
            item(L("Önceki sekme"), #selector(FilesWindowController.previousTab(_:)), "{", [.command]),
        ])
        // ⌘⇧] / ⌘⇧[ ikinci kısayollar menüde gizli dursun
        window.submenu?.items.suffix(2).forEach { $0.isAlternate = false; $0.isHidden = true; $0.allowsKeyEquivalentWhenHidden = true }
        NSApp.windowsMenu = window.submenu
        NSApp.mainMenu = main
    }

    private func dir(_ d: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: d, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func themeMenu() -> NSMenuItem {
        let top = NSMenuItem(title: L("Tema"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: L("Tema"))
        for t in FilesTheme.allCases {
            let i = NSMenuItem(title: t.title, action: #selector(FilesWindowController.setTheme(_:)), keyEquivalent: "")
            i.representedObject = t.rawValue
            m.addItem(i)
        }
        top.submenu = m
        return top
    }

    private func placeItem(_ title: String, _ url: URL, _ key: String, _ mods: NSEvent.ModifierFlags = [.command, .shift]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(FilesWindowController.goToPlace(_:)), keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.representedObject = url
        return i
    }
}

/// Menüde pencereye bağlı olmayan eylemler
@MainActor final class FilesMenuTarget: NSObject {
    static let shared = FilesMenuTarget()
    @objc func openSettings() { FilesManager.shared.openSettings() }
    @objc func openFilesSettings() { FilesSettingsWindow.shared.show() }
    @objc func newWindow() { FilesManager.shared.open(newWindow: true) }
}

// MARK: - Dock'ta tut

/// Missing'i Dock'a sabitler (macOS'taki Seçenekler › Dock'ta Tut ile aynı kayıt)
@MainActor enum DockPin {
    private static let dock = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    private static var apps: [[String: Any]] {
        CFPreferencesAppSynchronize(dock)
        return CFPreferencesCopyAppValue(key, dock) as? [[String: Any]] ?? []
    }

    private static func path(of tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
              let s = file["_CFURLString"] as? String else { return nil }
        let u = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
        return u?.standardizedFileURL.path
    }

    static var isPinned: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        return apps.contains { path(of: $0) == me }
    }

    static func pin() {
        guard !isPinned else { return }
        let url = Bundle.main.bundleURL
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": "Missing",
                "bundle-identifier": Bundle.main.bundleIdentifier ?? "",
                "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
            ] as [String: Any],
        ]
        CFPreferencesSetAppValue(key, (apps + [tile]) as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
        // Dock yeni kaydı okusun
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
