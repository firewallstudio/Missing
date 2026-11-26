import AppKit
import SwiftUI

// MARK: - Dosyalar'ın kendi sağ tık menüsü (macOS cam menü)
//
// İçerik bugünkü NSMenu'dan gelir (eylemler, hedefler, alt menüler aynen çalışır); sadece çizim bizim:
// cam zemin, simgeli satırlar, sağda kısayol, alt menüler yana açılır. Dışarı tıklayınca, Esc ile ya da
// bir satır seçilince kapanır.

@MainActor final class FilesContextMenu: ObservableObject {
    static let shared = FilesContextMenu()

    private var panels: [NSPanel] = []          // 0: ana menü, 1…: yana açılan alt menüler
    @Published private var openItems: [NSMenuItem?] = []   // her seviyede açık alt menünün sahibi
    private var monitors: [Any] = []
    private var root: NSMenu?
    private var pendingOpen: DispatchWorkItem?

    var isOpen: Bool { !panels.isEmpty }

    /// Menüyü ekrandaki bir noktada aç (sol üst köşe orada olur; sığmazsa yukarı / sola kayar)
    private var lastShow: (time: TimeInterval, point: NSPoint)?

    func show(_ menu: NSMenu, at point: NSPoint, eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Aynı sağ tık için ikinci kez açılmasın (seçim değişince görünüm yeniden çizilirken tekrar tetiklenebilir)
        if let l = lastShow, abs(l.time - eventTime) < 0.25, hypot(l.point.x - point.x, l.point.y - point.y) < 4, isOpen { return }
        lastShow = (eventTime, point)
        close()
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        // İçeriği kendi menümüze taşı: tarayıcı menüsünü yeniden kurarsa açık menü bozulmasın
        let snapshot = NSMenu()
        snapshot.autoenablesItems = false
        let items = menu.items
        menu.removeAllItems()
        items.forEach(snapshot.addItem)
        root = snapshot
        present(snapshot, level: 0, anchor: NSRect(origin: point, size: .zero), side: .below)
        installMonitors()
    }

    func close() {
        pendingOpen?.cancel()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        openItems.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        root = nil
    }

    // MARK: Paneller

    private enum Side { case below, right }

    private func present(_ menu: NSMenu, level: Int, anchor: NSRect, side: Side) {
        // Bu seviyeden sonrakileri kapat
        while panels.count > level { panels.removeLast().orderOut(nil) }
        while openItems.count > level { openItems.removeLast() }

        let view = FilesMenuList(items: menu.items, level: level, controller: self)
        let host = FilesMenuHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let size = host.fittingSize
        let panel = FilesMenuPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = host
        panel.isReleasedWhenClosed = false

        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        switch side {
        case .below:
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
            if origin.y < vis.minY { origin.y = min(anchor.minY, vis.maxY - size.height) }
            if origin.x + size.width > vis.maxX { origin.x = anchor.minX - size.width }
        case .right:
            // Satırın hizasında, sağa; sığmazsa sola
            origin = NSPoint(x: anchor.maxX - 2, y: anchor.maxY - size.height + 6)
            if origin.x + size.width > vis.maxX { origin.x = anchor.minX - size.width + 2 }
            if origin.y < vis.minY { origin.y = vis.minY }
        }
        origin.x = max(vis.minX, origin.x)
        panel.setFrameOrigin(origin)
        // Odak pencerede kalsın (panel anahtar olmaz); Esc yerel izleyiciyle yakalanır
        panel.orderFrontRegardless()
        panels.append(panel)
        openItems.append(nil)
    }

    /// Satırın üstüne gelindi: alt menüyse biraz bekleyip yana aç, değilse daha derin menüleri kapat
    fileprivate func hover(_ item: NSMenuItem, level: Int, rowFrame: NSRect) {
        pendingOpen?.cancel()
        guard let sub = item.submenu, item.isEnabled else {
            closeDeeper(than: level)
            return
        }
        if openItems.indices.contains(level), openItems[level] === item { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.openSubmenu(item, sub, level: level, rowFrame: rowFrame) }
        }
        pendingOpen = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func openSubmenu(_ item: NSMenuItem, _ sub: NSMenu, level: Int, rowFrame: NSRect) {
        guard panels.indices.contains(level) else { return }
        if sub.numberOfItems == 0 { sub.delegate?.menuNeedsUpdate?(sub) }
        sub.update()
        present(sub, level: level + 1, anchor: screenRect(rowFrame, in: panels[level]), side: .right)
        openItems[level] = item
    }

