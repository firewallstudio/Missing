import AppKit

// Missing Dock'ta tutulduğunda (pencere kapalıyken) simgesi yaprak değil dosya klasörü görünsün.
// Dock bu eklentiyi Missing.app/Contents/PlugIns/ içinden yükler.

@objc(MissingDockTilePlugIn)
final class MissingDockTilePlugIn: NSObject, NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {
        guard let tile = dockTile else { return }
        // .../Missing.app/Contents/PlugIns/MissingDockTile.docktileplugin → .../Contents/Resources/Leaf@2x.png
        let contents = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let leaf = contents.appendingPathComponent("Resources/Leaf@2x.png")
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = FilesDockIcon.make(leafURL: leaf)
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
}
