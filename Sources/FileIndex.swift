import Foundation
import CoreServices

// MARK: - Dosya adı indeksi (⌘Space dosya arama)
//
// Diskteki dosya ADLARI bir kez taranır, bellekte sıkışık tamponlarda tutulur ve FSEvents ile güncel kalır.
// Dosya içeriği okunmaz. İndeks sadece bu Mac'te, ~/Library/Application Support/AudioTab/fileindex.bin
// dosyasında saklanır; hiçbir yere gönderilmez. Bütün durum tek bir seri kuyrukta yaşar.

struct FileHit: Sendable {
    let id: Int32
    let score: Int32
}

/// Arama sonucu satırı (ana iş parçacığına bu gider)
struct FileResult: Sendable, Hashable {
    let path: String
    let name: String
    let isDir: Bool
    let mtime: Date
    /// Adda eşleşen kısım (UTF-16 aralığı, vurgu için); yoksa nil
    let match: NSRange?
}

enum FileIndexState: Equatable, Sendable {
    case idle
    case scanning(Int)
    case ready(Int)
}

final class FileIndex: @unchecked Sendable {
    static let shared = FileIndex()
    let queue = DispatchQueue(label: "com.firewallstudio.audiotab.fileindex", qos: .userInitiated)

    // Bayraklar
    private static let fDir: UInt8 = 1
    private static let fDead: UInt8 = 2
    private static let fPackage: UInt8 = 4
    private static let fRoot: UInt8 = 8

    // Kayıtlar (hepsi aynı uzunlukta, sıra = kimlik)
    private var parent: [Int32] = []
    private var flags: [UInt8] = []
    private var mtime: [Int32] = []          // 2001'den beri saniye
    private var nameStart: [Int32] = []
    private var nameLen: [UInt16] = []
    private var foldStart: [Int32] = []
    private var foldLen: [UInt16] = []
    private var nameBuf: [UInt8] = []        // asıl adlar (UTF-8)
    private var foldBuf: [UInt8] = []        // küçük harf + aksansız adlar, aralarında 0
    private var dirIndex: [String: Int32] = [:]
    private var kids: [Int32: [Int32]] = [:]
    private var deadCount = 0
    private var stamps: [UInt32] = []
    private var stamp: UInt32 = 0

