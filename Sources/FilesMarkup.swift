import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Önizlemede fotoğraf işaretleme: model, çizim ve kaydetme (arayüzden bağımsız)
//
// İşaretler resmin piksel koordinatında tutulur (EXIF yönü uygulanmış dik alan, sol üst köşe başlangıç, y aşağı);
// çizgi kalınlığı ve yazı boyu da piksel. Böylece önizleme hangi boyda olursa olsun ve kaydedilen dosyada aynı görünür.
// Görünüm (FilesMarkupView.swift) yalnız nokta ↔ piksel çevirir.

enum FilesMarkupTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, arrow, rect, ellipse, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: return L("Seç ve taşı")
        case .pen: return L("Kalem")
        case .highlighter: return L("Fosforlu kalem")
        case .arrow: return L("Ok")
        case .rect: return L("Dikdörtgen")
        case .ellipse: return L("Elips")
        case .text: return L("Metin")
        }
    }
}

/// Renk paleti (sRGB)
struct FilesMarkupColor: Equatable {
    let r: CGFloat, g: CGFloat, b: CGFloat
    let name: String

    static let palette: [FilesMarkupColor] = [
        FilesMarkupColor(r: 1.00, g: 0.23, b: 0.19, name: "Kırmızı"),
        FilesMarkupColor(r: 1.00, g: 0.58, b: 0.00, name: "Turuncu"),
        FilesMarkupColor(r: 1.00, g: 0.84, b: 0.04, name: "Sarı"),
        FilesMarkupColor(r: 0.20, g: 0.78, b: 0.35, name: "Yeşil"),
        FilesMarkupColor(r: 0.00, g: 0.48, b: 1.00, name: "Mavi"),
        FilesMarkupColor(r: 1.00, g: 1.00, b: 1.00, name: "Beyaz"),
        FilesMarkupColor(r: 0.00, g: 0.00, b: 0.00, name: "Siyah"),
    ]

    static func at(_ i: Int) -> FilesMarkupColor { palette[min(max(i, 0), palette.count - 1)] }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Üç kalınlık kademesi; ekran noktası cinsinden (çizim anında piksele çevrilir)
enum FilesMarkupWidth {
    static let titles = ["İnce", "Orta", "Kalın"]

    /// Kalem, ok, dikdörtgen, elips
    static let stroke: [CGFloat] = [2, 4, 8]
    /// Fosforlu kalem
    static let highlighter: [CGFloat] = [10, 18, 30]
    /// Metin: yazı boyu
    static let font: [CGFloat] = [14, 22, 34]

    static func points(_ step: Int, for kind: FilesMarkupItem.Kind) -> CGFloat {
        let s = min(max(step, 0), 2)
        switch kind {
        case .highlighter: return highlighter[s]
        case .text: return font[s]
        default: return stroke[s]
        }
    }
}

// MARK: Öğe

struct FilesMarkupItem: Equatable, Identifiable {
    enum Kind: Equatable { case pen, highlighter, arrow, rect, ellipse, text }

    enum Shape: Equatable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        /// Metin ve sol üst köşesi
        case text(String, CGPoint)
    }

    var id = UUID()
    var shape: Shape
    /// Paletteki sıra
    var color: Int
    /// Kalınlık kademesi (0…2); araç çubuğu seçili öğenin kademesini gösterir
    var step: Int
    /// Çizgi kalınlığı ya da yazı boyu, resim pikseli
    var width: CGFloat

    var kind: Kind {
        switch shape {
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .arrow: return .arrow
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .text: return .text
        }
    }

    var text: String? { if case .text(let s, _) = shape { return s } else { return nil } }

