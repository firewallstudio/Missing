import AppKit
import SwiftUI

// MARK: - Bırakma geri bildirimi
//
// Dosya sürüklenip bırakmayı kabul edecek bir klasörün üstüne gelince: klasörün ağzı açılır
// (ön kapak öne yatar, içindeki kâğıt görünür) ve satırın / kutunun zemini temanın vurgusuyla hafifçe boyanır.
// Izgara, liste ve sütunlar aynı parçaları kullanır; kenar çubuğu için SwiftUI hâli de burada.

extension FilesPalette {
    /// Bırakma hedefi zemini: vurgu, düşük opaklık (fare üstü griden ve seçimden belirgin biçimde farklı)
    var nsDropFill: NSColor {
        switch theme {
        case .missing: return Brand.nsRed.withAlphaComponent(dark ? 0.20 : 0.13)
        case .finder: return nsAccent.withAlphaComponent(dark ? 0.24 : 0.15)
        case .windows: return nsAccent.withAlphaComponent(dark ? 0.20 : 0.13)
        case .glass: return nsAccent.withAlphaComponent(dark ? 0.26 : 0.22)
        }
    }
    /// Bırakma hedefinin ince kenarı
    var nsDropStroke: NSColor { nsAccent.withAlphaComponent(dark ? 0.85 : 0.75) }
    var dropStrokeWidth: CGFloat { 1.5 }
    var dropFill: Color { Color(nsColor: nsDropFill) }
    var dropStroke: Color { Color(nsColor: nsDropStroke) }
}

@MainActor enum FilesDropFeedback {
    /// Kapak açılma / kapanma süresi
    static let duration: CFTimeInterval = 0.16
    /// Açıkken simgenin büyümesi (küçük liste simgesinde biraz daha fazla, yoksa fark edilmez)
    static func scale(forIconSide side: CGFloat) -> CGFloat { side <= 24 ? 1.14 : 1.08 }

    /// Kapalı simge → açık simge; nil: bu klasör kendi simgesini korur (özel simge, kısayol, disk…)
    private static let cache = NSMapTable<NSImage, NSImage>.weakToStrongObjects()
    private static let keepOwn = NSImage()

    static func openIcon(for item: FileItem?, base: NSImage) -> NSImage? {
        if let c = cache.object(forKey: base) { return c === keepOwn ? nil : c }
        let open = item.map(keepsOwnIcon) == true ? nil : openFolder(base)
        cache.setObject(open ?? keepOwn, forKey: base)
        return open
    }

    /// Kısayollar, diskler ve kendine özel simgesi olan klasörler kendi simgesini korur (sadece zemin ve büyüme)
    static func keepsOwnIcon(_ item: FileItem) -> Bool {
        if !item.isFolder || item.isLinkToFolder { return true }
        if (try? item.url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { return true }
        return FileManager.default.fileExists(atPath: item.url.appendingPathComponent("Icon\r").path)
    }

    // MARK: Açık klasör çizimi

    /// Klasör simgesinin ölçüleri (alttan, 0…1): ön kapağın alt ve üst kenarı, sol ve sağ kenar
    struct Shape: Equatable {
        var bottom: CGFloat, frontTop: CGFloat, left: CGFloat, right: CGFloat
    }

    /// Simgeyi küçük çizip ön kapağın üst kenarını bulur (arka yüzle ön kapağın tonu farklı: ortadaki sütunda parlaklık sıçraması).
    /// Klasöre benzemeyen simgede nil
    static func measure(_ base: NSImage) -> Shape? {
        let n = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: n * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep), let px = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        base.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        // Satır yukarıdan sayılır
        func alpha(_ x: Int, _ y: Int) -> CGFloat { CGFloat(px[(y * n + x) * 4 + 3]) / 255 }
        func lum(_ x: Int, _ y: Int) -> CGFloat {
            let i = (y * n + x) * 4, a = max(1, CGFloat(px[i + 3]))
            return (0.30 * CGFloat(px[i]) + 0.59 * CGFloat(px[i + 1]) + 0.11 * CGFloat(px[i + 2])) / a
        }
        let cx = n / 2
        guard let top = (0..<n).first(where: { alpha(cx, $0) > 0.9 }),
              let last = (0..<n).last(where: { alpha(cx, $0) > 0.9 }) else { return nil }
        // En büyük sıçrama (üst kenardaki parlak çizgi daha küçük bir sıçramadır)
        var front: Int?
        var best: CGFloat = 0.035
        for y in (top + 1)..<min(n, top + 18) where alpha(cx, y) > 0.9 && alpha(cx, y - 1) > 0.9 {
            let d = abs(lum(cx, y) - lum(cx, y - 1))
            if d > best { best = d; front = y }
        }
        guard let front else { return nil }
        let mid = (front + last) / 2
        guard let l = (0..<n).first(where: { alpha($0, mid) > 0.9 }),
              let r = (0..<n).last(where: { alpha($0, mid) > 0.9 }) else { return nil }
        let s = Shape(bottom: 1 - CGFloat(last + 1) / CGFloat(n), frontTop: 1 - CGFloat(front) / CGFloat(n),
                      left: CGFloat(l) / CGFloat(n), right: CGFloat(r + 1) / CGFloat(n))
        guard s.frontTop > 0.5, s.frontTop < 0.92, s.frontTop - s.bottom > 0.35, s.right - s.left > 0.6 else { return nil }
        return s
    }

