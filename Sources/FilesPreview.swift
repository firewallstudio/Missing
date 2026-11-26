import AppKit
import Combine
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dosyalar'ın kendi önizleme penceresi (Space / ⌘Y)
//
// Sistemin QLPreviewPanel'i yerine: içerik yine QLPreviewView, çevresi (başlık, düğmeler, çerçeve) temaya uyar.
// Pencere hiçbir zaman anahtar olmaz: Dosyalar anahtar kalır, ok tuşları seçimi oynatır, önizleme seçimi izler,
// başka bir öğeye tek tıkla geçilir. Dosyalar penceresinin çocuk penceresi olarak hep onun üstünde durur;
// Dosyalar arkadayken başka uygulamaların üstünde yüzmez, pencere kapanınca / küçülünce gizlenir.
//
// missing: koyu cam, köşe 12, beyaz %10 kenar, kırmızı birincil düğme
// finder:  Quick Look paneli gibi; koyuda koyu yarı saydam araç şeridi, açıkta açık malzeme, sistem düğmeleri
// windows: Windows 11 penceresi; düz #202020 / #F3F3F3 yüzey, başlık şeridi, köşe 8, vurgu düğmesi köşe 4
// glass:   ince bulanık cam, köşe 14, açık kenar, mor vurgu

// MARK: Öğe bilgisi

/// Önizlenen öğenin özeti: başlık satırı, "önizlenemiyor" kartı ve pencere boyu için
struct FilesPreviewInfo {
    let url: URL
    let name: String
    let kind: String
    let isFolder: Bool
    let size: Int64?
    let dims: String?
    let modified: Date?
    /// Quick Look bunu çizebilir mi (yoksa temalı büyük simge kartı gösterilir)
    let renderable: Bool
    /// İçeriğin doğal boyu (nokta); bilinmiyorsa nil
    let natural: NSSize?
    /// Varsayılan uygulama
    let app: URL?

    init(url: URL) {
        self.url = url
        let v = try? url.resourceValues(forKeys: [.localizedNameKey, .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey,
                                                  .fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        name = v?.localizedName ?? url.lastPathComponent
        kind = v?.localizedTypeDescription ?? ""
        let dir = v?.isDirectory ?? false
        let pkg = v?.isPackage ?? false
        isFolder = dir && !pkg
        size = dir ? nil : v?.fileSize.map { Int64($0) }
        modified = v?.contentModificationDate
        let type = v?.contentType
        renderable = Self.canRender(type, isDirectory: dir, isPackage: pkg)
        app = isFolder ? nil : NSWorkspace.shared.urlForApplication(toOpen: url)

        var dims: String?
        var natural: NSSize?
        if renderable, let t = type {
            if t.conforms(to: .image), let px = Self.imagePixels(url) {
                dims = "\(Int(px.width)) × \(Int(px.height))"
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                natural = NSSize(width: px.width / scale, height: px.height / scale)
            } else if t.conforms(to: .pdf), let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
                let box = page.getBoxRect(.mediaBox)
                let turned = page.rotationAngle % 180 != 0
                natural = turned ? NSSize(width: box.height, height: box.width) : box.size
            } else if t.conforms(to: .audio) {
                natural = NSSize(width: 560, height: 220)
            } else if t.conforms(to: .audiovisualContent) {
                natural = NSSize(width: 960, height: 540)
            } else if t.conforms(to: .text) || t.conforms(to: .compositeContent) {
                natural = NSSize(width: 760, height: 900)   // sayfa gibi
            } else {
                natural = NSSize(width: 900, height: 640)
            }
        }
        self.dims = dims
        self.natural = natural
    }

    /// QLPreviewView'in anlamlı bir önizleme çizdiği türler; geri kalanı (klasör, uygulama, arşiv…) temalı kartta gösterilir
    static func canRender(_ t: UTType?, isDirectory: Bool, isPackage: Bool) -> Bool {
        guard let t else { return false }
        if isDirectory && !isPackage { return false }
        if t.conforms(to: .application) || t.conforms(to: .archive) || t.conforms(to: .diskImage) { return false }
        let known: [UTType] = [.image, .pdf, .audiovisualContent, .text, .compositeContent, .presentation,
                               .spreadsheet, .font, .threeDContent]
        if known.contains(where: { t.conforms(to: $0) }) { return true }
        let ids = ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
                   "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages", "org.idpf.epub-container"]
        return ids.contains(t.identifier)
    }