    func moved(by d: CGVector) -> FilesMarkupItem {
        var c = self
        let m = { (p: CGPoint) in CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        switch shape {
        case .pen(let pts): c.shape = .pen(pts.map(m))
        case .highlighter(let pts): c.shape = .highlighter(pts.map(m))
        case .arrow(let a, let b): c.shape = .arrow(m(a), m(b))
        case .rect(let r): c.shape = .rect(r.offsetBy(dx: d.dx, dy: d.dy))
        case .ellipse(let r): c.shape = .ellipse(r.offsetBy(dx: d.dx, dy: d.dy))
        case .text(let s, let o): c.shape = .text(s, m(o))
        }
        return c
    }

    /// Kaplanan alan (çizgi kalınlığı dahil), resim pikseli
    var bounds: CGRect {
        let half = width / 2
        switch shape {
        case .pen(let pts), .highlighter(let pts):
            return FilesMarkupGeometry.box(pts).insetBy(dx: -half, dy: -half)
        case .arrow(let a, let b):
            let head = FilesMarkupRenderer.arrowHead(width: width)
            return FilesMarkupGeometry.box([a, b]).insetBy(dx: -head.halfWidth, dy: -head.halfWidth)
        case .rect(let r), .ellipse(let r):
            return r.insetBy(dx: -half, dy: -half)
        case .text(let s, let o):
            let size = FilesMarkupRenderer.textSize(s, fontSize: width)
            return CGRect(origin: o, size: size)
        }
    }
}

// MARK: Geometri

enum FilesMarkupGeometry {
    static func box(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(_ p: CGPoint, polyline pts: [CGPoint]) -> CGFloat {
        guard let f = pts.first else { return .infinity }
        if pts.count == 1 { return hypot(p.x - f.x, p.y - f.y) }
        var d = CGFloat.infinity
        for i in 1..<pts.count { d = min(d, distance(p, pts[i - 1], pts[i])) }
        return d
    }

    /// Dikdörtgenin kenarına uzaklık
    static func distance(_ p: CGPoint, rectBorder r: CGRect) -> CGFloat {
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                 CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        return distance(p, polyline: c)
    }

    /// Elipsin çevresine yaklaşık uzaklık (merkezden geçen ışın boyunca)
    static func distance(_ p: CGPoint, ellipse r: CGRect) -> CGFloat {
        let a = r.width / 2, b = r.height / 2
        let cx = r.midX, cy = r.midY
        let dx = p.x - cx, dy = p.y - cy
        let d = hypot(dx, dy)
        guard a > 0.5, b > 0.5 else { return distance(p, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)) }
        guard d > 0 else { return min(a, b) }
        let ct = dx / d, st = dy / d
        let rr = a * b / sqrt(pow(b * ct, 2) + pow(a * st, 2))
        return abs(d - rr)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Shift: ok 45°'lik adımlara oturur, dikdörtgen kare, elips daire olur
    static func constrain(_ kind: FilesMarkupItem.Kind, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch kind {
        case .arrow:
            let len = hypot(dx, dy)
            guard len > 0 else { return b }
            let step = CGFloat.pi / 4
            let ang = (atan2(dy, dx) / step).rounded() * step
            var x = a.x + len * cos(ang), y = a.y + len * sin(ang)
            // 0°/90° katlarında kayan nokta kırıntısı kalmasın
            if abs(x - a.x) < 1e-6 { x = a.x }
            if abs(y - a.y) < 1e-6 { y = a.y }
            return CGPoint(x: x, y: y)
        case .rect, .ellipse:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s))
        default:
            return b
        }
    }
}

// MARK: Belge (geri al / yinele)