    private var stream: FSEventStreamRef?
    private var lastEventID: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    private var dirty = false
    private var started = false
    private var saveTimer: DispatchSourceTimer?
    /// Tarama sürerken kapatma: kuyruk dışından okunur/yazılır
    private let cancelLock = NSLock()
    private var cancelFlag = false
    private var cancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelFlag }
        set { cancelLock.lock(); cancelFlag = newValue; cancelLock.unlock() }
    }

    /// Durum değişince ana iş parçacığında çağrılır
    var onState: (@MainActor (FileIndexState) -> Void)?
    private(set) var state: FileIndexState = .idle

    private var count: Int { parent.count }

    // MARK: Ayarlar

    /// İçine girilmeyen klasör adları (küçük harf)
    static let skipNames: Set<String> = ["node_modules", "__pycache__", "deriveddata", ".git", ".svn", ".trash",
                                         "pods", ".build", ".cache", "caches", ".venv", "venv"]
    /// Dosya gibi davranan paketler: kendisi listelenir, içi taranmaz
    static let packageExts: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary",
                                           "musiclibrary", "tvlibrary", "fcpbundle", "imovielibrary", "rtfd", "pages",
                                           "numbers", "key", "xcodeproj", "xcworkspace", "playground", "sparsebundle",
                                           "lrlibrary", "lrdata", "logicx", "band", "dSYM", "qlgenerator", "mdimporter",
                                           "prefpane", "saver", "wdgt", "photosLibrary", "aplibrary", "drp", "dra",
                                           "fcpxbundle", "motn", "lpdf", "scptd", "workflow", "action", "sketch", "xcassets"]
        .reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    static var home: String { NSHomeDirectory() }

    /// Taranan kökler: ev klasörü, uygulamalar, iCloud Drive, harici diskler
    static func roots() -> [String] {
        var r: [String] = [home, "/Applications"]
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { r.append(icloud) }
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            guard let rv = try? v.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.volumeIsRootFileSystem == true { continue }
            if rv.volumeIsLocal != true || rv.volumeIsBrowsable != true { continue }
            guard v.path.hasPrefix("/Volumes/") else { continue }
            r.append(v.path)
        }
        return r
    }

    /// Ev klasöründe atlanan yerler (iCloud Drive ayrı kök olarak taranır)
    private static func isExcludedPath(_ p: String) -> Bool {
        let h = home
        if p == h + "/Library" { return true }
        if p == h + "/.Trash" { return true }
        return false
    }

    // MARK: Başlat / durdur

    func start() {
        cancelled = false
        queue.async {
            guard !self.started else { return }
            self.started = true
            if self.load() {
                self.publish(.ready(self.aliveCount()))
                self.startStream(since: self.lastEventID)
            } else {
                self.fullScan()
            }
            self.startSaveTimer()
        }
    }

    func stop() {
        cancelled = true   // süren taramayı hemen bırak
        queue.sync {
            self.stopStream()
            self.saveTimer?.cancel()
            self.saveTimer = nil
            if self.dirty, case .ready = self.state { self.save() }
            self.started = false
            self.reset()
            self.state = .idle
        }
    }

    /// Ayarlardan "Yeniden tara"
    func rebuild() {
        cancelled = false
        queue.async {
            guard self.started else { return }
            self.stopStream()
            self.reset()
            self.fullScan()
        }
    }

    func saveIfDirty() {
        queue.async { if self.dirty { self.save() } }
    }

    private func reset() {
        parent = []; flags = []; mtime = []; nameStart = []; nameLen = []
        foldStart = []; foldLen = []; nameBuf = []; foldBuf = []
        dirIndex = [:]; kids = [:]; deadCount = 0; stamps = []; stamp = 0
    }

    private func publish(_ s: FileIndexState) {
        state = s
        let cb = onState
        DispatchQueue.main.async { MainActor.assumeIsolated { cb?(s) } }
    }

    private func aliveCount() -> Int { count - deadCount }

    // MARK: Tarama

    private func fullScan() {
        let since = FSEventsGetCurrentEventId()
        publish(.scanning(0))
        reserve(600_000)
        for root in Self.roots() {
            let rid = addRoot(root)
            scanTree(path: root, parentID: rid)
        }
        if cancelled { return }   // yarım indeks kaydedilmez; sonraki açılışta baştan
        lastEventID = since
        dirty = true
        save()
        publish(.ready(aliveCount()))
        startStream(since: since)
    }

    private func reserve(_ n: Int) {
        parent.reserveCapacity(n); flags.reserveCapacity(n); mtime.reserveCapacity(n)
        nameStart.reserveCapacity(n); nameLen.reserveCapacity(n); foldStart.reserveCapacity(n); foldLen.reserveCapacity(n)
        nameBuf.reserveCapacity(n * 20); foldBuf.reserveCapacity(n * 21)
    }

    private func addRoot(_ path: String) -> Int32 {
        if let existing = dirIndex[path] { return existing }
        let id = append(name: Array(path.utf8), parent: -1, flags: Self.fDir | Self.fRoot, mtime: 0)
        dirIndex[path] = id
        return id
    }

    @discardableResult
    private func append(name: [UInt8], parent p: Int32, flags f: UInt8, mtime m: Int32) -> Int32 {
        let id = Int32(count)
        parent.append(p)
        flags.append(f)
        mtime.append(m)
        nameStart.append(Int32(nameBuf.count))
        let nl = min(name.count, Int(UInt16.max))
        nameLen.append(UInt16(nl))
        nameBuf.append(contentsOf: name.prefix(nl))
        let folded = Self.fold(bytes: name)
        foldStart.append(Int32(foldBuf.count))
        let fl = min(folded.count, Int(UInt16.max))
        foldLen.append(UInt16(fl))
        foldBuf.append(contentsOf: folded.prefix(fl))
        foldBuf.append(0)
        if p >= 0 { kids[p, default: []].append(id) }
        return id
    }

    /// Bir klasörü (ve altını) tarar; klasörün kendisi zaten eklenmiş olmalı (parentID).
    private func scanTree(path: String, parentID: Int32) {
        guard let cpath = strdup(path) else { return }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }

        var levelIDs: [Int32] = [parentID]
        let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name) ?? 0
        var added = 0
        let lastPublish = Date()
        var nextPublish = lastPublish.addingTimeInterval(0.5)

        while let ent = fts_read(fts) {
            if added & 0x3FF == 0 && cancelled { break }
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            if level == 0 { continue }     // kökün kendisi
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }

            let nlen = Int(ent.pointee.fts_namelen)
            let raw = UnsafeRawPointer(ent).advanced(by: nameOffset).assumingMemoryBound(to: UInt8.self)
            let nameBytes = Array(UnsafeBufferPointer(start: raw, count: nlen))
            let first: UInt8 = nlen > 0 ? nameBytes[0] : 0
            let isDir = info == FTS_D || info == FTS_DC

            // Gizli dosyalar (.ile başlayan) atlanır
            if first == UInt8(ascii: ".") {
                if isDir { fts_set(fts, ent, FTS_SKIP) }
                continue
            }
            if nameBytes == Array("Icon\r".utf8) || nameBytes == Array(".DS_Store".utf8) { continue }

            let p: Int32 = level - 1 < levelIDs.count ? levelIDs[level - 1] : parentID
            var m: Int32 = 0
            if let st = ent.pointee.fts_statp {
                m = Int32(clamping: st.pointee.st_mtimespec.tv_sec - 978_307_200)
            }

            if isDir {
                let nameStr = String(decoding: nameBytes, as: UTF8.self)
                let lower = nameStr.lowercased()
                let fullPath = String(cString: ent.pointee.fts_path)
                if Self.skipNames.contains(lower) || Self.isExcludedPath(fullPath) {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                let ext = (lower as NSString).pathExtension
                if !ext.isEmpty && Self.packageExts.contains(ext) {
                    fts_set(fts, ent, FTS_SKIP)
                    append(name: nameBytes, parent: p, flags: Self.fPackage, mtime: m)
                    added += 1
                    continue
                }
                let id = append(name: nameBytes, parent: p, flags: Self.fDir, mtime: m)
                dirIndex[fullPath] = id
                if levelIDs.count > level { levelIDs[level] = id } else { levelIDs.append(id) }
                added += 1
            } else {
                append(name: nameBytes, parent: p, flags: 0, mtime: m)
                added += 1
            }

            if added & 0x3FFF == 0 {
                let now = Date()
                if now >= nextPublish {
                    nextPublish = now.addingTimeInterval(0.5)
                    if case .scanning = state { publish(.scanning(aliveCount())) }
                }
            }
        }
    }

    // MARK: Değişiklikler (FSEvents)

    private func startStream(since: FSEventStreamEventId) {
        stopStream()
        let paths = Self.roots() as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, flagsPtr, ids in
            guard let info else { return }
            let me = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var items: [(String, FSEventStreamEventFlags)] = []
            items.reserveCapacity(n)
            for i in 0..<min(n, arr.count) {
                if let s = arr[i] as? String { items.append((s, flagsPtr[i])) }
            }
            let last = n > 0 ? ids[n - 1] : 0
            me.handle(items, lastID: last)   // zaten kendi kuyruğumuzdayız
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths, since, 1.5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(_ items: [(String, FSEventStreamEventFlags)], lastID: FSEventStreamEventId) {
        var shallow = Set<String>()
        var deep = Set<String>()
        var rootsChanged = false
        for (raw, f) in items {
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootsChanged = true; continue }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
                rootsChanged = true; continue
            }
            var p = raw
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            let must = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                               | kFSEventStreamEventFlagKernelDropped)
            if f & must != 0 { deep.insert(p) } else { shallow.insert(p) }
        }
        if lastID > 0 { lastEventID = lastID }
        if rootsChanged { syncRoots() }
        for p in deep { rescan(path: p, deep: true) }
        for p in shallow where !deep.contains(p) { rescan(path: p, deep: false) }
        if !deep.isEmpty || !shallow.isEmpty { dirty = true }
        if case .ready = state { publish(.ready(aliveCount())) }
    }

    /// Disk takılıp çıkarılınca kökleri güncelle
    private func syncRoots() {
        let want = Set(Self.roots())
        for (path, id) in dirIndex where flags[Int(id)] & Self.fRoot != 0 && !want.contains(path) {
            kill(id, includeSelf: true)
            dirIndex[path] = nil
        }
        for r in want where dirIndex[r] == nil {
            let rid = addRoot(r)
            scanTree(path: r, parentID: rid)
        }
        startStream(since: lastEventID)
    }

    /// Bir klasördeki değişikliği uygula. deep: altını tamamen yeniden tara.
    private func rescan(path: String, deep: Bool) {
        guard let id = dirIndex[path] else {
            // Yeni bir klasör olabilir: üst klasörü taranıyorsa onu sığ tara
            let up = (path as NSString).deletingLastPathComponent
            if up != path, dirIndex[up] != nil, !Self.isExcludedPath(path) { rescan(path: up, deep: false) }
            return
        }
        if flags[Int(id)] & Self.fDead != 0 { return }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
            if flags[Int(id)] & Self.fRoot == 0 { kill(id, includeSelf: true) }
            return
        }
        if deep {
            kill(id, includeSelf: false)
            scanTree(path: path, parentID: id)
            return
        }
        // Sığ: klasörün çocuklarını diskle karşılaştır
        var existing: [String: Int32] = [:]
        for k in kids[id] ?? [] where flags[Int(k)] & Self.fDead == 0 {
            existing[name(of: k)] = k
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        var seen = Set<String>()
        for n in names {
            if n.hasPrefix(".") || n == "Icon\r" { continue }
            seen.insert(n)
            let full = path + "/" + n
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let m = Int32(clamping: st.st_mtimespec.tv_sec - 978_307_200)
            let dir = (st.st_mode & S_IFMT) == S_IFDIR
            if let k = existing[n] {
                mtime[Int(k)] = m
                continue
            }
            if dir {
                let lower = n.lowercased()
                if Self.skipNames.contains(lower) || Self.isExcludedPath(full) { continue }
                let ext = (lower as NSString).pathExtension
                if !ext.isEmpty && Self.packageExts.contains(ext) {
                    append(name: Array(n.utf8), parent: id, flags: Self.fPackage, mtime: m)
                } else {
                    let nid = append(name: Array(n.utf8), parent: id, flags: Self.fDir, mtime: m)
                    dirIndex[full] = nid
                    scanTree(path: full, parentID: nid)   // içine taşınmış klasör
                }
            } else {
                append(name: Array(n.utf8), parent: id, flags: 0, mtime: m)
            }
        }
        for (n, k) in existing where !seen.contains(n) { kill(k, includeSelf: true) }
    }

    /// Kaydı (ve altındakileri) sil olarak işaretle
    private func kill(_ id: Int32, includeSelf: Bool) {
        var stack: [Int32] = includeSelf ? [id] : (kids[id] ?? [])
        if !includeSelf { kids[id] = [] }
        while let k = stack.popLast() {
            let i = Int(k)
            if flags[i] & Self.fDead != 0 { continue }
            flags[i] |= Self.fDead
            deadCount += 1
            if flags[i] & Self.fDir != 0 {
                dirIndex[path(of: k)] = nil
                if let c = kids[k] { stack.append(contentsOf: c) }
                kids[k] = nil
            }
        }
        if includeSelf, parent[Int(id)] >= 0 {
            let p = parent[Int(id)]
            kids[p]?.removeAll { $0 == id }
        }
    }

    // MARK: Okuma yardımcıları

    func name(of id: Int32) -> String {
        let s = Int(nameStart[Int(id)]), l = Int(nameLen[Int(id)])
        return nameBuf.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[s..<(s + l)]), as: UTF8.self) }
    }

    func path(of id: Int32) -> String {
        var parts: [String] = []
        var cur = id
        var guardCount = 0
        while cur >= 0 && guardCount < 256 {
            parts.append(name(of: cur))
            if flags[Int(cur)] & Self.fRoot != 0 { break }
            cur = parent[Int(cur)]
            guardCount += 1
        }
        return parts.reversed().joined(separator: "/")
    }

    private func isDirEntry(_ id: Int32) -> Bool { flags[Int(id)] & Self.fDir != 0 }

    // MARK: Ad katlama (küçük harf + aksansız; Türkçe ı/İ → i)

    static func fold(bytes: [UInt8]) -> [UInt8] {
        var ascii = true
        for b in bytes where b >= 0x80 { ascii = false; break }
        if ascii {
            var out = bytes
            for i in 0..<out.count where out[i] >= 65 && out[i] <= 90 { out[i] += 32 }
            return out
        }
        return Array(fold(String(decoding: bytes, as: UTF8.self)).utf8)
    }

    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return f.replacingOccurrences(of: "ı", with: "i")
    }

    // MARK: Kalıcı kayıt

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioTab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fileindex.bin")
    }

    private static let magic: UInt32 = 0x41544649   // "ATFI"
    private static let formatVersion: UInt32 = 1

    private func startSaveTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 600, repeating: 600, leeway: .seconds(60))
        t.setEventHandler { [weak self] in
            guard let self, self.dirty else { return }
            self.save()
        }
        t.resume()
        saveTimer = t
    }

    /// Canlı kayıtları ağaç sırasıyla yazar (silinenler atılır → dosya hep sıkışık)
    private func save() {
        var out = Data()
        out.reserveCapacity(nameBuf.count + aliveCount() * 12 + 64)
        func put<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        put(Self.magic); put(Self.formatVersion); put(UInt64(lastEventID))
        let countPos = out.count
        put(UInt32(0))

        var newID: [Int32: Int32] = [:]
        var written: UInt32 = 0
        let rootIDs = dirIndex.values.filter { flags[Int($0)] & Self.fRoot != 0 && flags[Int($0)] & Self.fDead == 0 }.sorted()
        for r in rootIDs {
            var stack: [Int32] = [r]
            while let k = stack.popLast() {
                let i = Int(k)
                if flags[i] & Self.fDead != 0 { continue }
                let p = parent[i]
                let np: Int32 = p >= 0 ? (newID[p] ?? -1) : -1
                if flags[i] & Self.fRoot == 0 && np < 0 { continue }
                newID[k] = Int32(written)
                put(np); put(flags[i]); put(mtime[i])
                let s = Int(nameStart[i]), l = Int(nameLen[i])
                put(UInt16(l))
                out.append(contentsOf: nameBuf[s..<(s + l)])
                written += 1
                if let c = kids[k] { stack.append(contentsOf: c.reversed()) }
            }
        }
        var wc = written.littleEndian
        withUnsafeBytes(of: &wc) { out.replaceSubrange(countPos..<(countPos + 4), with: $0) }
        if (try? out.write(to: Self.fileURL, options: .atomic)) != nil { dirty = false }
        // Çok fazla silinmiş kayıt birikmişse bellekteki indeksi de sıkıştır
        if deadCount > 50_000 && deadCount * 4 > count { _ = load() }
    }

    private func load() -> Bool {
        guard let data = try? Data(contentsOf: Self.fileURL, options: .mappedIfSafe), data.count >= 20 else { return false }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            var pos = 0
            func get<T: FixedWidthInteger>(_: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard pos + size <= buf.count else { return nil }
                let v = buf.loadUnaligned(fromByteOffset: pos, as: T.self)
                pos += size
                return T(littleEndian: v)
            }
            guard get(UInt32.self) == Self.magic, get(UInt32.self) == Self.formatVersion,
                  let ev = get(UInt64.self), let n = get(UInt32.self) else { return false }
            // Olay kimliği şimdikinden büyükse (başka Mac'ten taşınmış / sıfırlanmış) baştan tara
            if ev > UInt64(FSEventsGetCurrentEventId()) { return false }
            reset()
            reserve(Int(n) + 50_000)
            var paths: [Int32: String] = [:]
            for _ in 0..<n {
                guard let p = get(Int32.self), let f = get(UInt8.self), let m = get(Int32.self),
                      let l = get(UInt16.self), pos + Int(l) <= buf.count else { reset(); return false }
                let bytes = Array(buf[pos..<(pos + Int(l))])
                pos += Int(l)
                let id = append(name: bytes, parent: p, flags: f & ~Self.fDead, mtime: m)
                if f & Self.fDir != 0 {
                    let full: String
                    if f & Self.fRoot != 0 { full = String(decoding: bytes, as: UTF8.self) }
                    else { full = (paths[p] ?? "") + "/" + String(decoding: bytes, as: UTF8.self) }
                    paths[id] = full
                    dirIndex[full] = id
                }
            }
            lastEventID = FSEventStreamEventId(ev)
            dirty = false
            return true
        }
    }

    // MARK: Arama

    struct Query: Sendable {
        var tokens: [[UInt8]]        // katlanmış kelimeler
        var ext: String? = nil       // "pdf rapor" → pdf
        var dirsOnly = false
        var scope: String? = nil     // bu klasörün altında
        var boosts: [String: Int32] = [:]   // tam yol → ek puan (daha önce seçilenler)
        var limit = 60
    }

    /// Kuyrukta çalışır. generation: daha yeni bir arama başladıysa erken bırak.
    func search(_ q: Query, isStale: () -> Bool) -> [FileResult] {
        let n = count
        guard n > 0 else { return [] }
        var scopeID: Int32 = -1
        if let s = q.scope {
            if let id = dirIndex[s] { scopeID = id }
            else { scopeID = addTemporaryRoot(s) }
            if scopeID < 0 { return [] }
        }

        // Boş arama + klasör: klasörün içeriği (Finder gibi)
        if q.tokens.isEmpty {
            guard scopeID >= 0 else { return [] }
            let list = (kids[scopeID] ?? []).filter { flags[Int($0)] & Self.fDead == 0 }
            var rows: [(Int32, String, Bool)] = list.map { ($0, name(of: $0), isDirEntry($0)) }
            rows.sort { a, b in
                if a.2 != b.2 { return a.2 }
                return a.1.localizedStandardCompare(b.1) == .orderedAscending
            }
            return rows.prefix(500).map { makeResult($0.0, tokens: []) }
        }

        if stamps.count < n { stamps.append(contentsOf: repeatElement(0, count: n - stamps.count)) }
        stamp &+= 1
        if stamp == 0 { for i in 0..<stamps.count { stamps[i] = 0 }; stamp = 1 }

        var boostIDs: [Int32: Int32] = [:]
        for (p, b) in q.boosts { if let id = lookup(path: p) { boostIDs[id] = b } }

        let now = Int32(clamping: Int(Date().timeIntervalSinceReferenceDate))
        let homeID = dirIndex[Self.home] ?? -1
        let favIDs: Set<Int32> = Set(["Desktop", "Documents", "Downloads"].compactMap { dirIndex[Self.home + "/" + $0] }
                                     + [dirIndex[Self.home + "/Library/Mobile Documents/com~apple~CloudDocs"]].compactMap { $0 })
        let appsID = dirIndex["/Applications"] ?? -1

        var top: [FileHit] = []
        top.reserveCapacity(q.limit + 1)
        var minTop: Int32 = Int32.min

        // Her kelimenin adda geçtiği kayıtlar adaydır; her aday tüm kelimeler için (ad + üst klasörler) denetlenir
        let tokens = q.tokens
        for token in tokens {
            if isStale() { return [] }
            guard !token.isEmpty else { continue }
            foldBuf.withUnsafeBufferPointer { fb in
                foldStart.withUnsafeBufferPointer { fs in
                    token.withUnsafeBufferPointer { tk in
                        guard let base = fb.baseAddress, let tbase = tk.baseAddress else { return }
                        let total = fb.count
                        var pos = 0
                        var cursor = 0
                        while pos < total {
                            guard let hit = memmem(base + pos, total - pos, tbase, tk.count) else { break }
                            let hpos = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                            // Kaydı bul (konumlar artan sırada → imleç ileri gider; uzak sıçramada ikili arama)
                            if cursor + 1 < n && Int(fs[cursor + 1]) <= hpos {
                                if cursor + 64 < n && Int(fs[cursor + 64]) <= hpos {
                                    var lo = cursor, hi = n - 1
                                    while lo < hi {
                                        let mid = (lo + hi + 1) / 2
                                        if Int(fs[mid]) <= hpos { lo = mid } else { hi = mid - 1 }
                                    }
                                    cursor = lo
                                } else {
                                    while cursor + 1 < n && Int(fs[cursor + 1]) <= hpos { cursor += 1 }
                                }
                            }
                            let id = Int32(cursor)
                            pos = cursor + 1 < n ? Int(fs[cursor + 1]) : total
                            if stamps[cursor] == stamp { continue }
                            stamps[cursor] = stamp
                            guard let sc = score(id, q: q, scopeID: scopeID, now: now, homeID: homeID,
                                                 favIDs: favIDs, appsID: appsID, boostIDs: boostIDs) else { continue }
                            if top.count < q.limit || sc > minTop {
                                var lo = 0, hi = top.count
                                while lo < hi { let mid = (lo + hi) / 2; if top[mid].score >= sc { lo = mid + 1 } else { hi = mid } }
                                top.insert(FileHit(id: id, score: sc), at: lo)
                                if top.count > q.limit { top.removeLast() }
                                minTop = top.count >= q.limit ? top[top.count - 1].score : Int32.min
                            }
                        }
                    }
                }
            }
        }
        return top.map { makeResult($0.id, tokens: tokens) }
    }

    private func foldSlice(_ id: Int32) -> ArraySlice<UInt8> {
        let s = Int(foldStart[Int(id)]), l = Int(foldLen[Int(id)])
        return foldBuf[s..<(s + l)]
    }

    private static func find(_ hay: ArraySlice<UInt8>, _ needle: [UInt8]) -> Int? {
        guard needle.count <= hay.count, !needle.isEmpty else { return nil }
        return hay.withUnsafeBufferPointer { h -> Int? in
            needle.withUnsafeBufferPointer { nd -> Int? in
                guard let hb = h.baseAddress, let nb = nd.baseAddress,
                      let r = memmem(hb, h.count, nb, nd.count) else { return nil }
                return hb.distance(to: r.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b >= 0x80
    }

    /// nil → eşleşmiyor. Puan büyükse üstte.
    private func score(_ id: Int32, q: Query, scopeID: Int32, now: Int32, homeID: Int32,
                       favIDs: Set<Int32>, appsID: Int32, boostIDs: [Int32: Int32]) -> Int32? {
        let i = Int(id)
        let f = flags[i]
        if f & (Self.fDead | Self.fRoot) != 0 { return nil }
        let isDir = f & Self.fDir != 0
        if q.dirsOnly && !isDir { return nil }

        let fname = foldSlice(id)
        if let ext = q.ext {
            guard !isDir, let dot = fname.lastIndex(of: UInt8(ascii: ".")) else { return nil }
            let e = fname[(dot + 1)...]
            if !e.elementsEqual(ext.utf8) { return nil }
        }

        // Üst klasör zinciri (kapsam + kelime denetimi için)
        var ancestors: [Int32] = []
        var cur = parent[i]
        var inScope = scopeID < 0
        var depth = 0
        var nearFav = false
        var inHome = false
        var inApps = false
        while cur >= 0 && depth < 128 {
            if cur == scopeID { inScope = true }
            if favIDs.contains(cur) { nearFav = true }
            if cur == homeID { inHome = true }
            if cur == appsID { inApps = true }
            if flags[Int(cur)] & Self.fRoot != 0 { break }
            ancestors.append(cur)
            cur = parent[Int(cur)]
            depth += 1
        }
        if !inScope { return nil }

        var total: Int32 = 0
        var nameHits = 0
        for t in q.tokens {
            if let at = Self.find(fname, t) {
                nameHits += 1
                let start = fname.startIndex
                let off = at
                let len = fname.count
                // Uzantısız ad
                var baseLen = len
                if !isDir, let dot = fname.lastIndex(of: UInt8(ascii: ".")), dot > start { baseLen = dot - start }
                var s: Int32
                if off == 0 && t.count == baseLen { s = 1000 }            // tam ad
                else if off == 0 && t.count == len { s = 1000 }
                else if off == 0 { s = 800 }                               // adla başlıyor
                else if !Self.isWordByte(fname[start + off - 1]) { s = 600 } // kelime başı
                else { s = 350 }                                           // ortada
                total += s
            } else {
                // Kelime adda yok: üst klasörlerden birinde olmalı
                var found = false
                for a in ancestors where Self.find(foldSlice(a), t) != nil { found = true; break }
                if !found { return nil }
                total += 150
            }
        }
        if nameHits == 0 { return nil }

        // Kısa ad daha iyi, derin klasör daha kötü
        total -= Int32(min(fname.count, 80)) * 2
        total -= Int32(min(depth, 20)) * 10

        if nearFav { total += 150 } else if inHome { total += 50 }
        if inApps && f & Self.fPackage != 0 { total += 120 }

        let age = now - mtime[i]
        if age < 86_400 { total += 120 }
        else if age < 7 * 86_400 { total += 80 }
        else if age < 30 * 86_400 { total += 40 }
        else if age < 365 * 86_400 { total += 10 }

        if let dot = fname.lastIndex(of: UInt8(ascii: ".")), !isDir {
            let e = String(decoding: fname[(dot + 1)...], as: UTF8.self)
            if Self.noiseExts.contains(e) { total -= 200 }
            else if Self.docExts.contains(e) { total += 40 }
        }
        if let b = boostIDs[id] { total += b }
        return total
    }

    static let docExts: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt",
                                       "md", "rtf", "png", "jpg", "jpeg", "heic", "gif", "psd", "ai", "mov", "mp4", "m4v",
                                       "mp3", "wav", "m4a", "aif", "aiff", "zip", "dmg", "csv", "drp", "braw", "mxf", "fig", "sketch"]
    static let noiseExts: Set<String> = ["plist", "log", "tmp", "o", "d", "dylib", "strings", "nib", "car", "lproj", "dat",
                                         "db-wal", "db-shm", "sqlite-wal", "sqlite-shm", "lock", "pyc", "map", "cache", "ds_store"]

    private func makeResult(_ id: Int32, tokens: [[UInt8]]) -> FileResult {
        let nm = name(of: id)
        var match: NSRange? = nil
        if let t = tokens.first(where: { Self.find(foldSlice(id), $0) != nil }) {
            let needle = String(decoding: t, as: UTF8.self)
            let r = (nm as NSString).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            if r.location != NSNotFound { match = r }
        }
        let isDir = flags[Int(id)] & Self.fDir != 0
        return FileResult(path: path(of: id), name: nm, isDir: isDir,
                          mtime: Date(timeIntervalSinceReferenceDate: TimeInterval(mtime[Int(id)])), match: match)
    }

    /// Tam yoldan kayıt (klasör sözlüğü + çocuk adları)
    private func lookup(path p: String) -> Int32? {
        if let d = dirIndex[p] { return d }
        let up = (p as NSString).deletingLastPathComponent
        let nm = (p as NSString).lastPathComponent
        guard let pid = dirIndex[up] else { return nil }
        return kids[pid]?.first { flags[Int($0)] & Self.fDead == 0 && name(of: $0) == nm }
    }

    /// Kapsam indekste değilse (ör. ağ diski, ~/Library) o klasörü geçici kök olarak tara
    private func addTemporaryRoot(_ path: String) -> Int32 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return -1 }
        let rid = addRoot(path)
        scanTree(path: path, parentID: rid)
        return rid
    }

    /// Klasörün içi (boş aramada gezinme). Kuyrukta çalışır.
    func isIndexed(_ path: String) -> Bool { dirIndex[path] != nil }
}