    /// Açık klasör: arka yüz aynı kalır, ön kapak alttan menteşeli öne yatar (kısalır, üstü genişler),
    /// aradan klasörün gölgeli içi ve bir kâğıt görünür. Renk etiketli klasörün boyası simgeden geldiği için korunur
    static func openFolder(_ base: NSImage) -> NSImage? {
        guard let shape = measure(base) else { return nil }
        let img = NSImage(size: base.size, flipped: false) { r in
            drawOpen(base, shape, in: r)
            return true
        }
        return img
    }

    /// Simgeyi px × px bitmap'e çizer
    static func bitmap(_ image: NSImage, pixels px: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func drawOpen(_ base: NSImage, _ g: Shape, in r: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let w = r.width, h = r.height
        // Kaynak bir kez, çizileceği piksel boyunda bitmap'e çevrilir: her şerit aynı pikselleri kullanır
        // (boyalı klasör simgesi kendi çizim bloğuyla gelir; şerit şerit yeniden çizilince kenarları dalgalanıyordu)
        let dev = cg.convertToDeviceSpace(CGSize(width: w, height: h))
        let px = Int(min(1024, max(16, max(abs(dev.width), abs(dev.height)).rounded(.up))))
        var proposed = NSRect(x: 0, y: 0, width: px, height: px)
        guard let src = Self.bitmap(base, pixels: px) ?? base.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        let b = r.minY + g.bottom * h, f = r.minY + g.frontTop * h
        let l = r.minX + g.left * w, rt = r.minX + g.right * w
        let cx = (l + rt) / 2
        let k: CGFloat = px <= 48 ? 0.58 : 0.66   // ön kapağın kalan boyu (küçük simgede ağız daha açık)
        let widen: CGFloat = 0.075   // kapağın üst kenarı bize yaklaştıkça genişler
        let flapTop = b + (f - b) * k
        let hair = max(0.5, h / 256)

        // 1) Arka yüz ve klasörün içi: ön kapağın yeri koyulaşır
        cg.draw(src, in: r)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: r.minX, y: b - h * 0.02, width: w, height: f - b + h * 0.02).clip()
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSGradient(starting: NSColor.black.withAlphaComponent(0.16), ending: NSColor.black.withAlphaComponent(0.34))?
            .draw(in: NSRect(x: r.minX, y: b, width: w, height: f - b), angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // 2) İçerideki kâğıt
        let pw = (rt - l) * 0.70
        let paper = NSRect(x: cx - pw / 2, y: b + (f - b) * 0.30, width: pw, height: (f - b) * 0.70 - h * 0.012)
        let pr = w * 0.025
        NSGraphicsContext.saveGraphicsState()
        let ps = NSShadow()
        ps.shadowColor = NSColor.black.withAlphaComponent(0.18)
        ps.shadowBlurRadius = h * 0.02
        ps.shadowOffset = NSSize(width: 0, height: -h * 0.006)
        ps.set()
        NSColor(white: 0.985, alpha: 1).setFill()
        NSBezierPath(roundedRect: paper, xRadius: pr, yRadius: pr).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Kâğıtta silik satırlar (büyük boyda)
        if h >= 48 {
            NSColor.black.withAlphaComponent(0.10).setFill()
            var y = paper.maxY - h * 0.06
            while y > flapTop + h * 0.02 {
                NSRect(x: paper.minX + pw * 0.14, y: y, width: pw * 0.72, height: hair * 1.5).fill()
                y -= h * 0.045
            }
        }

        // 3) Kapağın içeri düşen gölgesi
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: l, y: flapTop, width: rt - l, height: f - flapTop).clip()
        NSGradient(starting: NSColor.black.withAlphaComponent(0.30), ending: NSColor.black.withAlphaComponent(0))?
            .draw(in: NSRect(x: l, y: flapTop, width: rt - l, height: h * 0.08), angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // 4) Ön kapak: şeritler hâlinde, alttan yukarı kısalıp genişleyerek (perspektif)
        func map(_ y: CGFloat) -> CGFloat { y <= b ? y : b + (y - b) * k }
        let strips = min(512, max(12, px))   // piksel başına bir şerit: yanlarda basamak görünmesin
        let y0All = r.minY
        for i in 0..<strips {
            let y0 = y0All + (f - y0All) * CGFloat(i) / CGFloat(strips)
            let y1 = y0All + (f - y0All) * CGFloat(i + 1) / CGFloat(strips)
            let d0 = map(y0), d1 = map(y1)
            let t = min(1, max(0, ((y0 + y1) / 2 - b) / (f - b)))
            let sx = 1 + widen * t
            let sy = (d1 - d0) / (y1 - y0)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: r.minX - w, y: d0, width: w * 3, height: d1 - d0 + (i < strips - 1 ? hair : 0)).clip()
            let tr = NSAffineTransform()
            tr.translateX(by: cx * (1 - sx), yBy: d0 - sy * y0)
            tr.scaleX(by: sx, yBy: sy)
            tr.concat()
            cg.draw(src, in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Kapağın üst kenarı ışık alır
        let half = (rt - l) / 2 * (1 + widen)
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSRect(x: cx - half + w * 0.02, y: flapTop - hair * 1.5, width: half * 2 - w * 0.04, height: hair * 1.5).fill()
    }
}

// MARK: - AppKit simgesi: açılıp kapanma

extension FilesIconView {
    /// Bırakma hedefi olunca açık klasöre geçer (soluklaşarak, hafif büyüyerek); bırakınca / uzaklaşınca kapanır.
    /// Açık hâli olmayan simge (özel simge, kısayol) kendi resmini korur, sadece büyür
    func setDropOpen(_ open: Bool, item: FileItem?, animated: Bool = true) {
        guard open != isDropOpen else { return }
        isDropOpen = open
        wantsLayer = true
        if open {
            dropClosedImage = image
            dropOpenImage = image.flatMap { FilesDropFeedback.openIcon(for: item, base: $0) }
            if let o = dropOpenImage {
                if animated { addFade() }
                image = o
            }
        } else {
            // Bu arada simge başka biri tarafından değiştirildiyse ona dokunma
            if let o = dropOpenImage, image === o {
                if animated { addFade() }
                image = dropClosedImage
            }
            dropClosedImage = nil
            dropOpenImage = nil
        }
        applyDropTransform(animated: animated)
    }

    /// Hücre yeniden kullanılmadan önce: kapalı, büyütmesiz, animasyonsuz
    func resetDropOpen() {
        guard isDropOpen || dropOpenImage != nil else { return }
        if let o = dropOpenImage, image === o { image = dropClosedImage }
        isDropOpen = false
        dropClosedImage = nil
        dropOpenImage = nil
        layer?.removeAnimation(forKey: "dropFade")
        layer?.removeAnimation(forKey: "dropScale")
        layer?.transform = CATransform3DIdentity
    }

    private func addFade() {
        let t = CATransition()
        t.type = .fade
        t.duration = FilesDropFeedback.duration
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(t, forKey: "dropFade")
    }

    /// Ortasından büyüt (katmanın çapası sol alt köşede olduğu için merkeze taşıyıp ölçekle)
    private func applyDropTransform(animated: Bool) {
        guard let layer else { return }
        let to: CATransform3D
        if isDropOpen {
            let s = FilesDropFeedback.scale(forIconSide: min(bounds.width, bounds.height))
            let ax = layer.bounds.width * layer.anchorPoint.x, ay = layer.bounds.height * layer.anchorPoint.y
            let cx = layer.bounds.midX - ax, cy = layer.bounds.midY - ay
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DScale(t, s, s, 1)
            to = CATransform3DTranslate(t, -cx, -cy, 0)
        } else {
            to = CATransform3DIdentity
        }
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        CATransaction.commit()
        guard animated, !CATransform3DEqualToTransform(from, to) else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: to)
        a.duration = FilesDropFeedback.duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "dropScale")
    }
}