    /// Resmin piksel boyu (dosyanın yalnız başlığı okunur); EXIF dönüşü hesaba katılır
    static func imagePixels(_ url: URL) -> NSSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? NSSize(width: h, height: w) : NSSize(width: w, height: h)
    }

    var sizeText: String? { size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } }

    /// "Dosya düğmesi" etiketi: "Önizleme ile Aç" / klasörde "Aç"
    var openTitle: String {
        guard let app else { return L("Aç") }
        return L("%@ ile Aç", FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
    }
}

// MARK: Model

@MainActor final class FilesPreviewModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var index = 0
    @Published private(set) var info: FilesPreviewInfo?
    /// Klasör: doğrudan içindeki öğe sayısı ve toplam boyu (arkada hesaplanır)
    @Published private(set) var itemCount: Int?
    @Published private(set) var folderBytes: Int64?
    @Published var zoomed = false

    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }

    func set(urls: [URL], index: Int) {
        self.urls = urls
        self.index = urls.isEmpty ? 0 : min(max(index, 0), urls.count - 1)
        load()
    }

    func step(_ d: Int) {
        guard urls.count > 1 else { return }
        index = (index + d + urls.count) % urls.count
        load()
    }

    private func load() {
        guard let u = current else { info = nil; return }
        if info?.url.fileKey != u.fileKey || info == nil {
            itemCount = nil
            folderBytes = nil
        }
        let i = FilesPreviewInfo(url: u)
        info = i
        guard i.isFolder else { return }
        let key = u.fileKey
        Task.detached(priority: .userInitiated) {
            let n = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]).count) ?? 0
            await MainActor.run { [weak self] in
                if self?.current?.fileKey == key { self?.itemCount = n }
            }
            let bytes = FileCopier.measure(u).bytes
            await MainActor.run { [weak self] in
                if self?.current?.fileKey == key { self?.folderBytes = bytes }
            }
        }
    }

    /// Başlıktaki ikinci satır: tür · boyut (klasörde öğe sayısı) · resim boyutu
    var secondary: String {
        guard let i = info else { return "" }
        var parts = [i.kind]
        if i.isFolder {
            if let n = itemCount { parts.append(Self.itemsText(n)) }
        } else if let s = i.sizeText {
            parts.append(s)
        }
        if let d = i.dims { parts.append(d) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func itemsText(_ n: Int) -> String {
        n == 0 ? L("Boş klasör") : (n == 1 ? L("1 öğe") : L("%d öğe", n))
    }
}

/// Başlıktaki düğmelerin işleri
struct FilesPreviewActions {
    var close: () -> Void = {}
    var open: () -> Void = {}
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var zoom: () -> Void = {}
}

// MARK: Ölçüler

enum FilesPreviewLayout {
    static func headerHeight(_ t: FilesTheme) -> CGFloat {
        switch t {
        case .missing, .glass: return 52
        case .finder: return 44
        case .windows: return 74    // başlık şeridi 32 + komut satırı 42
        }
    }

    static func radius(_ t: FilesTheme) -> CGFloat {
        switch t {
        case .missing: return 12
        case .finder: return 10
        case .windows: return 8
        case .glass: return 14
        }
    }

    /// Başlıktaki düğmeler sığsın diye
    static let minWidth: CGFloat = 540
    static let minContentHeight: CGFloat = 240
    /// Önizlenemeyen öğe / klasör kartının içerik boyu
    static let cardSize = NSSize(width: 560, height: 400)
}

// MARK: - Pencere

/// Hiç anahtar olmayan önizleme paneli. İçerikte çift tık: öğeyi Dosyalar'daki gibi aç.
final class FilesPreviewWindow: NSPanel {
    var onDoubleClickContent: (() -> Void)?
    var contentArea: () -> NSRect = { .zero }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, contentArea().contains(event.locationInWindow),
           let onDoubleClickContent {
            onDoubleClickContent()
            return
        }
        super.sendEvent(event)
    }
}