/// İşaretler ve geri alma yığını. Her değişiklik önceki listenin tamamını saklar: geri alma tam olarak önceki hâle döner.
final class FilesMarkupDocument {
    private(set) var items: [FilesMarkupItem] = []
    private var undoStack: [[FilesMarkupItem]] = []
    private var redoStack: [[FilesMarkupItem]] = []
    /// Sürükleme gibi canlı değişikliğin başındaki hâl
    private var liveStart: [FilesMarkupItem]?
    var onChange: () -> Void = {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { items.isEmpty }

    func item(_ id: UUID?) -> FilesMarkupItem? { id.flatMap { id in items.first { $0.id == id } } }

    /// Tek adımlık değişiklik (değişmediyse yığına girmez)
    func apply(_ change: (inout [FilesMarkupItem]) -> Void) {
        let before = items
        change(&items)
        if items != before {
            undoStack.append(before)
            redoStack.removeAll()
        }
        onChange()
    }

    func add(_ item: FilesMarkupItem) { apply { $0.append(item) } }

    func remove(_ id: UUID) { apply { $0.removeAll { $0.id == id } } }

    func update(_ id: UUID, _ change: (inout FilesMarkupItem) -> Void) {
        apply { list in
            if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) }
        }
    }

    /// Canlı değişiklik: başı ve sonu tek geri alma adımı olur
    func beginLive() { liveStart = items }

    func live(_ change: (inout [FilesMarkupItem]) -> Void) {
        if liveStart == nil { liveStart = items }
        change(&items)
        onChange()
    }

    func endLive() {
        if let s = liveStart, s != items {
            undoStack.append(s)
            redoStack.removeAll()
        }
        liveStart = nil
        onChange()
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(items)
        items = s
        onChange()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(items)
        items = s
        onChange()
    }

    /// Noktadaki en üstteki öğe. `tolerance`: çizginin yarı kalınlığına eklenen pay (resim pikseli)
    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> UUID? {
        for it in items.reversed() where Self.hits(it, p, tolerance) { return it.id }
        return nil
    }

    static func hits(_ it: FilesMarkupItem, _ p: CGPoint, _ tol: CGFloat) -> Bool {
        let reach = it.width / 2 + tol
        switch it.shape {
        case .pen(let pts), .highlighter(let pts):
            return FilesMarkupGeometry.distance(p, polyline: pts) <= reach
        case .arrow(let a, let b):
            let head = FilesMarkupRenderer.arrowHead(width: it.width)
            if FilesMarkupGeometry.distance(p, a, b) <= reach { return true }
            return hypot(p.x - b.x, p.y - b.y) <= head.length + tol
        case .rect(let r):
            return FilesMarkupGeometry.distance(p, rectBorder: r) <= reach
        case .ellipse(let r):
            return FilesMarkupGeometry.distance(p, ellipse: r) <= reach
        case .text:
            return it.bounds.insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }
}

// MARK: Çizim

/// İşaretleri bir CGContext'e çizer. Bağlam resim pikseli ölçeğinde ve sol üstten başlayan (y aşağı) olmalı.
enum FilesMarkupRenderer {
    static let highlighterAlpha: CGFloat = 0.45

    static func font(_ size: CGFloat) -> CTFont {
        NSFont.systemFont(ofSize: max(1, size), weight: .semibold) as CTFont
    }

