import AppKit
import UniformTypeIdentifiers

// MARK: - Dosyalar penceresinin Dock simgesi
//
// Finder gibi bir klasör; önünde Missing yaprağı kabartma olarak. Hem uygulama (pencere açıkken)
// hem de Dock'ta tutulan simgeyi çizen eklenti (DockTile/) bu dosyayı kullanır; başka dosyaya bağlı değil.

enum FilesDockIcon {
    /// leafURL: yaprak resmi (Resources/Leaf@2x.png)
    static func make(leafURL: URL?) -> NSImage {
        let side: CGFloat = 512
        let folder = NSWorkspace.shared.icon(for: .folder)
        let leaf = leafURL.flatMap { NSImage(contentsOf: $0) }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            folder.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            guard let leaf else { return true }
            // Klasörün ön yüzüne, Finder'ın İndirilenler okundaki gibi koyu mavi kabartma
            let s = side * 0.30
            let rect = NSRect(x: (side - s) / 2, y: side * 0.25, width: s, height: s)
            let tinted = NSImage(size: rect.size, flipped: false) { tr in
                leaf.draw(in: tr, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor(srgbRed: 0.10, green: 0.42, blue: 0.80, alpha: 0.78).set()
                tr.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// Uygulamanın içinden
    static var app: NSImage { make(leafURL: Bundle.main.url(forResource: "Leaf@2x", withExtension: "png")) }
}