/// İlk tıklamayı da kabul eden barındırıcı (pencere anahtar olmadığı için her tık "ilk tık")
final class FilesPreviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// QLPreviewView: anahtar olmayan pencerede de ilk tık içeriğe gitsin (oynat düğmesi, kaydırma)
final class FilesPreviewQLView: QLPreviewView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pencerenin içeriği: altta temalı çerçeve (SwiftUI), içerik alanında QLPreviewView
final class FilesPreviewRootView: NSView {
    let chrome: NSView
    let ql: QLPreviewView

    init(model: FilesPreviewModel, actions: FilesPreviewActions) {
        chrome = FilesPreviewHostingView(rootView: FilesThemedRoot { _ in FilesPreviewChrome(model: model, actions: actions) })
        ql = FilesPreviewQLView(frame: .zero, style: .normal) ?? QLPreviewView()
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.masksToBounds = true
        ql.shouldCloseWithWindow = false
        ql.autostarts = true          // Hızlı Bakış gibi: video / ses açılınca oynar
        ql.wantsLayer = true
        ql.layer?.masksToBounds = true
        ql.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(chrome)
        addSubview(ql)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var theme: FilesTheme { FilesThemeStore.shared.theme }

    /// İçerik alanı (pencere koordinatı, alttan): kenarın 1 pt içinde, başlığın altında
    var contentArea: NSRect {
        let h = FilesPreviewLayout.headerHeight(theme)
        return NSRect(x: 1, y: 1, width: max(0, bounds.width - 2), height: max(0, bounds.height - h - 1))
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        ql.frame = contentArea
    }

    func restyle() {
        let r = FilesPreviewLayout.radius(theme)
        layer?.cornerRadius = r
        layer?.cornerCurve = .continuous
        ql.layer?.cornerRadius = max(0, r - 1)
        ql.layer?.cornerCurve = .continuous
        needsLayout = true
    }
}

// MARK: - Denetleyici

@MainActor final class FilesPreviewPanel: NSObject, NSWindowDelegate {
    static let shared = FilesPreviewPanel()

    let model = FilesPreviewModel()
    /// Önizlemeyi açan Dosyalar penceresi
    private(set) weak var controller: FilesWindowController?
    private(set) weak var host: NSWindow?
    private(set) var panel: FilesPreviewWindow?
    private(set) var root: FilesPreviewRootView?

    private var sourceFrame: (URL) -> NSRect? = { _ in nil }
    private var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var hostObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var themeWatch: AnyCancellable?
    private var throttle: DispatchWorkItem?
    private var pending: (urls: [URL], index: Int)?
    private var lastApply: CFTimeInterval = 0
    /// Kullanıcı elle boyutlandırdıysa öğe değişince pencere yeniden sığdırılmaz
    private var userSized = false
    /// Kapanış canlandırması sürüyor (sayaç: eski canlandırmanın bitişi yenisini bozmasın)
    private var closeToken = 0
    private var closing = false

    var isVisible: Bool { panel?.isVisible == true && !closing }

    // MARK: Dosyalar penceresi için kısa yol