    private func closeDeeper(than level: Int) {
        while panels.count > level + 1 { panels.removeLast().orderOut(nil) }
        while openItems.count > level + 1 { openItems.removeLast() }
        if openItems.indices.contains(level) { openItems[level] = nil }
    }

    /// SwiftUI'deki satır çerçevesi (pencere içi, üstten) → ekran
    private func screenRect(_ r: NSRect, in panel: NSPanel) -> NSRect {
        let f = panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    fileprivate func click(_ item: NSMenuItem, level: Int, rowFrame: NSRect) {
        guard item.isEnabled else { return }
        if let sub = item.submenu {
            pendingOpen?.cancel()
            openSubmenu(item, sub, level: level, rowFrame: rowFrame)
            return
        }
        close()
        guard let action = item.action else { return }
        DispatchQueue.main.async { NSApp.sendAction(action, to: item.target, from: item) }
    }

    fileprivate var openSubmenuOwners: [NSMenuItem?] { openItems }

    // MARK: Kapanma

    private func installMonitors() {
        let ours: (NSEvent) -> Bool = { [weak self] e in
            guard let self, let w = e.window else { return false }
            return self.panels.contains { $0 === w }
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { if !ours(e) { self?.close() } }
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return e }
                if e.keyCode == 53 { self.close(); return nil }   // Esc
                return e
            }
        } as Any)
        // Yalnız gerçek kaydırmada kapan: trackpad'de iki parmakla sağ tık, hareketi sıfır olan bir
        // kaydırma olayı da gönderir ("başlayabilir" evresi); onu kaydırma sayarsak menü açılır açılmaz kapanır
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
            let moved = abs(e.scrollingDeltaX) > 0.5 || abs(e.scrollingDeltaY) > 0.5
            MainActor.assumeIsolated { if moved, !ours(e) { self?.close() } }
            return e
        } as Any)
    }
}

private final class FilesMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Panel anahtar pencere değilken gelen ilk tıklama da satıra ulaşsın: NSHostingView varsayılan olarak
/// ilk tıklamayı pencereyi öne almak için harcıyordu, menüde bir şeyi seçmek için iki kez tıklamak gerekiyordu.
final class FilesMenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Görünüm

private struct FilesMenuList: View {
    let items: [NSMenuItem]
    let level: Int
    @ObservedObject var controller: FilesContextMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                } else if let v = item.view {
                    HostedMenuView(view: v)
                        .frame(width: max(v.fittingSize.width, 200), height: max(v.fittingSize.height, 24), alignment: .leading)
                } else {
                    FilesMenuRow(item: item, level: level, controller: controller)
                }
            }
        }
        .padding(5)
        .frame(minWidth: 230, alignment: .leading)
        .fixedSize()
        .background(
            ZStack {
                GlassBlur(material: .menu)
                Color.primary.opacity(0.02)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// Gizli satırları ve art arda / baştaki / sondaki ayıraçları at
    private var visible: [NSMenuItem] {
        var out: [NSMenuItem] = []
        for i in items where !i.isHidden {
            if i.isSeparatorItem, out.last?.isSeparatorItem ?? true { continue }
            out.append(i)
        }
        if out.last?.isSeparatorItem == true { out.removeLast() }
        return out
    }
}

private struct FilesMenuRow: View {
    let item: NSMenuItem
    let level: Int
    @ObservedObject var controller: FilesContextMenu
    @State private var hover = false
    @State private var frame: NSRect = .zero

    var body: some View {
        let enabled = item.isEnabled
        let lit = (hover || isOpenParent) && enabled
        HStack(spacing: 8) {
            ZStack {
                if item.state == .on {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                } else if let img = icon {
                    Image(nsImage: img).renderingMode(img.isTemplate ? .template : .original)
                        .resizable().scaledToFit().frame(width: 15, height: 15)
                }
            }
            .frame(width: 18)
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 16)
            if let k = FilesMenuShortcuts.text(for: item) {
                Text(k).font(.system(size: 12)).foregroundStyle(lit ? Color.white.opacity(0.85) : Color.secondary)
            }
            if item.submenu != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(lit ? Color.white.opacity(0.9) : Color.secondary)
            }
        }
        .foregroundStyle(lit ? Color.white : Color.primary)
        .opacity(enabled ? 1 : 0.4)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame = $0 }
        })
        .onHover { h in
            hover = h
            if h { controller.hover(item, level: level, rowFrame: frame) }
        }
        .onTapGesture { controller.click(item, level: level, rowFrame: frame) }
        .help(item.toolTip ?? "")
    }

    private var isOpenParent: Bool {
        let o = controller.openSubmenuOwners
        return o.indices.contains(level) && o[level] === item
    }

    private var icon: NSImage? {
        if let i = item.image { return i }
        guard let s = FilesMenuShortcuts.symbol(for: item),
              let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) else { return nil }
        img.isTemplate = true
        return img
    }
}

