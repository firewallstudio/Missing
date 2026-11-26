import AppKit
import AVFoundation
import Combine
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hızlı işlemler (sağ tık)
//
// Bilgi Al, Sıkıştır / Aç, görsel döndürme · dönüştürme · boyutlandırma, görsellerden PDF, PDF birleştirme,
// video dönüştürme / küçültme, sesi çıkarma, takma ad, paket içeriği, iCloud indirme.
// Uzun işler arka planda çalışır; ilerleme kopyalama kartında görünür, bitince sonuç seçili gelir.

@MainActor enum FilesQuickActions {
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "cpio", "xar"]

    /// Sağ tık menüsüne eklenecekler
    static func menuItems(for sel: [FileItem], controller: FilesWindowController) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let urls = sel.map(\.url)
        func item(_ title: String, _ kind: Kind, _ urls: [URL] = urls, _ symbol: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(QuickTarget.quickAction(_:)), keyEquivalent: "")
            i.target = QuickTarget.shared
            i.representedObject = Request(kind: kind, urls: urls, controller: controller)
            if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                img.isTemplate = true
                i.image = img
            }
            return i
        }

        let info = item(L("Bilgi al"), .info, urls, "info.circle")
        info.keyEquivalent = "i"
        info.keyEquivalentModifierMask = [.command]
        out.append(info)

        let archives = sel.filter { archiveExtensions.contains($0.url.pathExtension.lowercased()) }
        if !archives.isEmpty, archives.count == sel.count {
            out.append(item(L("Buraya aç"), .extract, urls, "archivebox"))
        }
        out.append(item(sel.count == 1 ? L("“%@” öğesini sıkıştır", sel[0].name) : L("%d öğeyi sıkıştır", sel.count), .compress, urls, "doc.zipper"))

        if let quick = quickMenu(for: sel, item: item) { out.append(quick) }

        if sel.count == 1 {
            let it = sel[0]
            let v = try? it.url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            if (v?.isAliasFile ?? false) || (v?.isSymbolicLink ?? false) {
                out.append(item(L("Aslını göster"), .showOriginal, urls, "arrow.uturn.right"))
            }
            if it.isPackage {
                out.append(item(L("Paket içeriğini göster"), .packageContents, urls, "shippingbox"))
            }
        }
        out.append(item(L("Takma ad oluştur"), .alias, urls, "arrowshape.turn.up.right"))

        let cloud = urls.filter { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true }
        if !cloud.isEmpty {
            out.append(item(L("Şimdi indir"), .download, cloud, "icloud.and.arrow.down"))
            out.append(item(L("İndirileni kaldır"), .evict, cloud, "icloud.slash"))
        }
        return out
    }

    /// Seçilenlerin türüne göre "Hızlı işlemler" alt menüsü
    private static func quickMenu(for sel: [FileItem], item: (String, Kind, [URL], String?) -> NSMenuItem) -> NSMenuItem? {
        func sub(_ title: String, _ symbol: String, _ children: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { img.isTemplate = true; top.image = img }
            let m = NSMenu()
            children.forEach(m.addItem)
            top.submenu = m
            return top
        }
        let images = sel.filter { conforms($0.url, .image) && !$0.isFolder }
        let pdfs = sel.filter { conforms($0.url, .pdf) }
        let videos = sel.filter { conforms($0.url, .movie) }
        let audio = sel.filter { conforms($0.url, .audio) && !conforms($0.url, .movie) }
        let menu = NSMenu()

        if !images.isEmpty, images.count == sel.count {
            let u = images.map(\.url)
            menu.addItem(item(L("Sola döndür"), .rotate(-90), u, "rotate.left"))
            menu.addItem(item(L("Sağa döndür"), .rotate(90), u, "rotate.right"))
            // Hepsi zaten o biçimdeyse o seçenek görünmez
            let conv = [("JPEG", "jpeg"), ("PNG", "png"), ("HEIC", "heic"), ("TIFF", "tiff")]
                .filter { f in !u.allSatisfy { sameFormat($0, f.1) } }
                .map { f in item(f.0, .convertImage(f.1), u.filter { !sameFormat($0, f.1) }, nil) }
            if !conv.isEmpty { menu.addItem(sub(L("Dönüştür"), "arrow.triangle.2.circlepath", conv)) }
            menu.addItem(sub(L("Boyutlandır"), "arrow.down.right.and.arrow.up.left",
                             [3840, 2560, 1920, 1280, 800].map { item(L("En fazla %d piksel", $0), .resize($0), u, nil) }))
            menu.addItem(item(images.count == 1 ? L("PDF oluştur") : L("%d görselden PDF oluştur", images.count), .imagesToPDF, u, "doc.richtext"))
        }
        if !pdfs.isEmpty, pdfs.count == sel.count {
            let u = pdfs.map(\.url)
            if pdfs.count >= 2 { menu.addItem(item(L("PDF'leri birleştir"), .mergePDF, u, "doc.on.doc")) }
            menu.addItem(item(L("Sayfaları görsele dönüştür (PNG)"), .pdfToImages, u, "photo.on.rectangle"))
        }
        if !videos.isEmpty, videos.count == sel.count {
            let u = videos.map(\.url)
            // Tek video: kes, kırp, başına / sonuna ekle (FilesMediaEditor)
            if videos.count == 1 { menu.addItem(item(L("Düzenle…"), .edit, u, "scissors")) }
            let conv = [(L("MP4 (H.264)"), AVAssetExportPresetHighestQuality, "mp4"),
                        (L("MOV (HEVC)"), AVAssetExportPresetHEVCHighestQuality, "mov")]
                .filter { f in !u.allSatisfy { sameFormat($0, f.2) } }
                .map { f in item(f.0, .video(f.1, f.2), u.filter { !sameFormat($0, f.2) }, nil) }
            if !conv.isEmpty { menu.addItem(sub(L("Dönüştür"), "arrow.triangle.2.circlepath", conv)) }
            menu.addItem(sub(L("Boyutu küçült"), "arrow.down.right.and.arrow.up.left", [
                item(L("1080p"), .video(AVAssetExportPreset1920x1080, "mp4"), u, nil),
                item(L("720p"), .video(AVAssetExportPreset1280x720, "mp4"), u, nil),
                item(L("480p"), .video(AVAssetExportPreset640x480, "mp4"), u, nil),
            ]))
            menu.addItem(item(L("Sesi çıkar (M4A)"), .video(AVAssetExportPresetAppleM4A, "m4a"), u, "waveform"))
        }
        if !audio.isEmpty, audio.count == sel.count {
            let u = audio.map(\.url)
            if audio.count == 1 { menu.addItem(item(L("Düzenle…"), .edit, u, "scissors")) }
            let conv = [("M4A (AAC)", "m4af", "aac", "m4a"), ("WAV", "WAVE", "LEI16", "wav"), ("AIFF", "AIFF", "BEI16", "aiff")]
                .filter { f in !u.allSatisfy { sameFormat($0, f.3) } }
                .map { f in item(f.0, .audio(f.1, f.2, f.3), u.filter { !sameFormat($0, f.3) }, nil) }
            if !conv.isEmpty { menu.addItem(sub(L("Dönüştür"), "arrow.triangle.2.circlepath", conv)) }
        }
        let sub = menu
        guard sub.numberOfItems > 0 else { return nil }
        let top = NSMenuItem(title: L("Hızlı işlemler"), action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil) { img.isTemplate = true; top.image = img }
        top.submenu = sub
        return top
    }

    /// Dosya zaten bu biçimde mi (jpg = jpeg, tif = tiff, aif = aiff, heif = heic)
    nonisolated static func sameFormat(_ u: URL, _ format: String) -> Bool {
        let alias = ["jpg": "jpeg", "tif": "tiff", "aif": "aiff", "heif": "heic", "m4v": "mp4"]
        let e = u.pathExtension.lowercased()
        return (alias[e] ?? e) == format
    }

    nonisolated static func conforms(_ u: URL, _ t: UTType) -> Bool {
        (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: t) ?? false
    }

    // MARK: İstek

    enum Kind {
        case info, compress, extract, alias, showOriginal, packageContents, download, evict
        case rotate(Int), convertImage(String), resize(Int), imagesToPDF, mergePDF, pdfToImages
        case video(String, String)
        case audio(String, String, String)   // afconvert dosya biçimi, veri biçimi, uzantı
        case edit                             // ses / video düzenleyici
    }

    final class Request: NSObject {
        let kind: Kind
        let urls: [URL]
        weak var controller: FilesWindowController?
        init(kind: Kind, urls: [URL], controller: FilesWindowController) {
            self.kind = kind; self.urls = urls; self.controller = controller
        }
    }

    final class QuickTarget: NSObject {
        static let shared = QuickTarget()
        // NSObject'in perform(_:) (performSelector:) adıyla çakışmasın: ayrı ad
        @objc(missingQuickAction:) func quickAction(_ sender: NSMenuItem) {
            guard let r = sender.representedObject as? Request else { return }
            MainActor.assumeIsolated { FilesQuickActions.perform(r.kind, r.urls, r.controller) }
        }
    }

    static func perform(_ kind: Kind, _ urls: [URL], _ c: FilesWindowController?) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        switch kind {
        case .info:
            for u in urls.prefix(5) { FilesInfoWindow.show(u) }
        case .edit:
            FilesMediaEditor.open(first, from: c, sourceFrame: c?.browser.screenFrame(of: first))
        case .showOriginal:
            if let orig = try? URL(resolvingAliasFileAt: first, options: [.withoutUI]) {
                FilesManager.shared.reveal(orig)
            } else { NSSound.beep() }
        case .packageContents:
            c?.navigate(first)
        case .alias:
            run(L("Takma ad"), urls, dir: dir, c) { u, _ in
                let dest = uniqueURL(u.lastPathComponent + " " + L("takma adı"), in: u.deletingLastPathComponent())
                let data = try u.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: dest)
                return dest
            }
        case .download:
            for u in urls { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
        case .evict:
            for u in urls { try? FileManager.default.evictUbiquitousItem(at: u) }
        case .compress:
            compress(urls, dir: dir, c)
        case .extract:
            run(L("Açılıyor"), urls, dir: dir, c) { u, _ in try extract(u) }
        case .rotate(let deg):
            run(L("Döndürülüyor"), urls, dir: dir, c) { u, _ in
                try tool("/usr/bin/sips", ["-r", String(deg < 0 ? 270 : deg), u.path])
                return u
            }
        case .convertImage(let fmt):
            run(L("Dönüştürülüyor"), urls, dir: dir, c) { u, _ in
                let ext = fmt == "jpeg" ? "jpg" : fmt
                let dest = uniqueURL(u.deletingPathExtension().lastPathComponent + "." + ext, in: u.deletingLastPathComponent())
                try tool("/usr/bin/sips", ["-s", "format", fmt, u.path, "--out", dest.path])
                return dest
            }
        case .resize(let px):
            run(L("Boyutlandırılıyor"), urls, dir: dir, c) { u, _ in
                let name = u.deletingPathExtension().lastPathComponent + " (\(px))" + (u.pathExtension.isEmpty ? "" : "." + u.pathExtension)
                let dest = uniqueURL(name, in: u.deletingLastPathComponent())
                try tool("/usr/bin/sips", ["-Z", String(px), u.path, "--out", dest.path])
                return dest
            }
        case .imagesToPDF:
            runOnce(L("PDF oluşturuluyor"), dir: dir, c) {
                let doc = PDFDocument()
                for u in urls {
                    if let img = NSImage(contentsOf: u), let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
                }
                let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : L("Görseller")
                let dest = uniqueURL(base + ".pdf", in: dir)
                guard doc.pageCount > 0, doc.write(to: dest) else { throw QuickError.failed }
                return [dest]
            }
        case .mergePDF:
            runOnce(L("PDF'ler birleştiriliyor"), dir: dir, c) {
                guard let doc = PDFDocument(url: urls[0]) else { throw QuickError.failed }
                for u in urls.dropFirst() {
                    guard let other = PDFDocument(url: u) else { continue }
                    for i in 0..<other.pageCount { if let p = other.page(at: i) { doc.insert(p, at: doc.pageCount) } }
                }
                let dest = uniqueURL(L("Birleştirilmiş") + ".pdf", in: dir)
                guard doc.write(to: dest) else { throw QuickError.failed }
                return [dest]
            }
        case .video(let preset, let ext):
            run(L("Dönüştürülüyor"), urls, dir: dir, c) { u, counter in
                try export(u, preset: preset, ext: ext, counter: counter)
            }
        case .audio(let file, let data, let ext):
            run(L("Dönüştürülüyor"), urls, dir: dir, c) { u, _ in
                let dest = uniqueURL(u.deletingPathExtension().lastPathComponent + "." + ext, in: u.deletingLastPathComponent())
                try tool("/usr/bin/afconvert", ["-f", file, "-d", data, u.path, dest.path])
                return dest
            }
        case .pdfToImages:
            run(L("Dönüştürülüyor"), urls, dir: dir, c) { u, _ in
                guard let doc = PDFDocument(url: u) else { throw QuickError.failed }
                let folder = uniqueURL(u.deletingPathExtension().lastPathComponent, in: u.deletingLastPathComponent())
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let box = page.bounds(for: .mediaBox)
                    let scale: CGFloat = 2
                    let img = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
                    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try png.write(to: folder.appendingPathComponent(String(format: "%03d.png", i + 1)))
                }
                return folder
            }
        }
    }

    // MARK: Çalıştırıcı

    enum QuickError: LocalizedError {
        case failed, tool(String)
        var errorDescription: String? {
            switch self {
            case .failed: return L("İşlem tamamlanamadı")
            case .tool(let m): return m
            }
        }
    }

    /// Her öğe için arka planda iş; ilerleme kartı, bitince sonuçlar seçili
    private static func run(_ title: String, _ urls: [URL], dir: URL, _ c: FilesWindowController?,
                            _ work: @escaping @Sendable (URL, CopyCounter) throws -> URL) {
        let job = CopyJob(title: title, destination: dir)
        job.countsItems = true
        job.measuring = false
        job.total = Int64(urls.count)
        FilesActivity.shared.add(job)
        let counter = job.counter
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [URL] = []
            var failure: Error?
            for u in urls {
                if counter.isCancelled { break }
                do { results.append(try work(u, counter)) } catch { failure = error }
                DispatchQueue.main.async { MainActor.assumeIsolated { job.done += 1 } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(job, results, failure, c) }
            }
        }
    }

    private static func runOnce(_ title: String, dir: URL, _ c: FilesWindowController?,
                                _ work: @escaping @Sendable () throws -> [URL]) {
        let job = CopyJob(title: title, destination: dir)
        job.countsItems = true
        job.measuring = false
        job.total = 1
        FilesActivity.shared.add(job)
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [URL] = []
            var failure: Error?
            do { results = try work() } catch { failure = error }
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(job, results, failure, c) } }
        }
    }

    private static func finish(_ job: CopyJob, _ results: [URL], _ failure: Error?, _ c: FilesWindowController?) {
        FilesActivity.shared.remove(job)
        if let failure { FileOps.report(failure, in: c?.window) }
        guard let c else { return }
        let tab = c.model.current
        let inHere = results.filter { $0.deletingLastPathComponent().fileKey == tab.url.fileKey }
        if !inHere.isEmpty { tab.pendingSelect = inHere }
        tab.reload()
    }

    // MARK: Araçlar

    nonisolated static func uniqueURL(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var u = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: u.path) else { return u }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: u.path)
        return u
    }

    @discardableResult
    nonisolated static func tool(_ path: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw QuickError.tool(msg.isEmpty ? L("İşlem tamamlanamadı") : msg) }
        return msg
    }

    /// Tek öğe: "Ad.zip"; birden çok öğe: "Arşiv.zip" (Finder gibi)
    private static func compress(_ urls: [URL], dir: URL, _ c: FilesWindowController?) {
        let parents = Set(urls.map { $0.deletingLastPathComponent().fileKey })
        runOnce(L("Sıkıştırılıyor"), dir: dir, c) {
            if urls.count == 1 {
                let dest = uniqueURL(urls[0].lastPathComponent + ".zip", in: dir)
                try tool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, dest.path])
                return [dest]
            }
            guard parents.count == 1 else { throw QuickError.tool(L("Farklı klasörlerdeki öğeler birlikte sıkıştırılamaz")) }
            let dest = uniqueURL(L("Arşiv") + ".zip", in: dir)
            try tool("/usr/bin/zip", ["-r", "-y", "-q", dest.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store"], cwd: dir)
            return [dest]
        }
    }

    /// Arşivi yanına, kendi adında bir klasöre açar
    nonisolated private static func extract(_ u: URL) throws -> URL {
        let base = u.deletingPathExtension().deletingPathExtension().lastPathComponent
        let dest = uniqueURL(base, in: u.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        do {
            if u.pathExtension.lowercased() == "zip" {
                try tool("/usr/bin/ditto", ["-x", "-k", u.path, dest.path])
            } else {
                try tool("/usr/bin/tar", ["-xf", u.path, "-C", dest.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        // İçinde tek klasör varsa onu yukarı al (Finder gibi "Ad/Ad" olmasın)
        if let inner = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent != "__MACOSX" }), inner.count == 1,
           (try? inner[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let up = uniqueURL(inner[0].lastPathComponent, in: u.deletingLastPathComponent())
            if (try? FileManager.default.moveItem(at: inner[0], to: up)) != nil {
                try? FileManager.default.removeItem(at: dest)
                return up
            }
        }
        return dest
    }

    /// Video / ses dönüştürme (AVFoundation)
    nonisolated private static func export(_ u: URL, preset: String, ext: String, counter: CopyCounter) throws -> URL {
        let asset = AVURLAsset(url: u)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw QuickError.failed }
        let suffix = preset == AVAssetExportPreset1920x1080 ? " (1080p)" : preset == AVAssetExportPreset1280x720 ? " (720p)"
            : preset == AVAssetExportPreset640x480 ? " (480p)" : ""
        let dest = uniqueURL(u.deletingPathExtension().lastPathComponent + suffix + "." + ext, in: u.deletingLastPathComponent())
        s.outputURL = dest
        s.outputFileType = ext == "m4a" ? .m4a : ext == "mov" ? .mov : .mp4
        s.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        s.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.3) == .timedOut {
            if counter.isCancelled { s.cancelExport() }
        }
        guard s.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            if let e = s.error { throw e }
            throw QuickError.failed
        }
        return dest
    }
}

