import AppKit
import AVFoundation
import CoreMedia

// MARK: - Düzenleyicinin zaman çizelgesi (AppKit, elle çizilir)
//
// Parçalar sırayla, aralarında küçük boşlukla yuvarlak bloklar. Video parçası: üstte küçük resim şeridi, altında
// dalga biçimi; ses parçası: dalga biçimi. Eklenen dosyadan gelen parça biraz farklı renkte ve üstünde adı yazar.
// Seçili parçanın kenarı vurgu renginde.
//
// Fare: cetvelde bas / sürükle → oynatma başı; parçaya tık → seç ve oraya git; parçada sürükle → aralık seçimi
// (giriş / çıkış tutamaçları sürüklenir, uzunluğu cetvelde yazar); parçanın sol / sağ kenarını sürükle → kırp;
// parçanın üst şeridinden (ya da ⌥ ile herhangi bir yerinden) sürükle → sırasını değiştir. En baştaki ve en sondaki
// "+" dosya ekler. Dosyalar'dan / Finder'dan bırakılan ses ve video en yakın sınıra eklenir (ekleme çizgisi görünür).
// Yakınlaştırma: kaydırıcı ve iki parmakla sıkıştırma; uzun dosyada yatay kaydırma (dikey tekerlek de yatay kaydırır).
//
// Yük: yalnız görünen kısım çizilir; küçük resimler görünen döşemeler için istenir (en çok 2 iş aynı anda, kaynak
// dosya + kaynak zamanına göre önbellekte, düzenlemeden sonra da geçerli); dalga biçimi düzenleme başına bir kez.

@MainActor final class FilesMediaTimelineContainer: NSView {
    weak var editor: FilesMediaEditorController? { didSet { document.editor = editor } }
    let scroll = FilesMediaTimelineScrollView()
    let document = FilesMediaTimelineView()
    private var lastWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if bounds.width != lastWidth || document.frame.height != scroll.contentSize.height {
            lastWidth = bounds.width
            document.relayout(keep: true)
        }
    }

    func projectChanged() { document.projectChanged() }
    func zoomChanged(to z: Double) { document.setZoom(z) }
    func follow(_ t: CMTime) { document.follow(t) }
    func teardown() { document.teardown() }
}