    /// Space / ⌘Y: açıksa kapatır, değilse seçimi (seçim yoksa bulunulan klasörü) önizler
    func toggle(for c: FilesWindowController) {
        if isVisible, controller === c { close(); return }
        guard let w = c.window else { return }
        var urls = c.browser.selectedItems.map(\.url)
        if urls.isEmpty { urls = [c.tab.url] }
        controller = c
        show(urls: urls, index: 0, over: w,
             sourceFrame: { [weak c] u in c?.browser.screenFrame(of: u) },
             open: { [weak c] u in
                 guard let c else { NSWorkspace.shared.open(u); return }
                 let sel = c.browser.selectedItems.filter { $0.url.fileKey == u.fileKey }
                 if !sel.isEmpty { c.open(sel); return }
                 guard let item = FileItem(url: u) else { return }
                 if item.isFolder && u.fileKey == c.tab.url.fileKey { return }   // zaten burada
                 c.open([item])
             })
    }

    /// Seçim değişti: açıksa önizleme yeni seçimi gösterir (ok tuşu basılı tutulunca hafifçe seyreltilir).
    /// `from` verilirse yalnız önizlemeyi açan pencereden gelen güncelleme işlenir. Boş seçim son öğeyi bırakır.
    func update(urls: [URL], index: Int = 0, from c: FilesWindowController? = nil) {
        guard isVisible, !urls.isEmpty else { return }
        if let c, c !== controller { return }
        pending = (urls, index)
        guard throttle == nil else { return }
        let now = CACurrentMediaTime()
        if now - lastApply > 0.12 {
            applyPending()
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.throttle = nil
                    self?.applyPending()
                }
            }
            throttle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    // MARK: Çekirdek (deneme düzeneği de bunu kullanır)