// MARK: - Bilgi Al (⌘I)
//
// Seçili temaya uyar: finder → Finder'ın Bilgi penceresi (açılır kapanır bölümler),
// windows → Gezgin'in "Özellikler" penceresi, missing / glass → cam kartlar. Tema değişince pencere de değişir.

@MainActor enum FilesInfoWindow {
    private static var open: [String: NSWindow] = [:]
    private static var themeWatch: AnyCancellable?

    static func show(_ url: URL) {
        let key = url.fileKey
        if let w = open[key] { w.makeKeyAndOrderFront(nil); return }
        let w = FilesInfoPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("%@ Bilgileri", FileManager.default.displayName(atPath: url.path))
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        // Pencere arka plandan sürüklenmez: SwiftUI düğmelerine basarken fare biraz kayınca pencere kayıyor,
        // tık düğmeye ulaşmıyordu. Taşımak için başlık şeridi (FilesWindowDragArea) ve başlık çubuğu var.
        w.isMovableByWindowBackground = false
        let host = FilesDialogHostingView(rootView: content(for: url, close: { [weak w] in w?.close() },
                                                            relayout: { [weak w] in
            // İçerik değişti (bilgiler yüklendi, bölüm açıldı / kapandı): bir tur sonra yeniden ölç
            DispatchQueue.main.async { MainActor.assumeIsolated { if let w { fit(w) } } }
        }))
        // Boyu SwiftUI'nin ideal boyu değil, çizildiği genişlikteki gerçek boy belirlesin (bkz. `fit`):
        // ideal boy çok satırlı yazılarda kısa kalıyor, alttaki düğmeler kesiliyordu
        host.sizingOptions = [.intrinsicContentSize]
        w.contentView = host
        style(w, resize: false)
        w.setContentSize(host.fittingSize)
        let cascade = CGFloat(open.count * 20)
        if let main = NSApp.keyWindow ?? NSApp.mainWindow, main.isVisible, !(main is FilesInfoPanel) {
            let f = main.frame
            w.setFrameTopLeftPoint(NSPoint(x: f.maxX - w.frame.width - 20 - cascade, y: f.maxY - 40 - cascade))
        } else if let last = open.values.first(where: { $0.isVisible }) {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 20 + cascade, y: last.frame.maxY - 20 - cascade))
        } else { w.center() }
        open[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[key] = nil }
        }
        if themeWatch == nil {
            themeWatch = FilesThemeStore.shared.$theme.dropFirst().sink { _ in
                // @Published değeri yazılmadan önce yayınlar: bir tur sonra uygula
                DispatchQueue.main.async { MainActor.assumeIsolated { open.values.forEach { style($0) } } }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// "Birlikte aç" seçimi: bu dosya bu uygulamayla açılsın (deneme düzeneği kaydedici koyar)
    static var setDefaultApp: (URL, URL) -> Void = { app, file in
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: file) { _ in }
    }
    /// "Hepsini değiştir…": bu türdeki bütün dosyalar
    static var setDefaultAppForType: (URL, UTType) -> Void = { app, type in
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in }
    }

    /// Pencerenin içeriği (deneme düzeneği de bunu çizer)
    static func content(for url: URL, close: @escaping () -> Void = {}, relayout: @escaping () -> Void = {}) -> some View {
        FilesThemedRoot { _ in
            FilesInfoView(url: url, close: close, relayout: relayout)
                // Başlık çubuğu saydamken (finder dışı) içerik en üstten başlar: güvenli alan payı
                // içeriği 32 pt aşağı itiyor, trafik ışıkları kartın dışında boşlukta kalıyordu
                .ignoresSafeArea()
        }
    }

    /// Pencere çerçevesi temaya göre: finder normal başlık çubuğu; diğerleri başlıksız, içerik en üstten başlar
    static func style(_ w: NSWindow, resize: Bool = true) {
        let t = FilesThemeStore.shared.theme
        if t == .finder { w.styleMask.remove(.fullSizeContentView) } else { w.styleMask.insert(.fullSizeContentView) }
        w.titlebarAppearsTransparent = t != .finder
        w.titleVisibility = t == .finder ? .visible : .hidden
        let clear = t == .missing || t == .glass
        w.isOpaque = !clear
        w.backgroundColor = clear ? .clear : .windowBackgroundColor
        w.appearance = t == .missing ? NSAppearance(named: .darkAqua) : nil
        guard resize else { return }
        // Yeni temanın içeriği bir tur sonra ölçülür; üst kenar yerinde kalır
        DispatchQueue.main.async { MainActor.assumeIsolated { fit(w) } }
    }

    /// Pencereyi içeriğin tam boyuna getirir (üst kenar sabit)
    static func fit(_ w: NSWindow) {
        guard let c = w.contentView else { return }
        c.layoutSubtreeIfNeeded()
        let top = w.frame.maxY
        let size = w.frameRect(forContentRect: NSRect(origin: .zero, size: c.fittingSize)).size
        if size != w.frame.size {
            w.setFrame(NSRect(x: w.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        }
        w.invalidateShadow()
    }
}

/// Bilgi penceresi: ⌘W bu pencereyi kapatır (yoksa menüdeki ⌘W ana pencereye gidip Dosyalar sekmesini kapatıyordu)
final class FilesInfoPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct FilesInfoView: View {
    let url: URL
    var close: () -> Void = {}
    /// Pencere boyu içeriğe yeniden uysun
    var relayout: () -> Void = {}
    @Environment(\.filesPalette) private var p
    @State private var size: String = "…"
    @State private var bytes: String = "…"
    @State private var locked = false
    @State private var hideExt = false
    @State private var apps: [URL] = []
    @State private var app: URL?
    /// finder: açık bölümler
    @State private var expanded: Set<String> = ["general", "more", "name", "openWith"]
    /// Kilit / uzantı değişince gösterilen bilgiler yeniden okunsun
    @State private var refresh = 0

    private var values: URLResourceValues? {
        // Yeni URL: önbellekteki eski değerler gösterilmesin (kilit / uzantı değişince yeniden okunur)
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                          .contentAccessDateKey, .isDirectoryKey, .isPackageKey, .contentTypeKey])
    }

    /// Gösterilen bilgiler (her temada aynı alanlar)
    private struct Info {
        var name: String
        var kind: String
        var location: String
        var created: String
        var modified: String
        var lastOpened: String?
        var dims: String?
        var isFolder: Bool
        var contentType: UTType?
    }

    private var info: Info {
        let v = values
        let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        return Info(name: FileManager.default.displayName(atPath: url.path),
                    kind: v?.localizedTypeDescription ?? "—",
                    location: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                    created: date(v?.creationDate),
                    modified: date(v?.contentModificationDate),
                    lastOpened: isFolder ? nil : date(v?.contentAccessDate),
                    dims: imageSize,
                    isFolder: isFolder,
                    contentType: v?.contentType)
    }

    var body: some View {
        let _ = refresh
        let i = info
        Group {
            switch p.theme {
            case .finder: finderLayout(i)
            case .windows: windowsLayout(i)
            case .missing, .glass: cardLayout(i)
            }
        }
        .foregroundStyle(p.fg)
        .task { await load() }
        .onChange(of: expanded) { _ in relayout() }
    }

    // MARK: Ortak denetimler (davranış her temada aynı)

    private var icon: Image { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)) }

    @ViewBuilder private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        switch p.theme {
        case .missing:
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn).toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
        case .glass:
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        case .finder, .windows:
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
        }
    }

    // Değişiklik yalnız kullanıcı dokununca dosyaya yazılır (yükleme sırasında değil); sonra dosyadan geri okunur
    private var lockedToggle: some View {
        toggle(L("Kilitli"), Binding(get: { locked }, set: { on in
            var rv = URLResourceValues(); rv.isUserImmutable = on
            var u = URL(fileURLWithPath: url.path); try? u.setResourceValues(rv)
            readFlags()
        }))
    }

    private var hideExtToggle: some View {
        toggle(L("Uzantıyı gizle"), Binding(get: { hideExt }, set: { on in
            var rv = URLResourceValues(); rv.hasHiddenExtension = on
            var u = URL(fileURLWithPath: url.path); try? u.setResourceValues(rv)
            readFlags()
        }))
    }

    private func readFlags() {
        let rv = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isUserImmutableKey, .hasHiddenExtensionKey])
        locked = rv?.isUserImmutable ?? false
        hideExt = rv?.hasHiddenExtension ?? false
        refresh &+= 1
        relayout()
    }

    private var appPicker: some View {
        Picker("", selection: Binding(get: { app }, set: { a in
            guard let a, a != app else { return }
            app = a
            FilesInfoWindow.setDefaultApp(a, url)
        })) {
            ForEach(apps, id: \.self) { a in
                Text(FileManager.default.displayName(atPath: a.path)).tag(Optional(a))
            }
        }
        .labelsHidden()
    }

    private func changeAllButton(_ type: UTType?, small: Bool = true) -> some View {
        Button(L("Hepsini değiştir…")) {
            guard let a = app, let t = type else { return }
            FilesInfoWindow.setDefaultAppForType(a, t)
        }
        .filesButton(.normal, p, small: small)
        .help(L("Bu türdeki bütün dosyalar bu uygulamayla açılsın"))
    }

    // MARK: finder: Finder'ın Bilgi penceresi

    private func finderLayout(_ i: Info) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                icon.resizable().interpolation(.high).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(i.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 6)
                        Text(bytes).font(.system(size: 13)).monospacedDigit().lineLimit(1).layoutPriority(1)
                    }
                    Text(L("Değiştirilme") + ": " + i.modified).font(.system(size: 11)).foregroundStyle(p.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            finderSection("general", L("Genel")) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 4) {
                    finderRow(L("Tür"), i.kind)
                    finderRow(L("Boyut"), size)
                    finderRow(L("Konum"), i.location)
                    finderRow(L("Oluşturulma"), i.created)
                    finderRow(L("Değiştirilme"), i.modified)
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        lockedToggle.padding(.top, 4)
                    }
                }
            }
            if i.lastOpened != nil || i.dims != nil {
                Divider()
                finderSection("more", L("Daha fazla bilgi")) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 4) {
                        if let o = i.lastOpened { finderRow(L("Son açılma"), o) }
                        if let d = i.dims { finderRow(L("Ölçüler"), d) }
                    }
                }
            }
            if !i.isFolder {
                Divider()
                finderSection("name", L("Ad ve uzantı")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(p.fg.opacity(0.15), lineWidth: 1))
                        hideExtToggle
                    }
                }
                if !apps.isEmpty {
                    Divider()
                    finderSection("openWith", L("Birlikte aç")) {
                        VStack(alignment: .leading, spacing: 6) {
                            appPicker.controlSize(.small)
                            Text(L("Bu türdeki bütün dosyalar bu uygulamayla açılsın"))
                                .font(.system(size: 11)).foregroundStyle(p.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            changeAllButton(i.contentType)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func finderSection<C: View>(_ id: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let on = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { if on { expanded.remove(id) } else { expanded.insert(id) } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(p.secondary)
                        .rotationEffect(.degrees(on ? 90 : 0))
                        .frame(width: 12)
                    Text(title + ":").font(.system(size: 11, weight: .bold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if on { content().padding(.leading, 16) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func finderRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k + ":").font(.system(size: 11, weight: .medium)).foregroundStyle(p.secondary)
                .gridColumnAlignment(.trailing)
            Text(v).lineLimit(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: windows: Gezgin'in Özellikler penceresi

    private func windowsLayout(_ i: Info) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Başlık çubuğu (trafik ışıklarının yanında)
            HStack(spacing: 7) {
                icon.resizable().interpolation(.high).frame(width: 16, height: 16)
                Text(L("%@ Bilgileri", i.name)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 80)
            .padding(.trailing, 12)
            .frame(height: 32)
            .allowsHitTesting(false)   // başlık yazısı da pencereyi taşısın (alttaki sürükleme alanı)
            .background(FilesWindowDragArea())
            // Sekme: Windows 11 seçim çubuğu
            HStack {
                VStack(spacing: 4) {
                    Text(L("Genel")).font(.system(size: 13, weight: .semibold))
                    Capsule().fill(p.accent).frame(width: 18, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .background(FilesWindowDragArea())
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    icon.resizable().interpolation(.high).frame(width: 36, height: 36)
                    Text(i.name).font(.system(size: 12.5)).lineLimit(2).textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(p.dark ? Color(white: 0.2) : .white))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(p.dialogBorder, lineWidth: 1))
                }
                .padding(.bottom, 12)
                winLine
                winRow(L("Tür"), i.kind)
                if !i.isFolder, !apps.isEmpty {
                    // Düğme açılır menünün altında: yan yana sığmıyor, Türkçe etiket kesiliyordu
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L("Birlikte aç") + ":").frame(width: 108, alignment: .leading).foregroundStyle(p.fg.opacity(0.8))
                        VStack(alignment: .leading, spacing: 6) {
                            appPicker.controlSize(.small).frame(maxWidth: .infinity)
                            changeAllButton(i.contentType).fixedSize()
                        }
                    }
                    .padding(.vertical, 4)
                }
                winLine
                winRow(L("Konum"), i.location)
                winRow(L("Boyut"), size)
                winLine
                winRow(L("Oluşturulma"), i.created)
                winRow(L("Değiştirilme"), i.modified)
                if let o = i.lastOpened { winRow(L("Son açılma"), o) }
                if let d = i.dims { winRow(L("Ölçüler"), d) }
                winLine
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("Öznitelikler") + ":").frame(width: 108, alignment: .leading).foregroundStyle(p.fg.opacity(0.8))
                    VStack(alignment: .leading, spacing: 6) {
                        lockedToggle
                        if !i.isFolder { hideExtToggle }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
            .font(.system(size: 12))
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.winSurface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.dialogBorder, lineWidth: 1))
            .padding(.horizontal, 12)
            HStack {
                Spacer()
                Button(L("Tamam"), action: close)
                    .filesButton(.primary, p)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 390)
        .background(p.winBand)
    }

    private var winLine: some View {
        Rectangle().fill(p.divider).frame(height: 1).padding(.vertical, 6)
    }

    private func winRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k + ":").frame(width: 108, alignment: .leading).foregroundStyle(p.fg.opacity(0.8))
            Text(v).lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    // MARK: missing / glass: cam kartlar

    private func cardLayout(_ i: Info) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                icon.resizable().interpolation(.high).frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(i.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text(i.kind).font(.system(size: 11.5)).foregroundStyle(p.secondary).lineLimit(1)
                    Text(size).font(.system(size: 11.5)).foregroundStyle(p.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22)   // trafik ışıklarına yer
            // Kartın üst şeridi pencereyi taşır (başlık çubuğu yok)
            .background(FilesWindowDragArea().padding(.horizontal, -16).padding(.top, -16))
            card(L("Genel")) {
                cardRow(L("Boyut"), size)
                cardRow(L("Konum"), i.location)
                cardRow(L("Oluşturulma"), i.created)
                cardRow(L("Değiştirilme"), i.modified)
                if let o = i.lastOpened { cardRow(L("Son açılma"), o) }
                if let d = i.dims { cardRow(L("Ölçüler"), d) }
            }
            card(L("Öznitelikler")) {
                lockedToggle
                if !i.isFolder { hideExtToggle }
            }
            if !i.isFolder, !apps.isEmpty {
                card(L("Birlikte aç")) {
                    appPicker.frame(maxWidth: .infinity)
                    HStack {
                        Spacer()
                        changeAllButton(i.contentType)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 320)
        .modifier(FilesDialogSurface())
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Büyük harf uygulamanın diline göre (İngilizce "with" → "WİTH" olmasın)
            Text(title.uppercased(with: Locale(identifier: AppLanguage.active.rawValue)))
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(p.secondary)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.cardStroke, lineWidth: 1))
    }

    private func cardRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).foregroundStyle(p.secondary)
            Spacer(minLength: 8)
            Text(v).multilineTextAlignment(.trailing).lineLimit(3).textSelection(.enabled)
        }
    }

    // MARK: Veri

    private var imageSize: String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }

    private func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return DateFormatter.localizedString(from: d, dateStyle: .long, timeStyle: .short)
    }

    private func load() async {
        let rv = try? url.resourceValues(forKeys: [.isUserImmutableKey, .hasHiddenExtensionKey])
        locked = rv?.isUserImmutable ?? false
        hideExt = rv?.hasHiddenExtension ?? false
        let ws = NSWorkspace.shared
        app = ws.urlForApplication(toOpen: url)
        var list = ws.urlsForApplications(toOpen: url)
        if let app, !list.contains(app) { list.insert(app, at: 0) }
        apps = list
        let u = url
        let measured = await Task.detached { FileCopier.measure(u) }.value
        let b = ByteCountFormatter.string(fromByteCount: measured.bytes, countStyle: .file)
        let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        bytes = b
        size = isDir ? L("%@ · %d öğe", b, measured.files) : b
        relayout()
    }
}