/// Dikey tekerlek yatay kaydırsın (fareyle uzun dosyada gezinmek için)
final class FilesMediaTimelineScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.hasPreciseScrollingDeltas,
           let cg = event.cgEvent?.copy() {
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            if let e = NSEvent(cgEvent: cg) { super.scrollWheel(with: e); return }
        }
        super.scrollWheel(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Önbellekteki küçük resim
private final class FilesMediaThumb: NSObject {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

@MainActor final class FilesMediaTimelineView: NSView {
    weak var editor: FilesMediaEditorController?
    var project: MediaEditProject? { didSet { relayout(keep: false) } }
    var palette = FilesPalette(theme: .missing, dark: true) { didSet { needsDisplay = true } }
    var playhead: CMTime = .zero {
        didSet {
            guard playhead != oldValue else { return }
            let a = x(for: oldValue.seconds), b = x(for: playhead.seconds)
            setNeedsDisplay(NSRect(x: a - 9, y: 0, width: 18, height: bounds.height))
            setNeedsDisplay(NSRect(x: b - 9, y: 0, width: 18, height: bounds.height))
        }
    }

    struct Seg {
        let id: UUID
        let index: Int
        let start: Double
        let dur: Double
        let x0: CGFloat
        let x1: CGFloat
        let segment: MediaSegment
        let added: Bool
    }

    private(set) var segs: [Seg] = []
    private(set) var pps: CGFloat = 50
    private(set) var zoom: Double = 0
    private var total: Double = 0

    static let padL: CGFloat = 40
    static let padR: CGFloat = 40
    static let gap: CGFloat = 4
    static let rulerH: CGFloat = 22
    static let stripH: CGFloat = 15

    // Sürükleme
    enum Drag {
        case none
        case scrub
        case pending(seg: Seg?, start: NSPoint, reorder: Bool)
        case select(anchor: Double)
        case handle(isIn: Bool)
        case trim(seg: Seg, left: Bool, startX: CGFloat)
        case reorder(seg: Seg)
    }
    private(set) var drag: Drag = .none
    /// Kırpma sürerken önerilen yeni kaynak aralığı
    private(set) var trimPreview: (id: UUID, range: CMTimeRange)?
    private var reorderX: CGFloat = 0
    /// Sırası değişecek / bırakılacak dosyanın ekleneceği sınır (0…parça sayısı)
    private(set) var insertionIndex: Int?
    /// Sıkıştırma (pinch) çapası
    private var zoomAnchor: CGFloat?

    // Önbellek
    private let thumbs = NSCache<NSString, FilesMediaThumb>()
    private var queue: [(key: String, time: Double, x: CGFloat, rev: Int)] = []
    private var inFlight = Set<String>()
    private var workers = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var wave: [Float] = []
    private var waveRev = -1
    private var waveBuckets = 0
    private var waveTask: Task<Void, Never>?
    private var closed = false
    /// Deneme düzeneği: kaç küçük resim / dalga biçimi istendi
    private(set) var thumbRequests = 0
    private(set) var waveRequests = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumbs.countLimit = 400
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    private var state: FilesMediaEditorState? { editor?.state }

    // MARK: Yerleşim

    var visibleWidth: CGFloat { enclosingScrollView?.contentView.bounds.width ?? bounds.width }

    var fitPPS: CGFloat {
        let n = CGFloat(max(0, (project?.segments.count ?? 1) - 1))
        let avail = max(60, visibleWidth - Self.padL - Self.padR - n * Self.gap)
        return avail / CGFloat(max(total, 0.05))
    }

    var maxPPS: CGFloat { max(fitPPS * 1.5, 320) }

    /// Parçaların yerini yeniden hesapla. `keep`: soldaki görünen zaman yerinde kalsın
    func relayout(keep: Bool) {
        let anchorTime = keep ? time(at: visibleRect.minX + 1) : 0
        let anchorOffset = keep ? x(for: anchorTime) - visibleRect.minX : 0
        guard let p = project else {
            segs = []
            total = 0
            setFrameSize(NSSize(width: visibleWidth, height: enclosingScrollView?.contentSize.height ?? bounds.height))
            needsDisplay = true
            return
        }
        total = max(0, p.duration.seconds)
        let fit = fitPPS
        pps = fit * CGFloat(pow(Double(maxPPS / fit), zoom))
        var out: [Seg] = []
        var t = 0.0
        var x = Self.padL
        let origKey = p.original.fileKey
        for (i, s) in p.segments.enumerated() {
            let d = max(0, s.duration.seconds)
            let w = CGFloat(d) * pps
            out.append(Seg(id: s.id, index: i, start: t, dur: d, x0: x, x1: x + w, segment: s, added: s.source.fileKey != origKey))
            t += d
            x += w + Self.gap
        }
        segs = out
        let width = max(visibleWidth, (out.last?.x1 ?? Self.padL) + Self.padR)
        let height = enclosingScrollView?.contentSize.height ?? bounds.height
        setFrameSize(NSSize(width: width.rounded(.up), height: height))
        if keep, let clip = enclosingScrollView?.contentView {
            let nx = max(0, min(width - visibleWidth, self.x(for: anchorTime) - anchorOffset))
            clip.scroll(to: NSPoint(x: nx, y: 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func projectChanged() {
        trimPreview = nil
        insertionIndex = nil
        relayout(keep: true)
    }

    func setZoom(_ z: Double) {
        guard z != zoom else { return }
        // Çapa: sıkıştırmada farenin altı, değilse görünüyorsa oynatma başı, yoksa görünen ortası
        let vr = visibleRect
        let ph = x(for: playhead.seconds)
        let ax = zoomAnchor ?? (vr.minX...vr.maxX ~= ph ? ph : vr.midX)
        zoomAnchor = nil
        let at = time(at: ax)
        let offset = ax - vr.minX
        zoom = z
        relayout(keep: false)
        if let clip = enclosingScrollView?.contentView {
            let nx = max(0, min(frame.width - visibleWidth, x(for: at) - offset))
            clip.scroll(to: NSPoint(x: nx, y: 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Oynarken oynatma başı görünen alandan çıkarsa sayfa kaydır
    func follow(_ t: CMTime) {
        guard state?.isPlaying == true, case .none = drag else { return }
        let px = x(for: t.seconds)
        let vr = visibleRect
        guard px > vr.maxX - 16 || px < vr.minX else { return }
        if let clip = enclosingScrollView?.contentView {
            let nx = max(0, min(frame.width - visibleWidth, px - 40))
            clip.scroll(to: NSPoint(x: nx, y: 0))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Çizelge zamanının x konumu
    func x(for t: Double) -> CGFloat {
        guard let first = segs.first else { return Self.padL }
        if t <= 0 { return first.x0 }
        for s in segs where t <= s.start + s.dur { return s.x0 + CGFloat(t - s.start) * pps }
        return segs.last!.x1
    }

    /// x konumundaki çizelge zamanı
    func time(at x: CGFloat) -> Double {
        guard !segs.isEmpty else { return 0 }
        for s in segs where x < s.x1 + Self.gap / 2 {
            return s.start + min(s.dur, max(0, Double((x - s.x0) / pps)))
        }
        return total
    }

    var trackRect: NSRect {
        NSRect(x: 0, y: Self.rulerH + 6, width: bounds.width, height: max(20, bounds.height - Self.rulerH - 6 - 14))
    }

    func blockRect(_ s: Seg) -> NSRect {
        let t = trackRect
        return NSRect(x: s.x0, y: t.minY, width: max(2, s.x1 - s.x0), height: t.height)
    }

    var startPlusRect: NSRect {
        let t = trackRect
        return NSRect(x: Self.padL / 2 - 12, y: t.midY - 12, width: 24, height: 24)
    }

    var endPlusRect: NSRect {
        let t = trackRect
        let x = (segs.last?.x1 ?? Self.padL) + Self.padR / 2
        return NSRect(x: x - 12, y: t.midY - 12, width: 24, height: 24)
    }

    /// x'e en yakın sınır (0: en baş, parça sayısı: en son)
    func nearestBoundary(_ x: CGFloat) -> Int {
        guard !segs.isEmpty else { return 0 }
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in 0...segs.count {
            let bx = boundaryX(i)
            let d = abs(bx - x)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func boundaryX(_ i: Int) -> CGFloat {
        guard !segs.isEmpty else { return Self.padL }
        if i <= 0 { return segs[0].x0 - Self.gap / 2 }
        if i >= segs.count { return segs.last!.x1 + Self.gap / 2 }
        return segs[i - 1].x1 + Self.gap / 2
    }

    // MARK: Önbellek ve istekler

    func teardown() {
        closed = true
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        waveTask?.cancel()
        waveTask = nil
        queue.removeAll()
        inFlight.removeAll()
        thumbs.removeAllObjects()
        wave = []
        project = nil
        unregisterDraggedTypes()
    }

    var pendingWork: Int { tasks.count + (waveTask == nil ? 0 : 1) }

    private func thumbKey(_ s: MediaSegment, sourceSeconds: Double) -> String {
        "\(s.source.path)|\(Int((sourceSeconds * 20).rounded()))"
    }

    private func requestThumb(key: String, time: Double, x: CGFloat) {
        guard !closed, !inFlight.contains(key), let p = project else { return }
        inFlight.insert(key)
        queue.append((key, time, x, p.revision))
        pump()
    }

    /// En yeni istek önce (son kaydırılan yer); görünmeyen ya da eski düzenlemeye ait istek atlanır
    private func pump() {
        guard let p = project else { return }
        let h = max(24, thumbHeight * (window?.backingScaleFactor ?? 2))
        while workers < 2, let r = queue.popLast() {
            let vr = visibleRect.insetBy(dx: -tileWidth, dy: 0)
            guard r.rev == p.revision, r.x >= vr.minX, r.x <= vr.maxX else { inFlight.remove(r.key); continue }
            workers += 1
            thumbRequests += 1
            let id = UUID()
            tasks[id] = Task { [weak self, weak p] in
                let img = await p?.thumbnail(at: CMTime(seconds: r.time, preferredTimescale: 600), maxHeight: h)
                guard let self else { return }
                self.tasks[id] = nil
                self.workers -= 1
                guard !self.closed else { return }
                self.inFlight.remove(r.key)
                if let img { self.thumbs.setObject(FilesMediaThumb(img), forKey: r.key as NSString) }
                self.setNeedsDisplay(self.trackRect.intersection(self.visibleRect))
                self.pump()
            }
        }
        if queue.count > 64 {
            let drop = queue.count - 64
            queue.prefix(drop).forEach { inFlight.remove($0.key) }
            queue.removeFirst(drop)
        }
    }

    /// Dalga biçimi: düzenleme başına, yaklaşık 2 nokta başına bir değer
    private func ensureWave() {
        guard let p = project, waveTask == nil, !closed else { return }
        let content = (segs.last?.x1 ?? 0) - Self.padL
        let want = min(8000, max(64, Int(content / 2)))
        if waveRev == p.revision, waveBuckets > 0, abs(Double(want - waveBuckets)) / Double(want) < 0.3 { return }
        let rev = p.revision
        waveRequests += 1
        waveTask = Task { [weak self, weak p] in
            let w = await p?.waveform(buckets: want) ?? []
            guard let self else { return }
            self.waveTask = nil
            guard !self.closed, let p, p.revision == rev else {
                if !(self.closed) { self.needsDisplay = true }
                return
            }
            self.wave = w
            self.waveRev = rev
            self.waveBuckets = want
            self.setNeedsDisplay(self.trackRect.intersection(self.visibleRect))
        }
    }

    private var aspect: CGFloat {
        let s = project?.renderSize ?? .zero
        return s.width > 0 && s.height > 0 ? s.width / s.height : 16.0 / 9.0
    }

    private var isVideo: Bool { project?.kind == .video }

    private var filmRect: (CGFloat, CGFloat) {
        let t = trackRect
        let top = t.minY + Self.stripH
        let h = isVideo ? ((t.height - Self.stripH) * 0.6).rounded() : 0
        return (top, h)
    }

    private var thumbHeight: CGFloat { filmRect.1 }
    private var tileWidth: CGFloat { max(24, (thumbHeight * aspect).rounded()) }

    // MARK: Renkler

    private var p: FilesPalette { palette }
    private var addedTint: NSColor {
        p.theme == .glass ? NSColor(srgbRed: 0.30, green: 0.78, blue: 0.95, alpha: 1)
                          : NSColor(srgbRed: 0.22, green: 0.72, blue: 0.68, alpha: 1)
    }
    private var playheadColor: NSColor { p.dark ? .white : NSColor(white: 0.08, alpha: 1) }
    private var radius: CGFloat {
        switch p.theme {
        case .windows: return 4
        case .glass: return 8
        case .finder: return 5
        case .missing: return 6
        }
    }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        guard project != nil else { return }
        drawRuler(dirtyRect)
        let track = trackRect
        for s in segs {
            let r = blockRect(s)
            guard r.insetBy(dx: -4, dy: 0).intersects(dirtyRect) else { continue }
            drawSegment(s, rect: r, dirty: dirtyRect)
        }
        drawPlus(startPlusRect)
        drawPlus(endPlusRect)
        drawSelection(track)
        drawTrimPreview(track)
        drawReorder(track)
        if let i = insertionIndex { drawInsertion(boundaryX(i), track) }
        drawPlayhead()
        ensureWave()
    }

    private func drawRuler(_ dirty: NSRect) {
        let h = Self.rulerH
        p.nsFG.withAlphaComponent(p.dark ? 0.035 : 0.03).setFill()
        NSRect(x: dirty.minX, y: 0, width: dirty.width, height: h).fill()
        p.nsFG.withAlphaComponent(p.dark ? 0.10 : 0.10).setFill()
        NSRect(x: dirty.minX, y: h - 1, width: dirty.width, height: 1).fill()
        guard total > 0 else { return }
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let major = steps.first { $0 * Double(pps) >= 64 } ?? 3600
        let minor = major / (major == 15 || major == 0.2 || major == 2 || major == 120 ? 4 : 5)
        let showMinor = minor * Double(pps) >= 7
        let t0 = max(0, time(at: dirty.minX - 60))
        let t1 = min(total, time(at: dirty.maxX + 60))
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: p.nsFG.withAlphaComponent(p.dark ? 0.55 : 0.55)]
        let tick = p.nsFG.withAlphaComponent(p.dark ? 0.30 : 0.28)
        let unit = showMinor ? minor : major
        var k = (t0 / unit).rounded(.down)
        while k * unit <= t1 + 0.0001 {
            let t = k * unit
            let isMajor = abs((t / major).rounded() - t / major) < 0.0001
            let px = x(for: t).rounded() + 0.5
            tick.setFill()
            NSRect(x: px - 0.5, y: isMajor ? h - 9 : h - 5, width: 1, height: isMajor ? 8 : 4).fill()
            if isMajor {
                let label = major < 1 ? Self.shortLabel(t, tenths: true) : Self.shortLabel(t, tenths: false)
                (label as NSString).draw(at: NSPoint(x: px + 3, y: 3), withAttributes: attr)
            }
            k += 1
        }
    }

    /// Cetvel yazısı: "0:05", "1:30", kısa adımda "0:01.5"
    static func shortLabel(_ t: Double, tenths: Bool) -> String {
        let total = Int((t * 10).rounded())
        let tn = total % 10, s = (total / 10) % 60, m = (total / 600) % 60, h = total / 36000
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if tenths { out += ".\(tn)" }
        return out
    }

    private func drawSegment(_ s: Seg, rect r: NSRect, dirty: NSRect) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let selected = state?.selectedID == s.id
        let base: NSColor = s.added ? addedTint.withAlphaComponent(p.dark ? 0.22 : 0.20)
                                    : p.nsFG.withAlphaComponent(p.dark ? 0.09 : 0.06)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        base.setFill()
        r.fill()
        // Üst şerit: tutamaç + ad (eklenen dosya) ya da süre
        let strip = NSRect(x: r.minX, y: r.minY, width: r.width, height: Self.stripH)
        (s.added ? addedTint.withAlphaComponent(p.dark ? 0.38 : 0.32) : p.nsFG.withAlphaComponent(p.dark ? 0.07 : 0.05)).setFill()
        strip.fill()
        drawStripLabel(s, strip)
        let (filmTop, filmH) = filmRect
        if isVideo, filmH > 0 {
            drawFilmstrip(s, top: filmTop, height: filmH, rect: r, dirty: dirty)
        }
        let waveTop = filmTop + filmH + (filmH > 0 ? 1 : 0)
        drawWave(s, NSRect(x: r.minX, y: waveTop, width: r.width, height: r.maxY - waveTop), dirty: dirty)
        NSGraphicsContext.restoreGraphicsState()
        // Kenar
        if selected {
            p.nsAccent.setStroke()
            let sp = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
            sp.lineWidth = 2
            sp.stroke()
        } else {
            (s.added ? addedTint.withAlphaComponent(0.55) : p.nsFG.withAlphaComponent(p.dark ? 0.12 : 0.14)).setStroke()
            let sp = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            sp.lineWidth = 1
            sp.stroke()
        }
    }

    private func drawStripLabel(_ s: Seg, _ strip: NSRect) {
        guard strip.width > 14 else { return }
        // Tutamaç: 2 × 3 nokta
        p.nsFG.withAlphaComponent(0.45).setFill()
        for c in 0..<2 {
            for rr in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: strip.minX + 6 + CGFloat(c) * 3.5, y: strip.minY + 3.5 + CGFloat(rr) * 3, width: 2, height: 2)).fill()
            }
        }
        guard strip.width > 40 else { return }
        let text = s.added ? s.segment.source.lastPathComponent + " · " + FilesMediaEditor.clock(s.dur, centis: false)
                           : FilesMediaEditor.clock(s.dur)
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: p.nsFG.withAlphaComponent(s.added ? 0.9 : 0.62)]
        let tr = NSRect(x: strip.minX + 17, y: strip.minY + 1.5, width: strip.width - 22, height: Self.stripH - 2)
        (text as NSString).draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attr)
    }

    private func drawFilmstrip(_ s: Seg, top: CGFloat, height: CGFloat, rect r: NSRect, dirty: NSRect) {
        let tw = tileWidth
        let lo = max(r.minX, dirty.minX), hi = min(r.maxX, dirty.maxX)
        guard hi > lo else { return }
        var i = Int(((lo - r.minX) / tw).rounded(.down))
        let placeholder = p.nsFG.withAlphaComponent(p.dark ? 0.05 : 0.05)
        let ctx = NSGraphicsContext.current?.cgContext
        while true {
            let tx = r.minX + CGFloat(i) * tw
            if tx >= hi { break }
            let tile = NSRect(x: tx, y: top, width: tw, height: height)
            let off = min(max(0, s.dur - 0.01), Double((CGFloat(i) * tw + tw / 2) / pps))
            let src = s.segment.range.start.seconds + off
            let key = thumbKey(s.segment, sourceSeconds: src)
            if let th = thumbs.object(forKey: key as NSString), let ctx {
                // Çevrilmiş görünüm: resmi dik çiz, döşemeyi doldurarak (taşan kırpılır)
                let iw = CGFloat(th.image.width), ih = CGFloat(th.image.height)
                let sc = max(tile.width / iw, tile.height / ih)
                let dw = iw * sc, dh = ih * sc
                ctx.saveGState()
                ctx.clip(to: tile)
                ctx.translateBy(x: tile.midX, y: tile.midY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(th.image, in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
                ctx.restoreGState()
            } else {
                placeholder.setFill()
                tile.insetBy(dx: 0.5, dy: 0).fill()
                requestThumb(key: key, time: s.start + off, x: tx)
            }
            i += 1
        }
        // Döşemeler arası ince çizgi
        NSColor.black.withAlphaComponent(0.25).setFill()
        var k = Int(((lo - r.minX) / tw).rounded(.down)) + 1
        while r.minX + CGFloat(k) * tw < hi {
            NSRect(x: r.minX + CGFloat(k) * tw, y: top, width: 0.5, height: height).fill()
            k += 1
        }
    }

    private func drawWave(_ s: Seg, _ wr: NSRect, dirty: NSRect) {
        guard wr.height > 4 else { return }
        let lo = max(wr.minX + 2, dirty.minX), hi = min(wr.maxX - 2, dirty.maxX)
        guard hi > lo else { return }
        let mid = wr.midY
        let usable = wr.height - 6
        let color = s.added ? addedTint.withAlphaComponent(0.95) : p.nsFG.withAlphaComponent(p.dark ? 0.55 : 0.45)
        color.setFill()
        let path = NSBezierPath()
        let n = wave.count
        let fresh = waveRev == project?.revision && n > 0
        var px = (lo / 2).rounded(.down) * 2
        while px < hi {
            var v: CGFloat = 0.02
            if fresh, total > 0 {
                let t0 = s.start + Double((px - s.x0) / pps)
                let t1 = s.start + Double((px + 2 - s.x0) / pps)
                let a = max(0, min(n - 1, Int(t0 / total * Double(n))))
                let b = max(a, min(n - 1, Int(t1 / total * Double(n))))
                var m: Float = 0
                for k in a...b { m = max(m, wave[k]) }
                v = max(0.02, CGFloat(m))
            }
            let h = max(1, v * usable)
            path.appendRect(NSRect(x: px, y: mid - h / 2, width: 1.2, height: h))
            px += 2
        }
        path.fill()
    }

    private func drawPlus(_ r: NSRect) {
        guard r.intersects(visibleRect) else { return }
        let circle = NSBezierPath(ovalIn: r)
        p.nsFG.withAlphaComponent(p.dark ? 0.09 : 0.06).setFill()
        circle.fill()
        p.nsFG.withAlphaComponent(p.dark ? 0.18 : 0.16).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        p.nsFG.withAlphaComponent(0.75).setFill()
        NSRect(x: r.midX - 5, y: r.midY - 0.75, width: 10, height: 1.5).fill()
        NSRect(x: r.midX - 0.75, y: r.midY - 5, width: 1.5, height: 10).fill()
    }

    var selectionRect: NSRect? {
        guard let sel = state?.selection, sel.duration.seconds > 0 else { return nil }
        let a = x(for: sel.start.seconds), b = x(for: sel.end.seconds)
        let t = trackRect
        return NSRect(x: a, y: t.minY, width: max(1, b - a), height: t.height)
    }

    private func drawSelection(_ track: NSRect) {
        guard let r = selectionRect, let sel = state?.selection else { return }
        p.nsAccent.withAlphaComponent(p.dark ? 0.22 : 0.18).setFill()
        r.fill(using: .sourceOver)
        p.nsAccent.setFill()
        // Kenar çizgileri ve tutamaçlar
        NSRect(x: r.minX - 1, y: r.minY - 3, width: 2, height: r.height + 6).fill()
        NSRect(x: r.maxX - 1, y: r.minY - 3, width: 2, height: r.height + 6).fill()
        for hx in [r.minX, r.maxX] {
            NSBezierPath(roundedRect: NSRect(x: hx - 4, y: r.minY - 4, width: 8, height: 16), xRadius: 2.5, yRadius: 2.5).fill()
        }
        NSRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1.5).fill()
        NSRect(x: r.minX, y: r.maxY - 0.5, width: r.width, height: 1.5).fill()
        // Uzunluk: cetvelde hap
        let text = FilesMediaEditor.length(sel.duration.seconds)
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: (p.theme == .windows && p.dark) ? NSColor.black : NSColor.white]
        let sz = (text as NSString).size(withAttributes: attr)
        let pw = sz.width + 12
        let px = min(max(r.midX - pw / 2, visibleRect.minX + 2), visibleRect.maxX - pw - 2)
        let pill = NSRect(x: px, y: 3, width: pw, height: 16)
        p.nsAccent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + (16 - sz.height) / 2), withAttributes: attr)
    }

    private func drawTrimPreview(_ track: NSRect) {
        guard case .trim(let s, let left, _) = drag, let tp = trimPreview, tp.id == s.id else { return }
        let orig = s.segment.range
        let r = blockRect(s)
        let edgeX: CGFloat
        if left {
            let d = CGFloat((tp.range.start - orig.start).seconds) * pps
            edgeX = r.minX + d
            if d > 0 {
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSRect(x: r.minX, y: r.minY, width: d, height: r.height).fill()
            } else if d < 0 {
                p.nsAccent.withAlphaComponent(0.25).setFill()
                NSRect(x: edgeX, y: r.minY, width: -d, height: r.height).fill()
            }
        } else {
            let d = CGFloat((tp.range.end - orig.end).seconds) * pps
            edgeX = r.maxX + d
            if d < 0 {
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSRect(x: edgeX, y: r.minY, width: -d, height: r.height).fill()
            } else if d > 0 {
                p.nsAccent.withAlphaComponent(0.25).setFill()
                NSRect(x: r.maxX, y: r.minY, width: d, height: r.height).fill()
            }
        }
        p.nsAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: edgeX - 2, y: r.minY - 2, width: 4, height: r.height + 4), xRadius: 2, yRadius: 2).fill()
        let text = FilesMediaEditor.clock(tp.range.duration.seconds)
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                                                   .foregroundColor: (p.theme == .windows && p.dark) ? NSColor.black : NSColor.white]
        let sz = (text as NSString).size(withAttributes: attr)
        let pill = NSRect(x: edgeX - sz.width / 2 - 6, y: 3, width: sz.width + 12, height: 16)
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + (16 - sz.height) / 2), withAttributes: attr)
    }

    private func drawReorder(_ track: NSRect) {
        guard case .reorder(let s) = drag else { return }
        let r = blockRect(s)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        let w = min(r.width, 180)
        let g = NSRect(x: reorderX - w / 2, y: r.minY + 6, width: w, height: r.height - 12)
        p.nsAccent.withAlphaComponent(0.28).setFill()
        let gp = NSBezierPath(roundedRect: g, xRadius: radius, yRadius: radius)
        gp.fill()
        p.nsAccent.setStroke()
        gp.lineWidth = 1.5
        gp.stroke()
    }

    private func drawInsertion(_ bx: CGFloat, _ track: NSRect) {
        p.nsAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: bx - 1.5, y: track.minY - 4, width: 3, height: track.height + 8), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(ovalIn: NSRect(x: bx - 5, y: track.minY - 10, width: 10, height: 10)).fill()
    }

    private func drawPlayhead() {
        let px = x(for: playhead.seconds).rounded() + 0.5
        guard px >= visibleRect.minX - 10, px <= visibleRect.maxX + 10 else { return }
        playheadColor.setFill()
        NSRect(x: px - 0.75, y: 2, width: 1.5, height: bounds.height - 6).fill()
        let knob = NSBezierPath()
        knob.move(to: NSPoint(x: px - 6, y: 1))
        knob.line(to: NSPoint(x: px + 6, y: 1))
        knob.line(to: NSPoint(x: px + 6, y: 10))
        knob.line(to: NSPoint(x: px, y: 16))
        knob.line(to: NSPoint(x: px - 6, y: 10))
        knob.close()
        knob.fill()
    }

    // MARK: İmleç

    override func resetCursorRects() {
        let vr = visibleRect
        let t = trackRect
        for s in segs {
            for ex in [s.x0, s.x1] where ex > vr.minX - 6 && ex < vr.maxX + 6 {
                addCursorRect(NSRect(x: ex - 5, y: t.minY + Self.stripH, width: 10, height: t.height - Self.stripH), cursor: .resizeLeftRight)
            }
            let strip = NSRect(x: s.x0 + 6, y: t.minY, width: max(0, s.x1 - s.x0 - 12), height: Self.stripH)
            if strip.width > 0, segs.count > 1 { addCursorRect(strip.intersection(vr), cursor: .openHand) }
        }
        addCursorRect(startPlusRect, cursor: .pointingHand)
        addCursorRect(endPlusRect, cursor: .pointingHand)
    }

    // MARK: Fare

    /// Kenar isabeti: (parça, sol mu)
    func edgeHit(_ pt: NSPoint) -> (Seg, Bool)? {
        let t = trackRect
        guard pt.y >= t.minY + Self.stripH, pt.y <= t.maxY else { return nil }
        var best: (Seg, Bool, CGFloat)?
        for s in segs {
            for (left, ex) in [(true, s.x0), (false, s.x1)] {
                let d = abs(pt.x - ex)
                if d <= 6, best == nil || d < best!.2 { best = (s, left, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    func segment(at x: CGFloat) -> Seg? { segs.first { x >= $0.x0 && x <= $0.x1 } }

    override func mouseDown(with event: NSEvent) {
        guard let ed = editor, project != nil, ed.state.overlay == nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if startPlusRect.contains(pt) { ed.addClip(atStart: true); return }
        if endPlusRect.contains(pt) { ed.addClip(atStart: false); return }
        if ed.state.isPlaying, pt.y >= Self.rulerH { ed.pause() }
        let t = trackRect
        if pt.y < Self.rulerH + 4 || pt.y > t.maxY {
            drag = .scrub
            ed.seek(CMTime(seconds: time(at: pt.x), preferredTimescale: 600))
            return
        }
        if let r = selectionRect {
            if abs(pt.x - r.minX) <= 6 { drag = .handle(isIn: true); return }
            if abs(pt.x - r.maxX) <= 6 { drag = .handle(isIn: false); return }
        }
        if let (s, left) = edgeHit(pt) {
            drag = .trim(seg: s, left: left, startX: pt.x)
            trimPreview = (s.id, s.segment.range)
            return
        }
        if let s = segment(at: pt.x) {
            let inStrip = pt.y < t.minY + Self.stripH
            drag = .pending(seg: s, start: pt, reorder: inStrip || event.modifierFlags.contains(.option))
        } else {
            drag = .pending(seg: nil, start: pt, reorder: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ed = editor, let p = project else { return }
        let pt = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .scrub:
            ed.seek(CMTime(seconds: time(at: pt.x), preferredTimescale: 600))
        case .pending(let s, let start, let reorder):
            guard hypot(pt.x - start.x, pt.y - start.y) > 3 else { return }
            if reorder, let s, segs.count > 1 {
                drag = .reorder(seg: s)
                NSCursor.closedHand.set()
            } else {
                drag = .select(anchor: time(at: start.x))
            }
            mouseDragged(with: event)
            return
        case .select(let anchor):
            let tt = time(at: pt.x)
            let a = min(anchor, tt), b = max(anchor, tt)
            ed.state.selection = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
        case .handle(let isIn):
            guard let sel = ed.state.selection else { return }
            let tt = CMTime(seconds: time(at: pt.x), preferredTimescale: 600)
            let minLen = CMTime(value: 1, timescale: 100)
            if isIn {
                ed.state.selection = CMTimeRange(start: min(tt, sel.end - minLen), end: sel.end)
            } else {
                ed.state.selection = CMTimeRange(start: sel.start, end: max(tt, sel.start + minLen))
            }
        case .trim(let s, let left, let startX):
            trimPreview = (s.id, trimmedRange(s, left: left, dx: pt.x - startX, frame: p.frameDuration))
            setNeedsDisplay(visibleRect)
        case .reorder:
            reorderX = pt.x
            insertionIndex = nearestBoundary(pt.x)
            setNeedsDisplay(visibleRect)
        }
        autoscroll(with: event)
    }

    /// Kırpılmış kaynak aralığı: en az bir kare; sol kenar 0'dan, sağ kenar kaynağın sonundan öteye gitmez
    func trimmedRange(_ s: Seg, left: Bool, dx: CGFloat, frame: CMTime) -> CMTimeRange {
        let orig = s.segment.range
        let minDur = max(frame.isValid && frame > .zero ? frame.seconds : 1.0 / 30, 0.05)
        let d = Double(dx / pps)
        if left {
            let ns = max(0, min(orig.end.seconds - minDur, orig.start.seconds + d))
            return CMTimeRange(start: CMTime(seconds: ns, preferredTimescale: 600), end: orig.end)
        }
        let limit = project?.source(for: s.segment)?.duration.seconds ?? orig.end.seconds
        let ne = min(max(orig.end.seconds, limit), max(orig.start.seconds + minDur, orig.end.seconds + d))
        return CMTimeRange(start: orig.start, end: CMTime(seconds: ne, preferredTimescale: 600))
    }

    override func mouseUp(with event: NSEvent) {
        guard let ed = editor else { drag = .none; return }
        let pt = convert(event.locationInWindow, from: nil)
        let d = drag
        drag = .none
        switch d {
        case .pending(let s, _, _):
            // Tık: parçayı seç (boşlukta seçimi bırak), aralık seçimini kaldır, oraya git
            ed.state.selectedID = s?.id
            ed.state.selection = nil
            ed.seek(CMTime(seconds: time(at: pt.x), preferredTimescale: 600))
        case .select:
            if let sel = ed.state.selection, sel.duration.seconds < 0.02 { ed.state.selection = nil }
        case .trim(let s, _, _):
            let tp = trimPreview
            trimPreview = nil
            if let tp, tp.id == s.id, tp.range != s.segment.range {
                ed.trim(s.id, to: tp.range)
            }
            setNeedsDisplay(visibleRect)
        case .reorder(let s):
            let target = insertionIndex
            insertionIndex = nil
            NSCursor.arrow.set()
            setNeedsDisplay(visibleRect)
            if let target, target != s.index, target != s.index + 1 {
                // Sınır sırası → taşındıktan sonraki sıra (motor parçayı önce çıkarır)
                ed.move(s.id, to: target > s.index ? target - 1 : target)
                ed.state.selectedID = s.id
            }
        default:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        guard let ed = editor else { return }
        zoomAnchor = convert(event.locationInWindow, from: nil).x
        ed.zoom(by: Double(event.magnification) * 0.9)
        // Değer değişmediyse (sınırda) çapa kalmasın
        DispatchQueue.main.async { MainActor.assumeIsolated { self.zoomAnchor = nil } }
    }

    // MARK: Bırakma

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FilesMediaEditor.canEdit($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard project != nil, editor?.state.overlay == nil, !droppedURLs(sender).isEmpty else {
            if insertionIndex != nil { insertionIndex = nil; setNeedsDisplay(visibleRect) }
            return []
        }
        let i = nearestBoundary(convert(sender.draggingLocation, from: nil).x)
        if i != insertionIndex { insertionIndex = i; setNeedsDisplay(visibleRect) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionIndex = nil
        setNeedsDisplay(visibleRect)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        let i = insertionIndex ?? nearestBoundary(convert(sender.draggingLocation, from: nil).x)
        insertionIndex = nil
        setNeedsDisplay(visibleRect)
        guard !urls.isEmpty, let ed = editor else { return false }
        ed.insert(urls, at: i)
        return true
    }

    // MARK: Deneme düzeneği için

    /// Bırakma çizgisini göster (ekran görüntüsü)
    func showInsertion(_ i: Int?) { insertionIndex = i; needsDisplay = true }
}