    func show(urls: [URL], index: Int, over window: NSWindow,
              sourceFrame: @escaping (URL) -> NSRect?, open: @escaping (URL) -> Void) {
        guard !urls.isEmpty else { return }
        if closing { finishClose() }
        if isVisible {
            if host === window { update(urls: urls, index: index); return }
            close(animated: false)
        }
        self.sourceFrame = sourceFrame
        self.opener = open
        let (panel, root) = makePanelIfNeeded()
        host = window
        userSized = false
        model.zoomed = false
        model.set(urls: urls, index: index)
        lastApply = CACurrentMediaTime()
        loadContent()
        applyStyle()
        root.layoutSubtreeIfNeeded()

        let target = fittedFrame()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let src = model.current.flatMap(sourceFrame).flatMap { visible($0) }
        panel.alphaValue = 0
        if !reduce, let src {
            panel.setFrame(Self.seed(around: src, target: target), display: false)
        } else {
            panel.setFrame(target, display: false)
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        watchHost(window)
        installKeyMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.12 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Kapat (Esc, Space, kapat düğmesi). Seçili öğe ekrandaysa ona doğru küçülerek kaybolur.
    func close(animated: Bool = true) {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        closeToken += 1
        let token = closeToken
        unwatchHost()
        removeKeyMonitor()
        throttle?.cancel(); throttle = nil
        pending = nil
        guard animated else { finishClose(); return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let src = reduce ? nil : model.current.flatMap(sourceFrame).flatMap { visible($0) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.12 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let src { panel.animator().setFrame(Self.seed(around: src, target: panel.frame), display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closeToken == token, self.closing else { return }
                self.finishClose()
            }
        })
    }

    private func finishClose() {
        guard let panel else { closing = false; return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        root?.ql.previewItem = nil   // video / ses dursun
        closing = false
        model.zoomed = false
    }

    // MARK: Kurulum

    private func makePanelIfNeeded() -> (FilesPreviewWindow, FilesPreviewRootView) {
        if let panel, let root { return (panel, root) }
        let actions = FilesPreviewActions(
            close: { [weak self] in self?.close() },
            open: { [weak self] in self?.openCurrent() },
            previous: { [weak self] in self?.step(-1) },
            next: { [weak self] in self?.step(1) },
            zoom: { [weak self] in self?.toggleZoom() })
        let p = FilesPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = false          // seviye Dosyalar penceresinden gelir (çocuk pencere)
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.animationBehavior = .none
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        p.delegate = self
        let r = FilesPreviewRootView(model: model, actions: actions)
        p.contentView = r
        p.contentArea = { [weak r] in r?.contentArea ?? .zero }
        p.onDoubleClickContent = { [weak self] in self?.openCurrent() }
        p.setAccessibilitySubrole(.floatingWindow)
        panel = p
        root = r
        themeWatch = FilesThemeStore.shared.$theme.dropFirst().sink { [weak self] _ in
            // @Published değeri yazılmadan önce yayınlar: bir tur sonra uygula
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.themeChanged() } }
        }
        return (p, r)
    }

    private func applyStyle() {
        guard let panel else { return }
        let t = FilesThemeStore.shared.theme
        panel.appearance = t == .missing ? NSAppearance(named: .darkAqua) : nil
        panel.minSize = NSSize(width: FilesPreviewLayout.minWidth,
                               height: FilesPreviewLayout.headerHeight(t) + FilesPreviewLayout.minContentHeight)
        root?.restyle()
        panel.invalidateShadow()
    }

    private func themeChanged() {
        applyStyle()
        guard isVisible, let panel else { return }
        panel.setFrame(userSized ? panel.frame : fittedFrame(keepCenter: true), display: true)
        panel.invalidateShadow()
    }

    /// İçerik alanına öğeyi koy: Quick Look çizebiliyorsa QLPreviewView, yoksa temalı kart (çerçevenin içinde)
    private func loadContent() {
        guard let root else { return }
        let info = model.info
        if let info, info.renderable {
            if root.ql.previewItem?.previewItemURL?.fileKey != info.url.fileKey { root.ql.previewItem = info.url as NSURL }
            root.ql.isHidden = false
        } else {
            root.ql.previewItem = nil
            root.ql.isHidden = true
        }
    }

    private func applyPending() {
        guard let p = pending else { return }
        pending = nil
        lastApply = CACurrentMediaTime()
        let before = model.current?.fileKey
        model.set(urls: p.urls, index: p.index)
        guard model.current?.fileKey != before else { return }
        loadContent()
        refit()
    }

    private func step(_ d: Int) {
        model.step(d)
        loadContent()
        refit()
    }

    private func toggleZoom() {
        model.zoomed.toggle()
        guard let panel else { return }
        let f = fittedFrame(keepCenter: !model.zoomed)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(f, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(f, display: true)
            }
        }
    }

    private func openCurrent() {
        guard let u = model.current else { return }
        let open = opener
        close(animated: false)
        open(u)
    }

    /// Öğe değişince pencereyi yeni içeriğe sığdır (kullanıcı boyutlandırmadıysa); merkez yerinde kalır
    private func refit() {
        guard let panel, isVisible, !userSized, !model.zoomed else { return }
        let f = fittedFrame(keepCenter: true)
        guard f != panel.frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(f, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(f, display: true)
            }
        }
    }

    /// İçeriğin doğal oranını ekranın görünür alanının ~%70'ine sığdır; Dosyalar penceresinin ekranında ortala
    func fittedFrame(keepCenter: Bool = false) -> NSRect {
        let screen = host?.screen ?? panel?.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if model.zoomed { return vf.insetBy(dx: 16, dy: 16) }
        let t = FilesThemeStore.shared.theme
        let header = FilesPreviewLayout.headerHeight(t)
        var c = model.info?.renderable == true ? (model.info?.natural ?? NSSize(width: 900, height: 640))
                                               : FilesPreviewLayout.cardSize
        let maxW = vf.width * 0.7 - 2, maxH = vf.height * 0.7 - header - 1
        let s = min(1, maxW / max(c.width, 1), maxH / max(c.height, 1))
        c = NSSize(width: (c.width * s).rounded(), height: (c.height * s).rounded())
        c.width = max(c.width, FilesPreviewLayout.minWidth - 2)
        c.height = max(c.height, FilesPreviewLayout.minContentHeight)
        let size = NSSize(width: c.width + 2, height: c.height + header + 1)
        var center = NSPoint(x: vf.midX, y: vf.midY)
        if keepCenter, let f = panel?.frame, panel?.isVisible == true { center = NSPoint(x: f.midX, y: f.midY) }
        var r = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        // Ekrandan taşmasın
        r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r.integral
    }