    /// Metnin satırları (taban çizgisi aralığıyla)
    static func lines(_ s: String, fontSize: CGFloat, color: CGColor? = nil) -> (lines: [CTLine], ascent: CGFloat, lineHeight: CGFloat) {
        let f = font(fontSize)
        var attrs: [NSAttributedString.Key: Any] = [.font: f]
        if let color { attrs[.foregroundColor] = color }
        let parts = s.components(separatedBy: "\n")
        let ls = parts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f), leading = CTFontGetLeading(f)
        return (ls, ascent, ceil(ascent + descent + leading))
    }

    static func textSize(_ s: String, fontSize: CGFloat) -> CGSize {
        let l = lines(s, fontSize: fontSize)
        let w = l.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return CGSize(width: max(w, fontSize * 0.3), height: l.lineHeight * CGFloat(max(1, l.lines.count)))
    }

    static func arrowHead(width: CGFloat) -> (length: CGFloat, halfWidth: CGFloat) {
        let length = max(width * 4.5, 6)
        return (length, length * 0.5)
    }

    /// Yumuşatılmış serbest çizgi: ara noktalardan geçen ikinci derece eğriler
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let f = pts.first else { return path }
        path.move(to: f)
        if pts.count == 1 { path.addLine(to: f); return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Okun gövdesi (başın tabanına kadar) ve dolu başı
    static func arrowPaths(_ a: CGPoint, _ b: CGPoint, width: CGFloat) -> (line: CGPath, head: CGPath) {
        let len = hypot(b.x - a.x, b.y - a.y)
        var head = arrowHead(width: width)
        if len < head.length * 1.2 {
            let k = len / max(head.length * 1.2, 0.001)
            head = (head.length * k, head.halfWidth * k)
        }
        let ux = len > 0 ? (b.x - a.x) / len : 1, uy = len > 0 ? (b.y - a.y) / len : 0
        let base = CGPoint(x: b.x - ux * head.length, y: b.y - uy * head.length)
        let line = CGMutablePath()
        line.move(to: a)
        // Gövde başın içine biraz girer: arada boşluk görünmesin
        line.addLine(to: CGPoint(x: base.x + ux * head.length * 0.3, y: base.y + uy * head.length * 0.3))
        let h = CGMutablePath()
        h.move(to: b)
        h.addLine(to: CGPoint(x: base.x - uy * head.halfWidth, y: base.y + ux * head.halfWidth))
        h.addLine(to: CGPoint(x: base.x + uy * head.halfWidth, y: base.y - ux * head.halfWidth))
        h.closeSubpath()
        return (line, h)
    }

    static func cornerRadius(_ r: CGRect, width: CGFloat) -> CGFloat {
        max(0, min(width * 1.2, min(r.width, r.height) / 2))
    }

    static func draw(_ items: [FilesMarkupItem], in ctx: CGContext, skip: UUID? = nil) {
        for it in items where it.id != skip { draw(it, in: ctx) }
    }

    static func draw(_ it: FilesMarkupItem, in ctx: CGContext) {
        let color = FilesMarkupColor.at(it.color).cg
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(it.width)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        switch it.shape {
        case .pen(let pts):
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .highlighter(let pts):
            // Tek seferde çizilir: üst üste binen yerler koyulaşmaz; çarpma karışımı altındaki resmi boyar
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(highlighterAlpha)
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .arrow(let a, let b):
            let p = arrowPaths(a, b, width: it.width)
            ctx.setLineCap(.butt)
            ctx.addPath(p.line)
            ctx.strokePath()
            ctx.addPath(p.head)
            ctx.fillPath()
        case .rect(let r):
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cornerRadius(r, width: it.width),
                               cornerHeight: cornerRadius(r, width: it.width), transform: nil))
            ctx.strokePath()
        case .ellipse(let r):
            ctx.addEllipse(in: r)
            ctx.strokePath()
        case .text(let s, let o):
            let l = lines(s, fontSize: it.width, color: color)
            for (i, line) in l.lines.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: o.x, y: o.y + l.ascent + CGFloat(i) * l.lineHeight)
                ctx.scaleBy(x: 1, y: -1)        // bağlam y aşağı; yazı dik çıksın
                ctx.textMatrix = .identity
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }
}

// MARK: Kaydetme

enum FilesMarkupError: LocalizedError {
    case unreadable
    case encodeFailed
    case failed(String)

    var errorDescription: String? { L("Kaydedilemedi") }

    var failureReason: String? {
        switch self {
        case .unreadable: return L("Resim okunamadı.")
        case .encodeFailed: return nil
        case .failed(let s): return s
        }
    }
}

enum FilesMarkupSaver {
    enum Mode { case overwrite, newFile }

    struct Plan {
        /// Yazılacak tür (UTI) ve uzantı; asıl biçim yazılamıyorsa PNG
        let type: String
        let ext: String
        let sameFormat: Bool
        let canOverwrite: Bool
    }

    /// Denemeler için: geçici dosya yazıldıktan sonra çağrılır (hata atarsa kaydetme geri alınır)
    nonisolated(unsafe) static var afterTempWrite: ((URL) throws -> Void)?

    static func plan(for url: URL) -> Plan {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        let srcType = src.flatMap { CGImageSourceGetType($0) as String? }
        let frames = src.map(CGImageSourceGetCount) ?? 0
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let raw = srcType.flatMap { UTType($0) }?.conforms(to: .rawImage) ?? false
        if let t = srcType, writable.contains(t), !raw, frames >= 1 {
            let fm = FileManager.default
            let dirOK = fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
            let fileOK = fm.isWritableFile(atPath: url.path)
            // Çok sayfalı / çok kareli dosyanın üstüne yazılırsa diğer kareler kaybolurdu
            return Plan(type: t, ext: url.pathExtension, sameFormat: true, canOverwrite: dirOK && fileOK && frames == 1)
        }
        return Plan(type: UTType.png.identifier, ext: "png", sameFormat: false, canOverwrite: false)
    }