// MARK: - Kenar çubuğu (SwiftUI)

/// SF Symbol simgeli satır için aynı geri bildirim: hedefken dolu / açık simge, vurgu rengi, küçük bir sıçrama.
/// Kullanım: `FilesDropTargetSymbol(symbol: place.symbol, isTargeted: dropTarget, color: iconColor, palette: p)`
struct FilesDropTargetSymbol: View {
    let symbol: String
    let isTargeted: Bool
    /// Hedef değilken simgenin rengi
    var color: Color
    var palette: FilesPalette

    var body: some View {
        Image(systemName: isTargeted ? Self.openVariant(of: symbol) : symbol)
            .foregroundStyle(isTargeted ? palette.accent : color)
            .scaleEffect(isTargeted ? 1.2 : 1, anchor: .center)
            .offset(y: isTargeted ? -0.5 : 0)
            .animation(isTargeted ? .spring(response: 0.22, dampingFraction: 0.5) : .easeOut(duration: FilesDropFeedback.duration),
                       value: isTargeted)
    }

    /// "folder" → "folder.fill"; dolu hâli olmayan simge olduğu gibi kalır
    static func openVariant(of symbol: String) -> String {
        guard !symbol.hasSuffix(".fill") else { return symbol }
        let fill = symbol + ".fill"
        return NSImage(systemSymbolName: fill, accessibilityDescription: nil) != nil ? fill : symbol
    }
}

/// Bırakma hedefi zemini: temanın vurgusu düşük opaklıkta + ince vurgu kenarı, temanın köşe yarıçapıyla
struct FilesDropTargetBackground: ViewModifier {
    let isTargeted: Bool
    let palette: FilesPalette
    var cornerRadius: CGFloat? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? max(4, palette.radius - 1), style: .continuous)
        return content.background(
            shape.fill(palette.dropFill)
                .overlay(shape.strokeBorder(palette.dropStroke, lineWidth: palette.dropStrokeWidth))
                .opacity(isTargeted ? 1 : 0)
                .animation(.easeOut(duration: FilesDropFeedback.duration), value: isTargeted)
        )
    }
}

extension View {
    /// Bırakma hedefiyken satırın zemini (kenar çubuğu satırları için)
    func filesDropTarget(_ isTargeted: Bool, palette: FilesPalette, cornerRadius: CGFloat? = nil) -> some View {
        modifier(FilesDropTargetBackground(isTargeted: isTargeted, palette: palette, cornerRadius: cornerRadius))
    }
}