    /// Açılış / kapanış canlandırmasının küçük çerçevesi: öğenin ekrandaki yerinde, hedefin oranında
    private static func seed(around src: NSRect, target: NSRect) -> NSRect {
        let w = max(140, min(target.width * 0.28, 260))
        let h = w * target.height / max(target.width, 1)
        return NSRect(x: src.midX - w / 2, y: src.midY - h / 2, width: w, height: h)
    }

    /// Kaynak çerçeve bir ekranda görünüyorsa
    private func visible(_ r: NSRect) -> NSRect? {
        guard r.width > 0, r.height > 0 else { return nil }
        return NSScreen.screens.contains { $0.frame.intersects(r) } ? r : nil
    }

    // MARK: Dosyalar penceresini izle

    private func watchHost(_ w: NSWindow) {
        unwatchHost()
        let nc = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            hostObservers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(animated: false) }
            })
        }
        // Başka bir pencere ana olunca (ör. ikinci Dosyalar penceresi) önizleme kapanır; uygulama arkaya geçince panel kendiliğinden gizlenir
        hostObservers.append(nc.addObserver(forName: NSWindow.didResignMainNotification, object: w, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, NSApp.isActive, let m = NSApp.mainWindow, m !== self.host, m !== self.panel else { return }
                    self.close(animated: false)
                }
            }
        })
    }

    private func unwatchHost() {
        hostObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hostObservers.removeAll()
    }

    /// Dosyalar anahtar kaldığı için Esc ona gider: önizleme açıkken onu kapatır (yeniden adlandırma sürerken değil)
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, e.keyCode == 53,
                      e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      e.window === self.host || e.window === self.panel,
                      !(self.host?.firstResponder is NSText) else { return e }
                self.close()
                return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: NSWindowDelegate

    func windowWillStartLiveResize(_ notification: Notification) { userSized = true }
    func windowDidResize(_ notification: Notification) { panel?.invalidateShadow() }
}

// MARK: - Çerçeve (SwiftUI)

