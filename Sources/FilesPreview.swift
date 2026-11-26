import AppKit
import AVFoundation
import AVKit
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
//
// Fotoğraf ve videolar kendi oranlarında: içerik alanı tam olarak ortamın oranında, pencere ekranın görünür
// alanına (20 pt pay) sığacak kadar büyük; küçük resimler en çok 3 katına büyür. Resimleri (EXIF yönü, GIF
// canlandırması) NSImageView, videoları AVPlayerView çizer; geri kalanı (PDF, metin, ses, belgeler) QLPreviewView.
// Dar pencerede başlık sıkışır: önce "… ile Aç" simgeye iner, sonra ikincil düğmeler ve bilgi satırı gizlenir.

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
    /// Kendi çizdiğimiz ortam: içerik alanı bunun oranında olur
    let media: Media
    /// Ortamın (yönü uygulanmış) piksel boyu; video için yüklenene kadar nil
    let mediaPixels: NSSize?
    /// Ses / video: başlıkta düzenle (makas) düğmesi
    let editable: Bool

    enum Media { case none, image, animated, video }

    /// `videoPixels`: daha önce yüklenmiş video boyu (.zero: AVFoundation açamadı, Quick Look'a kalır)
    init(url: URL, videoPixels: NSSize? = nil) {
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
        editable = !dir && (type?.conforms(to: .audiovisualContent) ?? false) && !(type?.conforms(to: .m3uPlaylist) ?? false)
        app = isFolder ? nil : NSWorkspace.shared.urlForApplication(toOpen: url)

        var dims: String?
        var natural: NSSize?
        var media = Media.none
        var mediaPixels: NSSize?
        if renderable, let t = type {
            if t.conforms(to: .image), let probe = Self.imageProbe(url) {
                let px = probe.pixels
                dims = "\(Int(px.width)) × \(Int(px.height))"
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                natural = NSSize(width: px.width / scale, height: px.height / scale)
                media = t.conforms(to: .gif) && probe.frames > 1 ? .animated : .image
                mediaPixels = px
            } else if t.conforms(to: .movie), videoPixels != .zero {
                media = .video
                mediaPixels = videoPixels
                if let px = videoPixels {
                    dims = "\(Int(px.width)) × \(Int(px.height))"
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    natural = NSSize(width: px.width / scale, height: px.height / scale)
                } else {
                    natural = NSSize(width: 960, height: 540)   // geçici: boy yüklenince yeniden sığdırılır
                }
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
        self.media = media
        self.mediaPixels = mediaPixels
    }

    /// Ortamın oranı (genişlik / yükseklik); ortam değilse ya da boyu bilinmiyorsa nil
    var mediaAspect: CGFloat? {
        guard media != .none, let m = mediaPixels, m.width > 0, m.height > 0 else { return nil }
        return m.width / m.height
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
    static func imagePixels(_ url: URL) -> NSSize? { imageProbe(url)?.pixels }

    /// Piksel boyu (EXIF yönü uygulanmış: 5-8 yan yatık) ve kare sayısı (GIF canlandırması)
    static func imageProbe(_ url: URL) -> (pixels: NSSize, frames: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return (o >= 5 ? NSSize(width: h, height: w) : NSSize(width: w, height: h), CGImageSourceGetCount(src))
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
    /// Fotoğraf işaretleniyor (FilesMarkupView.swift); başlığın yerini araç çubuğu alır
    @Published var markup: FilesMarkupSession?
    /// Yüklenmiş video boyları (yönü uygulanmış piksel; .zero: açılamadı)
    private(set) var videoPixels: [String: NSSize] = [:]

    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }

    /// Video boyu yüklendi: önbelleğe al, gösterilen öğeyse bilgisini yenile
    func setVideoPixels(_ px: NSSize, for url: URL) {
        videoPixels[url.fileKey] = px
        if current?.fileKey == url.fileKey { info = FilesPreviewInfo(url: url, videoPixels: px) }
    }

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
        let i = FilesPreviewInfo(url: u, videoPixels: videoPixels[u.fileKey])
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
    /// Paylaş düğmesi; düğmenin pencere içindeki (üstten) çerçevesiyle
    var share: (NSRect) -> Void = { _ in }
    /// Makas: ses / videoyu düzenleyicide aç
    var edit: () -> Void = {}
    /// Fotoğrafı işaretle
    var markup: () -> Void = {}
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

    /// Ortam olmayan öğelerde en dar pencere (tam başlık sığsın)
    static let minWidth: CGFloat = 540
    /// Fotoğraf / videoda en dar pencere: başlık en sıkışık hâliyle sığar; daha dar ortam yanlardan boşluklu gösterilir
    static let mediaMinWidth: CGFloat = 280
    /// Ortamın ekran kenarına uzaklığı
    static let mediaMargin: CGFloat = 20
    /// Küçük resimler en çok bu kadar büyütülür
    static let maxUpscale: CGFloat = 3
    static let minContentHeight: CGFloat = 240
    /// Önizlenemeyen öğe / klasör kartının içerik boyu
    static let cardSize = NSSize(width: 560, height: 400)
}

// MARK: - Pencere

/// Hiç anahtar olmayan önizleme paneli. İçerikte çift tık: öğeyi Dosyalar'daki gibi aç.
final class FilesPreviewWindow: NSPanel {
    var onDoubleClickContent: (() -> Void)?
    var contentArea: () -> NSRect = { .zero }
    /// İşaretlerken anahtar olabilir (yazı, ⌘Z, Sil, Esc, Return); çift tık öğeyi açmaz
    var markupActive = false

    override var canBecomeKey: Bool { markupActive }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if !markupActive, event.type == .leftMouseDown, event.clickCount == 2, contentArea().contains(event.locationInWindow),
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

/// Resim: anahtar olmayan pencerede ilk tık da gelsin; tıklar pencereye (çift tık: aç) geçer
final class FilesPreviewImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
}

/// Ortamın kırpma kabı: tıklamaları kendisi tutmaz (başlığın altına taşan payı düğmeleri örtmesin)
final class FilesPreviewClipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// Video: AVPlayerView, ilk tık denetimlere gitsin
final class FilesPreviewPlayerView: AVPlayerView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pencerenin içeriği: altta temalı çerçeve (SwiftUI), içerik alanında QLPreviewView ya da kendi resim / video görünümümüz
final class FilesPreviewRootView: NSView {
    let chrome: NSView
    let ql: QLPreviewView
    /// Resim ve videonun kırpma kabı: alt köşeler pencereninkiyle aynı yuvarlak. Üstte köşe yarıçapı kadar başlığın
    /// altına taşar ki üst köşelerin yuvarlağı ortamı kesmesin (maskedCorners'a güvenmeden)
    let mediaClip = FilesPreviewClipView()
    let imageView = FilesPreviewImageView()
    let playerView = FilesPreviewPlayerView()
    /// İşaretleme tuvali: resim görünümüyle aynı çerçevede
    var markupCanvas: NSView? { didSet { needsLayout = true } }
    /// Gösterilen ortamın oranı; nil: ortam yok (QL / kart)
    var mediaAspect: CGFloat? { didSet { if mediaAspect != oldValue { needsLayout = true } } }

    init(model: FilesPreviewModel, actions: FilesPreviewActions) {
        chrome = FilesPreviewHostingView(rootView: FilesThemedRoot { _ in FilesPreviewChrome(model: model, actions: actions) })
        ql = FilesPreviewQLView(frame: .zero, style: .normal) ?? QLPreviewView()
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.masksToBounds = true
        ql.shouldCloseWithWindow = false
        ql.autostarts = true          // Hızlı Bakış gibi: ses / belge içindeki ortam açılınca oynar
        ql.wantsLayer = true
        ql.layer?.masksToBounds = true
        ql.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        mediaClip.wantsLayer = true
        mediaClip.layer?.masksToBounds = true
        mediaClip.isHidden = true
        // Oran pencereyle zaten aynı: eksenleri bağımsız ölçekle ki kıl payı yuvarlamada bile boşluk kalmasın
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.animates = true
        imageView.isEditable = false
        imageView.wantsLayer = true
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        mediaClip.addSubview(imageView)
        mediaClip.addSubview(playerView)
        addSubview(chrome)
        addSubview(ql)
        addSubview(mediaClip)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var theme: FilesTheme { FilesThemeStore.shared.theme }

    /// İçerik alanı (pencere koordinatı, alttan): kenarın 1 pt içinde, başlığın altında
    var contentArea: NSRect {
        let h = FilesPreviewLayout.headerHeight(theme)
        return NSRect(x: 1, y: 1, width: max(0, bounds.width - 2), height: max(0, bounds.height - h - 1))
    }

    /// Ortamın içerik alanındaki yeri: oran tutuyorsa alanın tamamı, pencere en dar sınırdaysa ortada sığdırılmış
    var mediaRect: NSRect {
        let c = contentArea
        guard let a = mediaAspect, c.width > 0, c.height > 0 else { return c }
        let ca = c.width / c.height
        if abs(ca - a) / a < 0.01 { return c }
        if ca > a {
            let w = c.height * a
            return NSRect(x: c.minX + (c.width - w) / 2, y: c.minY, width: w, height: c.height)
        }
        let h = c.width / a
        return NSRect(x: c.minX, y: c.minY + (c.height - h) / 2, width: c.width, height: h)
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        ql.frame = contentArea
        let c = contentArea
        let r = FilesPreviewLayout.radius(theme)
        mediaClip.frame = NSRect(x: c.minX, y: c.minY, width: c.width, height: c.height + r)
        let m = mediaRect
        let inner = NSRect(x: m.minX - c.minX, y: m.minY - c.minY, width: m.width, height: m.height)
        imageView.frame = inner
        playerView.frame = inner
        markupCanvas?.frame = inner
    }

    func restyle() {
        let r = FilesPreviewLayout.radius(theme)
        layer?.cornerRadius = r
        layer?.cornerCurve = .continuous
        for l in [ql.layer, mediaClip.layer] {
            l?.cornerRadius = max(0, r - 1)
            l?.cornerCurve = .continuous
        }
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
    /// Video oynatıcısı (öğe değişince / kapanınca durur)
    private var player: AVPlayer?
    /// Deneme düzeneği sessiz oynatır
    var muted = false
    /// Arkada çözülen resmin hâlâ istenen öğe olduğunu doğrulamak için
    private var imageToken = 0
    /// Video boyu yüklenene kadar bekleyen açılış (kısa süre; boy gelince pencere doğru oranda açılır)
    private var pendingPresent: (() -> Void)?
    /// İşaretlerken yok sayılan son seçim (işaretler bırakılınca önizleme ona döner)
    var markupIgnored: (urls: [URL], index: Int)?

    var isVisible: Bool { (panel?.isVisible == true || pendingPresent != nil) && !closing }

    // MARK: Dosyalar penceresi için kısa yol

    /// Space / ⌘Y: açıksa kapatır, değilse seçimi (seçim yoksa bulunulan klasörü) önizler
    func toggle(for c: FilesWindowController) {
        if isVisible, controller === c { requestClose(); return }
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

        let present = { [weak self, weak window] in
            guard let self, let window, let panel = self.panel else { return }
            self.pendingPresent = nil
            let target = self.fittedFrame()
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let src = self.model.current.flatMap(sourceFrame).flatMap { self.visible($0) }
            panel.alphaValue = 0
            if !reduce, let src {
                panel.setFrame(Self.seed(around: src, target: target), display: false)
            } else {
                panel.setFrame(target, display: false)
            }
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduce ? 0.12 : 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        watchHost(window)
        installKeyMonitor()
        if model.info?.media == .video, model.info?.mediaPixels == nil {
            // Videonun boyu birkaç ms içinde gelir: geçici boyla açıp sonra zıplamak yerine kısa bekle (en çok 0,3 sn)
            pendingPresent = present
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.pendingPresent?() }
            }
        } else {
            present()
        }
    }

    /// Kapat (Esc, Space, kapat düğmesi). Seçili öğe ekrandaysa ona doğru küçülerek kaybolur.
    func close(animated: Bool = true) {
        endMarkup()
        if pendingPresent != nil {
            // Henüz açılmadı (video boyu bekleniyordu): açılmadan vazgeç
            pendingPresent = nil
            unwatchHost()
            removeKeyMonitor()
            stopMedia()
            return
        }
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
        endMarkup()
        guard let panel else { closing = false; return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        stopMedia()   // video / ses dursun
        closing = false
        model.zoomed = false
    }

    // MARK: Kurulum

    private func makePanelIfNeeded() -> (FilesPreviewWindow, FilesPreviewRootView) {
        if let panel, let root { return (panel, root) }
        let actions = FilesPreviewActions(
            close: { [weak self] in self?.requestClose() },
            open: { [weak self] in self?.openCurrent() },
            previous: { [weak self] in self?.step(-1) },
            next: { [weak self] in self?.step(1) },
            zoom: { [weak self] in self?.toggleZoom() },
            share: { [weak self] r in self?.share(from: r) },
            edit: { [weak self] in self?.editCurrent() },
            markup: { [weak self] in self?.beginMarkup() })
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
        updateMinSize()
        root?.restyle()
        panel.invalidateShadow()
    }

    /// Ortamda pencere dar olabilir (başlık sıkışır); diğer öğelerde tam başlık sığacak kadar geniş kalır
    private func updateMinSize() {
        let h = FilesPreviewLayout.headerHeight(FilesThemeStore.shared.theme)
        panel?.minSize = model.info?.mediaAspect != nil
            ? NSSize(width: FilesPreviewLayout.mediaMinWidth, height: h + 60)
            : NSSize(width: FilesPreviewLayout.minWidth, height: h + FilesPreviewLayout.minContentHeight)
    }

    private func themeChanged() {
        applyStyle()
        guard isVisible, let panel else { return }
        panel.setFrame(userSized ? panel.frame : fittedFrame(keepCenter: true), display: true)
        panel.invalidateShadow()
    }

    /// İçerik alanına öğeyi koy: resim → NSImageView, video → AVPlayerView, Quick Look'un çizdiği diğer türler →
    /// QLPreviewView, kalanlar temalı kart (çerçevenin içinde). Kendi görünümlerimiz içerik alanını kenardan kenara doldurur.
    private func loadContent() {
        endMarkup()   // başka öğeye geçildi: işaretler sessizce bırakılır
        guard let root else { return }
        let info = model.info
        let media = info?.media ?? .none
        root.mediaAspect = info?.mediaAspect ?? (media == .video ? 16.0 / 9.0 : nil)
        root.mediaClip.isHidden = media == .none
        root.imageView.isHidden = !(media == .image || media == .animated)
        root.playerView.isHidden = media != .video
        if media != .video { stopPlayer() }
        if media != .image && media != .animated { root.imageView.image = nil }

        switch media {
        case .image, .animated:
            root.ql.previewItem = nil
            root.ql.isHidden = true
            if let info { loadImage(info) }
        case .video:
            root.ql.previewItem = nil
            root.ql.isHidden = true
            if let info { loadVideo(info) }
        case .none:
            if let info, info.renderable {
                if root.ql.previewItem?.previewItemURL?.fileKey != info.url.fileKey { root.ql.previewItem = info.url as NSURL }
                root.ql.isHidden = false
            } else {
                root.ql.previewItem = nil
                root.ql.isHidden = true
            }
        }
        updateMinSize()
    }

    /// Resim: GIF NSImage olarak (canlanır); diğerleri EXIF yönü uygulanmış, ekran boyuna küçültülmüş CGImage.
    /// Küçük resimler hemen, büyükler arkada çözülür.
    private func loadImage(_ info: FilesPreviewInfo) {
        guard let root else { return }
        imageToken += 1
        let token = imageToken
        let url = info.url
        if info.media == .animated {
            root.imageView.image = NSImage(contentsOf: url)
            return
        }
        let screen = host?.screen ?? NSScreen.main
        let longest = max(screen?.frame.width ?? 1920, screen?.frame.height ?? 1080) * (screen?.backingScaleFactor ?? 2)
        let px = info.mediaPixels ?? .zero
        let maxPixel = min(max(px.width, px.height), longest)
        if px.width * px.height <= 2_500_000 {
            root.imageView.image = Self.decode(url, maxPixel: maxPixel).map { NSImage(cgImage: $0, size: .zero) }
            return
        }
        root.imageView.image = nil
        Task.detached(priority: .userInitiated) {
            let img = Self.decode(url, maxPixel: maxPixel)
            await MainActor.run { [weak self] in
                guard let self, self.imageToken == token, let img else { return }
                self.root?.imageView.image = NSImage(cgImage: img, size: .zero)
            }
        }
    }

    /// EXIF yönünü uygulayarak çöz (iPhone'un yan yatık fotoğrafı dik gelir)
    nonisolated static func decode(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up)))]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Video: hemen oynamaya başlar (Hızlı Bakış gibi); boyu (döndürme dahil) bilinmiyorsa yüklenince pencere yeniden sığar
    private func loadVideo(_ info: FilesPreviewInfo) {
        guard let root else { return }
        let url = info.url
        if (player?.currentItem?.asset as? AVURLAsset)?.url.fileKey != url.fileKey {
            stopPlayer()
            let asset = AVURLAsset(url: url)
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            p.isMuted = muted
            root.playerView.player = p
            player = p
            p.play()
            if info.mediaPixels == nil { loadVideoSize(asset, url: url) }
        }
    }

    private func loadVideoSize(_ asset: AVURLAsset, url: URL) {
        Task { @MainActor [weak self] in
            var px = NSSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                px = NSSize(width: abs(r.width), height: abs(r.height))
            }
            guard let self else { return }
            self.model.setVideoPixels(px, for: url)
            guard self.model.current?.fileKey == url.fileKey else { return }
            if px == .zero {
                // AVFoundation açamadı: Quick Look denesin
                self.loadContent()
            } else {
                self.root?.mediaAspect = self.model.info?.mediaAspect
                self.updateMinSize()
            }
            if let present = self.pendingPresent { present() } else { self.refit(force: true) }
        }
    }

    private func stopPlayer() {
        player?.pause()
        player = nil
        root?.playerView.player = nil
    }

    private func stopMedia() {
        stopPlayer()
        imageToken += 1
        root?.imageView.image = nil
        root?.ql.previewItem = nil
    }

    private func applyPending() {
        guard let p = pending else { return }
        pending = nil
        // İşaretler varken başka dosyaya geçilmez (seçim hatırlanır)
        if markupKeepsPreview(for: p.urls) { markupIgnored = p; return }
        lastApply = CACurrentMediaTime()
        let before = model.current?.fileKey
        model.set(urls: p.urls, index: p.index)
        guard model.current?.fileKey != before else { return }
        loadContent()
        refit(force: true)
    }

    private func step(_ d: Int) {
        model.step(d)
        loadContent()
        refit(force: true)
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

    /// Paylaş düğmesi: Dosyalar'ın temalı Paylaş menüsü, düğmenin hemen altında. Panel anahtar olmaz;
    /// menü kendi panelinde (açılır menü seviyesinde) önizlemenin üstünde açılır, servis Dosyalar penceresinden çalışır.
    private func share(from r: NSRect) {
        guard let panel, let u = model.current else { return }
        let f = panel.frame
        let point = NSPoint(x: f.minX + r.minX, y: f.maxY - r.maxY - 4)
        FilesShare.show(for: [u], at: point, window: host ?? panel) { [weak self] u in self?.sourceFrame(u) }
    }

    /// Makas: önizleme kapanır, ses / video düzenleyicide açılır (önizlemenin yerinden büyüyerek)
    func editCurrent() {
        guard let u = model.current, model.info?.editable == true else { return }
        let frame = panel?.isVisible == true ? panel?.frame : nil
        let c = controller
        close(animated: false)
        FilesMediaEditor.open(u, from: c, sourceFrame: frame)
    }

    /// İşaretlenen fotoğraf kaydedildi: önizleme onu gösterir (üstüne yazıldıysa aynı adla, yeniden çözülerek)
    func showSaved(_ url: URL) {
        guard isVisible else { return }
        model.set(urls: [url], index: 0)
        loadContent()
        refit(force: true)
    }

    private func openCurrent() {
        guard let u = model.current else { return }
        let open = opener
        close(animated: false)
        open(u)
    }

    /// Pencereyi içeriğe yeniden sığdır; merkez yerinde kalır, ekrandan taşmaz.
    /// `force`: öğe değişti (elle verilen boy unutulur); değilse elle boyutlandırılmış pencereye dokunulmaz.
    private func refit(force: Bool = false) {
        if force { userSized = false }
        guard let panel, panel.isVisible, !closing, !userSized else { return }
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

    /// Pencere çerçevesi. Fotoğraf / video: içerik alanı tam ortamın oranında, görünür alanın (20 pt pay, başlık dahil)
    /// izin verdiği en büyük boy; küçük resimler en çok 3 kat. Diğerleri: doğal oranla görünür alanın ~%70'i.
    /// Dosyalar penceresinin ekranında ortalanır (keepCenter: şimdiki merkezde kalır), ekrandan taşmaz.
    func fittedFrame(keepCenter: Bool = false) -> NSRect {
        let screen = host?.screen ?? panel?.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let t = FilesThemeStore.shared.theme
        let header = FilesPreviewLayout.headerHeight(t)
        let size: NSSize
        var area = vf
        if let info = model.info, info.media != .none {
            let scale = screen?.backingScaleFactor ?? 2
            let px = info.mediaPixels ?? NSSize(width: 1920, height: 1080)   // video boyu gelene kadar 16:9
            let pts = NSSize(width: max(1, px.width / scale), height: max(1, px.height / scale))
            let margin = model.zoomed ? 8 : FilesPreviewLayout.mediaMargin
            area = vf.insetBy(dx: margin, dy: margin)
            let maxCW = area.width - 2, maxCH = area.height - header - 1
            var s = min(maxCW / pts.width, maxCH / pts.height)
            // Küçük resim en çok 3 kat büyür (simge ekranı kaplamasın); video her zaman doldurur
            if !model.zoomed, info.media != .video { s = min(s, FilesPreviewLayout.maxUpscale) }
            // Yarım noktaya (Retina pikseli) yuvarla; oran yüksekliği genişlikten türeterek korunur
            let cw = (pts.width * s * 2).rounded(.down) / 2
            let ch = min(maxCH, (cw * pts.height / pts.width * 2).rounded() / 2)
            size = NSSize(width: max(cw + 2, FilesPreviewLayout.mediaMinWidth), height: ch + header + 1)
        } else if model.zoomed {
            return vf.insetBy(dx: 16, dy: 16)
        } else {
            var c = model.info?.renderable == true ? (model.info?.natural ?? NSSize(width: 900, height: 640))
                                                   : FilesPreviewLayout.cardSize
            let maxW = vf.width * 0.7 - 2, maxH = vf.height * 0.7 - header - 1
            let s = min(1, maxW / max(c.width, 1), maxH / max(c.height, 1))
            c = NSSize(width: (c.width * s).rounded(), height: (c.height * s).rounded())
            c.width = max(c.width, FilesPreviewLayout.minWidth - 2)
            c.height = max(c.height, FilesPreviewLayout.minContentHeight)
            size = NSSize(width: c.width + 2, height: c.height + header + 1)
        }
        var center = NSPoint(x: vf.midX, y: vf.midY)
        if keepCenter, let f = panel?.frame, panel?.isVisible == true { center = NSPoint(x: f.midX, y: f.midY) }
        var r = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        // Ekrandan taşmasın
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        r.origin.x = (r.minX * 2).rounded() / 2
        r.origin.y = (r.minY * 2).rounded() / 2
        return r
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
                // Paylaş menüsü açıksa Esc yalnız menüyü kapatır (menünün kendi izleyicisi)
                guard let self, self.isVisible, e.keyCode == 53, !FilesContextMenu.shared.isOpen,
                      !(self.model.markup != nil && e.window === self.panel),   // işaretlerken panelde Esc tuvalin
                      e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      e.window === self.host || e.window === self.panel,
                      !(self.host?.firstResponder is NSText) else { return e }
                self.requestClose()
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

    /// Elle boyutlandırma: fotoğraf / videoda içerik alanının oranı kilitli (başlık yüksekliği sabit)
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let a = model.info?.mediaAspect else { return frameSize }
        let header = FilesPreviewLayout.headerHeight(FilesThemeStore.shared.theme)
        let cur = sender.frame.size
        var cw = frameSize.width - 2, ch = frameSize.height - header - 1
        if abs(frameSize.width - cur.width) >= abs(frameSize.height - cur.height) { ch = cw / a } else { cw = ch * a }
        ch = max(ch, 60)
        // En dar sınırın altında ortam yanlardan boşluklu gösterilir; yükseklik serbest
        if cw + 2 < FilesPreviewLayout.mediaMinWidth { return NSSize(width: FilesPreviewLayout.mediaMinWidth, height: ch + header + 1) }
        return NSSize(width: cw + 2, height: ch + header + 1)
    }
    func windowDidResize(_ notification: Notification) { panel?.invalidateShadow() }
}

// MARK: - Çerçeve (SwiftUI)

struct FilesPreviewChrome: View {
    @ObservedObject var model: FilesPreviewModel
    let actions: FilesPreviewActions
    @Environment(\.filesPalette) private var p
    /// Paylaş düğmesinin pencere içindeki çerçevesi (menü altına açılsın)
    @State private var shareFrame: NSRect = .zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FilesPreviewLayout.radius(p.theme), style: .continuous)
        VStack(spacing: 0) {
            GeometryReader { g in header(level(for: g.size.width)) }
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

    /// Başlığın sıkışma kademesi: full → her şey; compact → "… ile Aç" simgeye iner, sayaç gizlenir;
    /// minimal → yalnız ad, gezinme okları, Aç simgesi ve kapat (büyüt / paylaş / bilgi satırı gizli)
    enum HeaderLevel: Int { case full, compact, minimal }

    @ViewBuilder private func header(_ level: HeaderLevel) -> some View {
        switch p.theme {
        case .missing, .glass: glassyHeader(level)
        case .finder: finderHeader(level)
        case .windows: windowsHeader(level)
        }
    }

    /// Genişliğe göre kademe: düğmelerin ölçüsü bilinir, "… ile Aç" yazısı ölçülür, ada en az yer bırakılır
    private func level(for width: CGFloat) -> HeaderLevel {
        let multi = model.urls.count > 1
        // Düzenle (makas) bir simge düğmesi daha
        let arrows: CGFloat = (multi ? 64 : 0) + (model.info?.editable == true ? 34 : 0) + (model.info?.media == .image ? 34 : 0)
        let counter: CGFloat = multi ? 40 : 0
        let open = openTextWidth
        let full: CGFloat, compact: CGFloat
        switch p.theme {
        case .missing, .glass:
            // kenar payı 26, simge 26, aralıklar 8; büyüt / paylaş / kapat 28
            let base: CGFloat = 26 + 26 + 8 + (multi ? 8 : 0) + 3 * 36
            full = base + 170 + arrows + counter + open + 8
            compact = base + 110 + arrows + 36
        case .finder:
            // kenar payı 16, kapat + büyüt 58, paylaş 28, aralıklar 6
            let base: CGFloat = 16 + 58 + 6 + 34 + (multi ? 6 : 0)
            full = base + 170 + arrows + counter + open + 6
            compact = base + 110 + arrows + 40
        case .windows:
            // komut satırı: kenar payı 24, bilgi satırı, paylaş 28, aralıklar 6
            let base: CGFloat = 24 + 34 + (multi ? 6 : 0)
            full = base + 150 + arrows + counter + open + 6
            compact = base + 90 + arrows + 40
        }
        if width >= full { return .full }
        if width >= compact { return .compact }
        return .minimal
    }

    /// "… ile Aç" düğmesinin genişliği (tema düğmesinin yazı tipi ve iç payıyla)
    private var openTextWidth: CGFloat {
        let t = model.info?.openTitle ?? L("Aç")
        func w(_ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            (t as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width.rounded(.up)
        }
        switch p.theme {
        case .windows: return max(96, w(13, .semibold) + 32)
        case .finder: return w(11, .regular) + 24
        case .missing, .glass: return w(11.5, .semibold) + 22
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

    /// Birden çok öğe seçiliyse önceki / sonraki ve (yer varsa) "2 / 5"
    @ViewBuilder private func navigation(_ level: HeaderLevel) -> some View {
        if model.urls.count > 1 {
            HStack(spacing: p.theme == .finder ? 0 : 4) {
                Button(action: actions.previous) { Image(systemName: "chevron.left") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                    .help(L("Önceki"))
                if level == .full {
                    Text("\(model.index + 1) / \(model.urls.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(p.secondary)
                        .fixedSize()
                        .padding(.horizontal, 2)
                }
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

    /// Sistemin paylaşım seçicisi yerine Dosyalar'ın temalı Paylaş menüsü (FilesShare)
    @ViewBuilder private var shareButton: some View {
        if model.info?.url != nil {
            Button { actions.share(shareFrame) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { shareFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { shareFrame = $0 }
                })
                .help(L("Paylaş"))
        }
    }

    /// Ses / video: makas, düzenleyicide açar (her kademede; ortam penceresi dar olabildiği için en az yer kaplar)
    @ViewBuilder private var editButton: some View {
        if model.info?.editable == true {
            Button(action: actions.edit) { Image(systemName: "scissors") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .help(L("Düzenle"))
                .accessibilityLabel(L("Düzenle"))
        }
    }

    /// Fotoğraf (tek kareli bitmap): işaretle
    @ViewBuilder private var markupButton: some View {
        if model.info?.media == .image {
            Button(action: actions.markup) { Image(systemName: "pencil.tip.crop.circle") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .help(L("İşaretle"))
                .accessibilityLabel(L("İşaretle"))
        }
    }

    /// "… ile Aç": dar başlıkta yalnız simge (adı ipucunda)
    @ViewBuilder private func openButton(_ level: HeaderLevel) -> some View {
        let title = model.info?.openTitle ?? L("Aç")
        if level == .full {
            Button(action: actions.open) { Text(title) }
                .filesButton(.primary, p, small: p.theme != .windows)
                .fixedSize()
        } else {
            Button(action: actions.open) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: p.theme == .windows ? 18 : nil)
            }
            .filesButton(.primary, p, small: true)
            .fixedSize()
            .help(title)
        }
    }

    private var closeButton: some View {
        Button(action: actions.close) { Image(systemName: "xmark") }
            .buttonStyle(FilesPreviewIconButtonStyle(p: p))
            .help(L("Kapat") + "  Esc")
    }

    // missing / glass: solda simge + ad + ikinci satır, sağda düğmeler
    private func glassyHeader(_ level: HeaderLevel) -> some View {
        HStack(spacing: 8) {
            if let m = model.markup { FilesMarkupToolbar(session: m) } else {
            if level != .minimal { iconView(26) }
            VStack(alignment: .leading, spacing: 1) {
                title(size: 13, weight: .semibold)
                if level != .minimal { subtitle }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            navigation(level)
            editButton
            markupButton
            if level != .minimal {
                zoomButton
                shareButton
            }
            openButton(level)
            closeButton
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(p.fg.opacity(p.theme == .glass ? 0.10 : 0.08)).frame(height: 1) }
    }

    // finder: Quick Look paneli: solda kapat + büyüt, ortada ad (altında küçük bilgi), sağda gezinme, paylaş, "… ile Aç"
    private func finderHeader(_ level: HeaderLevel) -> some View {
        HStack(spacing: 6) {
            if let m = model.markup { FilesMarkupToolbar(session: m) } else {
            HStack(spacing: 2) {
                closeButton
                if level != .minimal { zoomButton }
            }
            .fixedSize()
            VStack(spacing: 0) {
                title(size: 12.5, weight: .semibold)
                if level != .minimal {
                    Text(model.secondary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            navigation(level)
            editButton
            markupButton
            if level != .minimal { shareButton }
            openButton(level)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(p.dark ? Color.black.opacity(0.28) : Color.white.opacity(0.45))
        .overlay(alignment: .bottom) { Rectangle().fill(p.dark ? Color.black.opacity(0.5) : Color.black.opacity(0.12)).frame(height: 1) }
    }

    // windows: üstte başlık şeridi (simge, ad, büyüt / kapat başlık düğmeleri), altında komut satırı
    private func windowsHeader(_ level: HeaderLevel) -> some View {
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
                if let m = model.markup { FilesMarkupToolbar(session: m) } else {
                if level == .minimal {
                    Spacer(minLength: 0)
                } else {
                    subtitle.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                }
                navigation(level)
                editButton
                markupButton
                if level != .minimal { shareButton }
                openButton(level)
                }
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
