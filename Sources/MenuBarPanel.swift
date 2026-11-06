import Cocoa
import SwiftUI

// MARK: - Menü çubuğu paneli
//
// Missing simgesine tıklayınca açılan cam panel (Denetim Merkezi gibi): üstte ses çıkışı,
// ortada büyük hızlı eylem kutucukları, altta monitör kaydırıcıları ve ayarlar.
// Düz bir menü listesi yerine; dışarı tıklayınca ya da Esc ile kapanır.

/// Panelin AppDelegate'ten aldığı eylemler ve anlık durumlar
final class MenuBarActions: ObservableObject {
    var tile: () -> Void = {}
    var capture: (CaptureAction) -> Void = { _ in }
    var stopRecording: () -> Void = {}
    var blackout: () -> Void = {}
    var openSettings: (SettingsPage) -> Void = { _ in }
    var checkUpdates: () -> Void = {}
    var installUpdate: () -> Void = {}
    var quit: () -> Void = {}
    var isRecording: () -> Bool = { false }

    func refresh() { objectWillChange.send() }
}

private final class MenuPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class MenuBarPanelController: NSObject {
    let actions = MenuBarActions()
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    var onVisibilityChanged: (Bool) -> Void = { _ in }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(below button: NSStatusBarButton?) {
        if isVisible { close() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton?) {
        DeviceStore.shared.refresh()
        if MonitorSettings.showInMenu { Monitors.shared.refresh() }
        actions.refresh()
        let p = panel ?? make()
        panel = p
        let size = p.contentView?.fittingSize ?? NSSize(width: 340, height: 420)
        var origin = NSPoint(x: 0, y: 0)
        if let b = button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 6)
            if let screen = w.screen {
                let vf = screen.visibleFrame
                origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            }
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
        installMonitors()
        onVisibilityChanged(true)
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        removeMonitors()
        p.orderOut(nil)
        onVisibilityChanged(false)
    }

    /// Bir eylemden önce paneli kapat, eylemi bir sonraki turda çalıştır (panel ekran görüntüsüne girmesin)
    func run(after delay: Double = 0.12, _ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
    }

    private func make() -> NSPanel {
        let p = MenuPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.appearance = NSAppearance(named: .darkAqua)
        let view = MenuBarView(actions: actions, store: DeviceStore.shared, updater: Updater.shared,
                               monitors: Monitors.shared, controller: self)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 420)
        p.contentView = host
        return p
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isKeyWindow == true else { return e }
            if e.keyCode == 53 { self.close(); return nil }   // Esc
            return e
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        keyMonitor = nil
    }
}

// MARK: - Görünüm

struct MenuBarView: View {
    @ObservedObject var actions: MenuBarActions
    @ObservedObject var store: DeviceStore
    @ObservedObject var updater: Updater
    @ObservedObject var monitors: Monitors
    let controller: MenuBarPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if updater.updateAvailable, let v = updater.latest?.version { updateBanner(v) }
            if needsAccess { accessBanner }
            audioSection
            quickGrid
            if MonitorSettings.showInMenu, !monitors.displays.isEmpty { monitorSection }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow)
                Color.black.opacity(0.25)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var needsAccess: Bool {
        #if SNAPSHOT
        return false
        #else
        return Onboarding.needsAccessibility && !AXIsProcessTrusted()
        #endif
    }

    // MARK: Üst

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: Brand.leaf).resizable().frame(width: 20, height: 20)
            Text("Missing").font(.system(size: 14, weight: .bold))
            Spacer()
            iconButton("gearshape.fill", L("Ayarlar…")) { controller.run { actions.openSettings(.general) } }
            iconButton("power", L("Missing'den Çık")) { actions.quit() }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func updateBanner(_ v: String) -> some View {
        Button { controller.run { actions.installUpdate() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 16))
                Text(L("Güncelleme var: %@ · Yükle", v)).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.red))
        }
        .buttonStyle(.plain)
    }

    private var accessBanner: some View {
        Button { controller.run { SettingsModel.open("Privacy_Accessibility") } } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L("Erişilebilirlik izni ver")).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Ses

    private var audioSection: some View {
        let rows = store.rows.filter(\.isConnected)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("Ses çıkışı"))
            VStack(spacing: 2) {
                ForEach(rows) { row in deviceRow(row) }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
            if store.passthroughActive {
                Text(L("eqMac üzerinden yönlendiriliyor")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func deviceRow(_ row: DeviceRow) -> some View {
        Button { store.switchTo(uid: row.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(row.isCurrent ? Brand.red : Color.white.opacity(0.12)))
                Text(row.name).font(.system(size: 12.5, weight: row.isCurrent ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if row.isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    // MARK: Hızlı eylemler

    private var quickGrid: some View {
        let recording = actions.isRecording()
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("Hızlı"))
            LazyVGrid(columns: cols, spacing: 8) {
                if TileSettings.enabled {
                    tile("rectangle.split.3x1", L("Ekranı böl"), "⌘<") { controller.run { actions.tile() } }
                }
                if CaptureSettings.enabled {
                    tile("rectangle.dashed", L("Ekran alıntısı"), "⌘⇧4") { controller.run(after: 0.25) { actions.capture(.area) } }
                    if recording {
                        tile("stop.circle.fill", L("Kaydı durdur"), "⌘⇧5", active: true) { controller.run { actions.stopRecording() } }
                    } else {
                        tile("record.circle", L("Ekranı kaydet"), "⌘⇧5") { controller.run(after: 0.25) { actions.capture(.recordScreen) } }
                    }
                    tile("scroll", L("Kaydırmalı"), "⌘⇧6") { controller.run(after: 0.25) { actions.capture(.scroll) } }
                }
                if MonitorSettings.blackoutKey {
                    tile(monitors.isBlackedOut ? "sun.max.fill" : "moon.fill",
                         monitors.isBlackedOut ? L("Ekranları aç") : L("Karart"), "⌘⇧<", active: monitors.isBlackedOut) {
                        controller.run { actions.blackout() }
                    }
                }
                tile("keyboard", L("Kısayollar"), nil) { controller.run { actions.openSettings(.shortcuts) } }
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ keys: String?, active: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(active ? Color.white : Brand.red))
                    .foregroundStyle(active ? Brand.red : .white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let keys {
                        Text(keys).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(active ? Brand.red.opacity(0.35) : Color.white.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(MenuRowStyle(radius: 14))
    }

    // MARK: Monitörler

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("Harici monitörler"))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(monitors.displays) { d in monitorRow(d) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
        }
    }

    private func monitorRow(_ d: Monitors.Display) -> some View {
        let id = d.id
        let bright = Binding<Double>(get: { monitors.displays.first { $0.id == id }?.brightness ?? 0 },
                                     set: { monitors.setBrightness($0, for: id) })
        return VStack(alignment: .leading, spacing: 4) {
            Text(d.ddc ? d.name : L("%@ · desteklemiyor", d.name)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Slider(value: bright, in: 0...100).tint(Brand.red)
            }
            .disabled(!d.ddc)
        }
    }

    // MARK: Alt

    private var footer: some View {
        HStack {
            Button { controller.run { actions.checkUpdates() } } label: {
                Label(L("Güncellemeleri denetle…"), systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(store.current?.name ?? "").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased(with: Locale.current))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.leading, 4)
    }
}

/// Üstüne gelince hafifçe aydınlanan satır
struct MenuRowStyle: ButtonStyle {
    var radius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration, radius: radius)
    }

    private struct MenuRowBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hover = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : (hover ? 0.07 : 0))))
                .onHover { hover = $0 }
        }
    }
}