struct FilesPreviewChrome: View {
    @ObservedObject var model: FilesPreviewModel
    let actions: FilesPreviewActions
    @Environment(\.filesPalette) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FilesPreviewLayout.radius(p.theme), style: .continuous)
        VStack(spacing: 0) {
            header
                .frame(height: FilesPreviewLayout.headerHeight(p.theme))
            ZStack {
                contentBackdrop
                if let i = model.info, !i.renderable {
                    FilesPreviewCard(info: i, itemCount: model.itemCount, folderBytes: model.folderBytes)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(p.fg)
        .background(windowBackground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.dialogBorder, lineWidth: 1))
        // Başlık çubuğu saydam ve gizli: içerik pencerenin en üstünden başlasın (güvenli alan payı yok)
        .ignoresSafeArea()
    }

    // MARK: Zeminler

    @ViewBuilder private var windowBackground: some View {
        switch p.theme {
        case .missing, .glass:
            Color.clear.modifier(FilesDialogSurface(shaped: false))
        case .windows:
            p.winBand
        case .finder:
            GlassBlur(material: p.dark ? .hudWindow : .windowBackground, appearance: p.dark ? .darkAqua : .aqua)
        }
    }

    @ViewBuilder private var contentBackdrop: some View {
        switch p.theme {
        case .missing: Color.black.opacity(0.22)
        case .glass: p.dark ? Color.black.opacity(0.10) : Color.white.opacity(0.18)
        case .windows: p.dark ? Color(white: 0.11) : Color.white
        case .finder: p.dark ? Color.black.opacity(0.18) : Color(nsColor: .textBackgroundColor).opacity(0.55)
        }
    }

    // MARK: Başlık

    @ViewBuilder private var header: some View {
        switch p.theme {
        case .missing, .glass: glassyHeader
        case .finder: finderHeader
        case .windows: windowsHeader
        }
    }

    private var name: String { model.info?.name ?? "" }
    private var icon: NSImage? { model.info.map { FileIcons.shared.icon($0.url) } }

    private func iconView(_ s: CGFloat) -> some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Color.clear }
        }
        .frame(width: s, height: s)
    }

    private func title(size: CGFloat, weight: Font.Weight) -> some View {
        Text(name)
            .font(.system(size: size, weight: weight))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(name)
    }

    private var subtitle: some View {
        Text(model.secondary)
            .font(.system(size: 11))
            .foregroundStyle(p.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Birden çok öğe seçiliyse önceki / sonraki ve "2 / 5"
    @ViewBuilder private var navigation: some View {
        if model.urls.count > 1 {
            HStack(spacing: p.theme == .finder ? 0 : 4) {
                Button(action: actions.previous) { Image(systemName: "chevron.left") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                    .help(L("Önceki"))
                Text("\(model.index + 1) / \(model.urls.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(p.secondary)
                    .fixedSize()
                    .padding(.horizontal, 2)
                Button(action: actions.next) { Image(systemName: "chevron.right") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                    .help(L("Sonraki"))
            }
            .fixedSize()
        }
    }

    private var zoomButton: some View {
        Button(action: actions.zoom) {
            Image(systemName: model.zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(FilesPreviewIconButtonStyle(p: p))
        .help(model.zoomed ? L("Eski boyutuna getir") : L("Büyüt"))
    }

    @ViewBuilder private var shareButton: some View {
        if let u = model.info?.url {
            ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .help(L("Paylaş"))
        }
    }

    private var openButton: some View {
        Button(action: actions.open) { Text(model.info?.openTitle ?? L("Aç")) }
            .filesButton(.primary, p, small: p.theme != .windows)
            .fixedSize()
    }

    private var closeButton: some View {
        Button(action: actions.close) { Image(systemName: "xmark") }
            .buttonStyle(FilesPreviewIconButtonStyle(p: p))
            .help(L("Kapat") + "  Esc")
    }

    // missing / glass: solda simge + ad + ikinci satır, sağda düğmeler
    private var glassyHeader: some View {
        HStack(spacing: 8) {
            iconView(26)
            VStack(alignment: .leading, spacing: 1) {
                title(size: 13, weight: .semibold)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            navigation
            zoomButton
            shareButton
            openButton
            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(p.fg.opacity(p.theme == .glass ? 0.10 : 0.08)).frame(height: 1) }
    }

    // finder: Quick Look paneli: solda kapat + büyüt, ortada ad (altında küçük bilgi), sağda gezinme, paylaş, "… ile Aç"
    private var finderHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                closeButton
                zoomButton
            }
            .fixedSize()
            VStack(spacing: 0) {
                title(size: 12.5, weight: .semibold)
                Text(model.secondary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            navigation
            shareButton
            openButton
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(p.dark ? Color.black.opacity(0.28) : Color.white.opacity(0.45))
        .overlay(alignment: .bottom) { Rectangle().fill(p.dark ? Color.black.opacity(0.5) : Color.black.opacity(0.12)).frame(height: 1) }
    }

    // windows: üstte başlık şeridi (simge, ad, büyüt / kapat başlık düğmeleri), altında komut satırı
    private var windowsHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                iconView(16).padding(.leading, 12).padding(.trailing, 10)
                title(size: 12, weight: .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.zoom) {
                    Image(systemName: model.zoomed ? "square.on.square" : "square")
                }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p, caption: true))
                .help(model.zoomed ? L("Eski boyutuna getir") : L("Büyüt"))
                Button(action: actions.close) { Image(systemName: "xmark") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p, caption: true, danger: true))
                    .help(L("Kapat") + "  Esc")
            }
            .frame(height: 32)
            HStack(spacing: 6) {
                subtitle.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                navigation
                shareButton
                openButton
            }
            .padding(.horizontal, 12)
            .frame(height: 41)
            Rectangle().fill(p.dialogBorder).frame(height: 1)
        }
    }
}

// MARK: Simge düğmesi

/// Başlıktaki simge düğmesi. windows'ta `caption`: 46×32 başlık çubuğu düğmesi (kapat basılıyken kırmızı)
struct FilesPreviewIconButtonStyle: ButtonStyle {
    let p: FilesPalette
    var caption = false
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, p: p, caption: caption, danger: danger)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let p: FilesPalette
        let caption: Bool
        let danger: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            let red = danger && caption && (pressed || hover)
            configuration.label
                .font(.system(size: caption ? 11 : 12, weight: caption ? .regular : .medium))
                .foregroundStyle(red ? Color.white : p.fg.opacity(p.theme == .finder ? 0.78 : 0.88))
                .frame(width: caption ? 46 : 28, height: caption ? 32 : (p.theme == .finder ? 24 : 28))
                .background(shape.fill(fill(pressed: pressed, red: red)))
                .overlay(shape.stroke(stroke, lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .opacity(enabled ? 1 : 0.4)
        }

        private var shape: AnyShape {
            if caption { return AnyShape(Rectangle()) }
            switch p.theme {
            case .glass: return AnyShape(Circle())
            case .windows: return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            case .finder: return AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .missing: return AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }

        private func fill(pressed: Bool, red: Bool) -> Color {
            if red { return Color(red: 0.77, green: 0.17, blue: 0.11).opacity(pressed ? 0.85 : 1) }   // #C42B1C
            let base: Color
            switch p.theme {
            case .missing: base = .white.opacity(0.06)
            case .glass: base = p.glassFill(0.10)
            case .windows, .finder: base = .clear
            }
            if pressed { return p.pressFill }
            if hover { return p.theme == .glass ? p.glassFill(0.18) : p.hoverFill.opacity(2) }
            return base
        }

        private var stroke: Color {
            switch p.theme {
            case .missing where !caption: return .white.opacity(0.08)
            case .glass where !caption: return p.glassStroke(0.22)
            default: return .clear
            }
        }
    }
}

// MARK: Önizlenemeyen öğe / klasör kartı

struct FilesPreviewCard: View {
    let info: FilesPreviewInfo
    let itemCount: Int?
    let folderBytes: Int64?
    @Environment(\.filesPalette) private var p

    var body: some View {
        let content = VStack(spacing: 8) {
            Image(nsImage: FileIcons.shared.icon(info.url))
                .resizable().interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(p.theme == .windows ? 0 : 0.18), radius: 6, y: 3)
                .padding(.bottom, 6)
            Text(info.name)
                .font(.system(size: p.theme == .windows ? 16 : 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            if !info.kind.isEmpty {
                Text(info.kind).font(.system(size: 12)).foregroundStyle(p.secondary).lineLimit(1)
            }
            VStack(spacing: 3) {
                ForEach(rows, id: \.0) { r in
                    HStack(spacing: 6) {
                        Text(r.0).foregroundStyle(p.secondary)
                        Text(r.1).monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 380)

        switch p.theme {
        case .missing, .glass:
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.cardStroke, lineWidth: 1))
        case .finder, .windows:
            content
        }
    }

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        if info.isFolder {
            r.append((L("Boyut"), folderBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"))
            r.append((L("İçerik"), itemCount.map(FilesPreviewModel.itemsText) ?? "…"))
        } else if let s = info.sizeText {
            r.append((L("Boyut"), s))
        }
        if let d = info.modified {
            r.append((L("Değiştirilme"), DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)))
        }
        return r
    }
}