/// NSMenuItem'ın kendi görünümü (renk etiketleri satırı)
private struct HostedMenuView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.removeFromSuperview()
        view.frame.origin = .zero
        box.addSubview(view)
        return box
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Simge ve kısayol eşleşmeleri

@MainActor enum FilesMenuShortcuts {
    private static func name(_ item: NSMenuItem) -> String { item.action.map(NSStringFromSelector) ?? "" }

    static func symbol(for item: NSMenuItem) -> String? {
        switch name(item) {
        case "openSelection:": return "arrow.up.forward.app"
        case "openSelectionInTab:": return "plus.rectangle.on.rectangle"
        case "toggleQuickLook:": return "eye"
        case "renameSelection:": return "pencil"
        case "duplicateSelection:": return "plus.square.on.square"
        case "copy:": return "doc.on.doc"
        case "copyPath:": return "link"
        case "paste:": return "doc.on.clipboard"
        case "moveHere:": return "arrow.down.doc"
        case "newFolder:": return "folder.badge.plus"
        case "pinSelection:": return "sidebar.left"
        case "openInTerminal:": return "terminal"
        case "revealInFinder:": return "macwindow"
        case "trashSelection:": return "trash"
        case "showList:": return "list.bullet"
        case "showGrid:": return "square.grid.2x2"
        case "showColumns:": return "rectangle.split.3x1"
        case "toggleHidden:": return "eye.slash"
        default: break
        }
        switch item.title {
        case L("Birlikte aç"): return "app.badge"
        case L("Paylaş"): return "square.and.arrow.up"
        case L("Sırala"): return "arrow.up.arrow.down"
        default: return nil
        }
    }

    static func text(for item: NSMenuItem) -> String? {
        if !item.keyEquivalent.isEmpty {
            let m = item.keyEquivalentModifierMask
            var s = ""
            if m.contains(.control) { s += "⌃" }
            if m.contains(.option) { s += "⌥" }
            if m.contains(.shift) { s += "⇧" }
            if m.contains(.command) { s += "⌘" }
            return s + item.keyEquivalent.uppercased()
        }
        switch name(item) {
        case "toggleQuickLook:": return "Space"
        case "renameSelection:": return "↩"
        case "duplicateSelection:": return "⌘D"
        case "copy:": return "⌘C"
        case "copyPath:": return "⌥⌘C"
        case "paste:": return "⌘V"
        case "moveHere:": return "⌥⌘V"
        case "newFolder:": return "⇧⌘N"
        case "trashSelection:": return "⌘⌫"
        case "revealInFinder:": return "⌥⌘R"
        case "showList:": return "⌘1"
        case "showGrid:": return "⌘2"
        case "showColumns:": return "⌘3"
        case "toggleHidden:": return "⇧⌘."
        default: return nil
        }
    }
}
