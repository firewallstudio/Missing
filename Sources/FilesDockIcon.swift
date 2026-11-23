import AppKit

// MARK: - Dosyalar penceresinin Dock simgesi
//
// Finder gibi mavi gradyanlı zemin, ortasında arka plansız Missing yaprağı. Hem uygulama (pencere açıkken) hem de
// Dock'ta tutulan simgeyi çizen eklenti (DockTile/) bu dosyayı kullanır; başka dosyaya bağlı değil.

enum FilesDockIcon {
    /// leafURL: ortaya konacak yaprak (Resources/Leaf@2x.png, arka plansız)
    static func make(leafURL: URL?) -> NSImage {
        let side: CGFloat = 512
        let leaf = leafURL.flatMap { NSImage(contentsOf: $0) }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // macOS simge ızgarası: 1024'te 824'lük gövde, ~185 köşe
            let inset = side * 0.098
            let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

            NSGraphicsContext.saveGraphicsState()
            let drop = NSShadow()
            drop.shadowColor = NSColor.black.withAlphaComponent(0.28)
            drop.shadowBlurRadius = side * 0.02
            drop.shadowOffset = NSSize(width: 0, height: -side * 0.008)
            drop.set()
            NSColor(srgbRed: 0.12, green: 0.50, blue: 0.96, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Finder gibi açık maviden koyu maviye
            NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.80, blue: 1.00, alpha: 1),
                                NSColor(srgbRed: 0.18, green: 0.58, blue: 0.98, alpha: 1),
                                NSColor(srgbRed: 0.08, green: 0.40, blue: 0.92, alpha: 1)],
                       atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: shape, angle: -90)
            // Üstte hafif parlama
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
                .draw(in: NSBezierPath(roundedRect: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
                                       xRadius: body.width * 0.225, yRadius: body.width * 0.225), angle: -90)

            guard let leaf else { return true }
            let d = side * 0.52
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor(srgbRed: 0.02, green: 0.12, blue: 0.40, alpha: 0.45)
            sh.shadowBlurRadius = side * 0.03
            sh.shadowOffset = NSSize(width: 0, height: -side * 0.012)
            sh.set()
            leaf.draw(in: NSRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d),
                      from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Uygulamanın içinden
    static var app: NSImage { make(leafURL: Bundle.main.url(forResource: "Leaf@2x", withExtension: "png")) }
}