    /// "<ad> (işaretli).<uzantı>", alınmışsa "<ad> (işaretli) 2.<uzantı>" …
    static func newFileURL(for url: URL, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let stem = "\(url.deletingPathExtension().lastPathComponent) (\(L("işaretli")))"
        let fm = FileManager.default
        var u = dir.appendingPathComponent(stem).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return u
    }

    /// EXIF yönünü uygulayan dönüşüm (CG koordinatı, y yukarı): ham w×h resim dik alana çizilir
    static func orientationTransform(_ o: Int, w: CGFloat, h: CGFloat) -> CGAffineTransform {
        switch o {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }

    /// Tam piksel boyunda, dik, işaretli resim ve yazılacak özellikler
    static func render(_ url: URL, items: [FilesMarkupItem]) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw FilesMarkupError.unreadable }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let w = img.width, h = img.height
        let (W, H) = o >= 5 && o <= 8 ? (h, w) : (w, h)

        let alpha: Bool
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        var space = img.colorSpace
        if space?.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB) }
        let bpc = img.bitsPerComponent > 8 ? 16 : 8
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        guard let cs = space,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: bpc, bytesPerRow: 0, space: cs, bitmapInfo: info)
              ?? CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { throw FilesMarkupError.encodeFailed }
        ctx.interpolationQuality = .none
        ctx.saveGState()
        ctx.concatenate(orientationTransform(o, w: CGFloat(w), h: CGFloat(h)))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        // İşaretler sol üstten başlayan piksel koordinatında
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        FilesMarkupRenderer.draw(items, in: ctx)
        guard let out = ctx.makeImage() else { throw FilesMarkupError.encodeFailed }

        // Üst veri: EXIF, GPS, TIFF, IPTC taşınır; yön 1, boyutlar yeni resmin
        var meta: [CFString: Any] = [:]
        for k in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                  kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[k] { meta[k] = v }
        }
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = W
            exif[kCGImagePropertyExifPixelYDimension] = H
            meta[kCGImagePropertyExifDictionary] = exif
        }
        return (out, meta)
    }

    /// Yazar ve yazılan dosyayı döndürür. Üstüne yazmada asıl dosya Çöp Sepeti'ne gider (geri alınabilir).
    /// Hata olursa geçici dosya silinir, asıl dosyaya dokunulmaz.
    static func save(_ url: URL, items: [FilesMarkupItem], mode: Mode) throws -> (url: URL, trashed: URL?) {
        let fm = FileManager.default
        let plan = plan(for: url)
        if mode == .overwrite, !plan.canOverwrite { throw FilesMarkupError.failed(L("Bu dosyanın üstüne yazılamıyor.")) }
        var dest = mode == .overwrite ? url : newFileURL(for: url, ext: plan.ext)
        let dir = dest.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(dest.deletingPathExtension().lastPathComponent).missing-\(UUID().uuidString.prefix(8)).\(plan.ext)")
        do {
            let r = try render(url, items: items)
            guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, plan.type as CFString, 1, nil) else {
                throw FilesMarkupError.failed(L("Bu klasöre yazılamıyor."))
            }
            var props = r.properties
            if let t = UTType(plan.type), t.conforms(to: .jpeg) || t.conforms(to: .heic) || t.conforms(to: .heif) {
                props[kCGImageDestinationLossyCompressionQuality] = 0.92
            }
            CGImageDestinationAddImage(d, r.image, props as CFDictionary)
            guard CGImageDestinationFinalize(d), fm.fileExists(atPath: tmp.path) else { throw FilesMarkupError.encodeFailed }
            try afterTempWrite?(tmp)

            var trashedURL: URL?
            switch mode {
            case .overwrite:
                let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate]
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                do {
                    try fm.moveItem(at: tmp, to: url)
                } catch {
                    if let t = trashed as URL? { try? fm.moveItem(at: t, to: url) }
                    throw error
                }
                if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
                trashedURL = trashed as URL?
            case .newFile:
                if fm.fileExists(atPath: dest.path) { dest = newFileURL(for: url, ext: plan.ext) }
                try fm.moveItem(at: tmp, to: dest)
            }
            return (dest, trashedURL)
        } catch {
            try? fm.removeItem(at: tmp)
            if let e = error as? FilesMarkupError { throw e }
            throw FilesMarkupError.failed(error.localizedDescription)
        }
    }
}
