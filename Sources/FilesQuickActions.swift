import AppKit
import AVFoundation
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

@MainActor enum FilesInfoWindow {
    private static var open: [String: NSWindow] = [:]

    static func show(_ url: URL) {
        let key = url.fileKey
        if let w = open[key] { w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        w.title = L("%@ Bilgileri", FileManager.default.displayName(atPath: url.path))
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.contentView = NSHostingView(rootView: FilesInfoView(url: url))
        w.setContentSize(w.contentView!.fittingSize)
        if let key = NSApp.keyWindow {
            let f = key.frame
            w.setFrameTopLeftPoint(NSPoint(x: f.maxX - 320 - CGFloat(open.count * 20), y: f.maxY - 40 - CGFloat(open.count * 20)))
        } else { w.center() }
        open[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[key] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct FilesInfoView: View {
    let url: URL
    @State private var size: String = "…"
    @State private var locked = false
    @State private var hideExt = false
    @State private var apps: [URL] = []
    @State private var app: URL?

    private var values: URLResourceValues? {
        try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                          .contentAccessDateKey, .isDirectoryKey, .isPackageKey, .contentTypeKey])
    }

    var body: some View {
        let v = values
        let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FileManager.default.displayName(atPath: url.path)).font(.system(size: 14, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled)
                    Text(size).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(L("Tür"), v?.localizedTypeDescription ?? "—")
                row(L("Boyut"), size)
                row(L("Konum"), (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                row(L("Oluşturulma"), date(v?.creationDate))
                row(L("Değiştirilme"), date(v?.contentModificationDate))
                if !isFolder { row(L("Son açılma"), date(v?.contentAccessDate)) }
                if let dims = imageSize { row(L("Ölçüler"), dims) }
            }
            .font(.system(size: 11.5))
            Divider()
            Toggle(L("Kilitli"), isOn: $locked)
                .onChange(of: locked) { on in
                    var rv = URLResourceValues(); rv.isUserImmutable = on
                    var u = url; try? u.setResourceValues(rv)
                }
            if !isFolder {
                Toggle(L("Uzantıyı gizle"), isOn: $hideExt)
                    .onChange(of: hideExt) { on in
                        var rv = URLResourceValues(); rv.hasHiddenExtension = on
                        var u = url; try? u.setResourceValues(rv)
                    }
                if !apps.isEmpty {
                    Divider()
                    Text(L("Birlikte aç")).font(.system(size: 11.5, weight: .semibold))
                    Picker("", selection: $app) {
                        ForEach(apps, id: \.self) { a in
                            Text(FileManager.default.displayName(atPath: a.path)).tag(Optional(a))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: app) { a in
                        guard let a else { return }
                        NSWorkspace.shared.setDefaultApplication(at: a, toOpenFileAt: url) { _ in }
                    }
                    Button(L("Hepsini değiştir…")) {
                        guard let a = app, let t = v?.contentType else { return }
                        NSWorkspace.shared.setDefaultApplication(at: a, toOpen: t) { _ in }
                    }
                    .help(L("Bu türdeki bütün dosyalar bu uygulamayla açılsın"))
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .toggleStyle(.checkbox)
        .task { await load() }
    }

    private var imageSize: String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).lineLimit(3).textSelection(.enabled)
        }
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
        let bytes = ByteCountFormatter.string(fromByteCount: measured.bytes, countStyle: .file)
        let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        size = isDir ? L("%@ · %d öğe", bytes, measured.files) : bytes
    }
}
