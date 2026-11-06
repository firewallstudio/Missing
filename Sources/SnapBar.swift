import Cocoa
import SwiftUI

// MARK: - Sürükleyerek ekran bölme (Windows 11'deki "Snap Layouts" çubuğu gibi)
//
// Bir pencereyi başlığından tutup sürüklemeye başlayınca ekranın üst ortasında küçük bir
// çıkıntı belirir. Pencereyi oraya götürünce çıkıntı açılır ve düzenler görünür; imleç hangi
// düzenin hangi bölmesinin üstündeyse ekranda o bölgenin önizlemesi çıkar. Bırakınca pencere
// oraya yerleşir. Çıkıntıdan uzaklaşınca kapanır, normal sürükleme devam eder.
//
// Sadece olayları dinler (NSEvent global monitör): fare olaylarını yutmaz, değiştirmez.
// Pencerenin gerçekten taşındığı pencere sunucusundaki konumundan anlaşılır; kenardan
// boyutlandırma, metin seçme, dosya sürükleme çubuğu açmaz.

enum SnapBarSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "snapBar.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "snapBar.enabled") }
    }
}

private typealias FnSnapGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
private let snapGetWindow: FnSnapGetWindow? = {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(p, to: FnSnapGetWindow.self)
}()

final class SnapBarModel: ObservableObject {
    @Published var expanded = false
    @Published var hoverLayout: Int? = nil
    @Published var hoverZone: Int? = nil
    /// Çentikli ekranda çentik yüksekliği (0: çentik yok, çubuk menü çubuğunun altında yüzer)
    @Published var notch: CGFloat = 0
    /// Açık çubukta her düzenin yeri (panelin sol üstüne göre)
    @Published var frames: [CGRect] = []
    /// Çentiğin altında duran, en çok kullanılan düzenler (büyük)
    @Published var featured: Set<Int> = []
}

/// Hangi düzen kaç kez kullanıldı: çentiğin altına en çok kullanılan ikisi gelir
enum SnapUsage {
    private static let key = "snapBar.usage"
    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func record(_ id: String) { counts[id, default: 0] += 1 }

    /// En çok kullanılan iki düzenin sırası (başlangıçta tam ekran ve ikiye bölme)
    static func top2(_ layouts: [TileLayout]) -> [Int] {
        let c = counts
        let defaults = ["full", "2v"]
        let ranked = layouts.indices.sorted { a, b in
            let ca = c[layouts[a].id] ?? 0, cb = c[layouts[b].id] ?? 0
            if ca != cb { return ca > cb }
            let da = defaults.firstIndex(of: layouts[a].id) ?? 99, db = defaults.firstIndex(of: layouts[b].id) ?? 99
            if da != db { return da < db }
            return a < b
        }
        return Array(ranked.prefix(2))
    }
}

/// Kenarsız panel menü çubuğunun / çentiğin üstüne de konabilsin
private final class TopPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class SnapBar {
    // Çubukta görünen düzenler (soldan sağa)
    static let layouts: [TileLayout] = ["full", "2v", "3v", "13", "23", "1+2", "4", "2h"]
        .compactMap { id in TileLayout.all.first { $0.id == id } }

    // Ölçüler (görünüm de isabet hesabı da bunları kullanır)
    nonisolated static let pad: CGFloat = 10
    nonisolated static let cellW: CGFloat = 64
    nonisolated static let cellH: CGFloat = 40
    nonisolated static let spacing: CGFloat = 10
    nonisolated static let notchLine: CGFloat = 4        // çentiğin altındaki kırmızı çizgi payı
    nonisolated static let notchRadius: CGFloat = 9      // çentiğin alt köşe yarıçapı (MacBook)
    nonisolated static let sidePad: CGFloat = 16         // çentikli adada kenar boşluğu
    static let tabSize = NSSize(width: 96, height: 14)
    static var rowSize: NSSize {
        let n = CGFloat(layouts.count)
        return NSSize(width: pad * 2 + n * cellW + (n - 1) * spacing, height: pad * 2 + cellH)
    }

    private enum State { case idle, watching, active, ignored }

    private let model = SnapBarModel()
    private var panel: NSPanel?
    private var preview: NSPanel?
    private var monitors: [Any] = []

    private var state = State.idle
    private var target: (wid: CGWindowID, pid: pid_t, bounds: CGRect)?
    private var screen: NSScreen?
    private var lastCheck = Date.distantPast
    private var previewShown = false
    private var previewGen = 0

    func start() {
        stop()
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        hide()
        state = .idle
    }

    // MARK: Olaylar

    private func mouseDown() {
        hide()
        target = nil
        guard SnapBarSettings.enabled, gSwitcher?.isActive != true,
              let t = Self.windowUnderMouse() else { state = .ignored; return }
        target = t
        state = .watching
    }

    private func mouseDragged() {
        switch state {
        case .watching:
            let now = Date()
            guard now.timeIntervalSince(lastCheck) > 0.03 else { return }
            lastCheck = now
            guard let t = target, let b = Self.bounds(of: t.wid) else { state = .ignored; return }
            let sameSize = abs(b.width - t.bounds.width) < 2 && abs(b.height - t.bounds.height) < 2
            let moved = hypot(b.minX - t.bounds.minX, b.minY - t.bounds.minY) > 6
            if !sameSize { state = .ignored }             // kenardan boyutlandırma
            else if moved { state = .active; showTab() }  // pencere taşınıyor
        case .active:
            track()
        case .idle, .ignored:
            break
        }
    }

    private func mouseUp() {
        defer { state = .idle; target = nil }
        guard state == .active else { return }
        let choice: (TileLayout, Int)? = {
            guard model.expanded, let l = model.hoverLayout, let z = model.hoverZone else { return nil }
            return (Self.layouts[l], z)
        }()
        let scr = screen
        hide()
        guard let c = choice, let scr, let t = target else { return }
        SnapUsage.record(c.0.id)
        let rect = WindowMover.frame(c.0.zones[c.1], on: scr)
        // Uygulama kendi sürüklemesini bitirsin, sonra yerleştir
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated {
                guard let w = Self.axWindow(pid: t.pid, wid: t.wid) else { return }
                WindowMover.move(window: w, to: rect)
            }
        }
    }

    // MARK: Çentik

    /// Ekranın çentiği (yoksa nil): genişlik ve yükseklik
    private static func notch(of s: NSScreen) -> NSSize? {
        guard #available(macOS 12.0, *), s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        let w = s.frame.width - l.width - r.width
        guard w > 40 else { return nil }
        return NSSize(width: w, height: s.safeAreaInsets.top)
    }

    // MARK: Yerleşim

    /// Açık çubuğun boyutu ve içindeki düzenlerin yerleri (sol üst başlangıçlı).
    /// Çentikte düzenler çentiğin iki yanına dizilir: ada çentikle birlikte kullanılır.
    nonisolated static let bigW: CGFloat = 92
    nonisolated static let bigH: CGFloat = 56

    /// Çentikte: en çok kullanılan iki düzen çentiğin hemen altında büyük, diğerleri iki yanda (2 satır)
    private static func layout(for s: NSScreen) -> (size: NSSize, frames: [CGRect], featured: Set<Int>) {
        layout(notch: notch(of: s))
    }

    #if SNAPSHOT
    static func snapshotLayout(notch: NSSize) -> (size: NSSize, frames: [CGRect], featured: Set<Int>) { layout(notch: notch) }
    #endif

    private static func layout(notch nt: NSSize?) -> (size: NSSize, frames: [CGRect], featured: Set<Int>) {
        let n = layouts.count
        if let nt {
            let top = SnapUsage.top2(layouts)
            let rest = (0..<n).filter { !top.contains($0) }
            let perSide: Int = (rest.count + 1) / 2
            let cols: Int = (perSide + 1) / 2
            let step: CGFloat = cellW + spacing
            let sideW: CGFloat = CGFloat(cols) * step - spacing
            let centerW: CGFloat = bigW * 2 + spacing
            let gap: CGFloat = Swift.max(nt.width, centerW) + spacing * 2 + 8
            let rightStart: CGFloat = sidePad + sideW + gap
            let w: CGFloat = sidePad * 2 + sideW * 2 + gap
            let centerTop: CGFloat = nt.height + 6
            let h: CGFloat = centerTop + bigH + 12
            let rowsH: CGFloat = cellH * 2 + spacing
            let rowsTop: CGFloat = (h - rowsH) / 2 + 2
            var frames = [CGRect](repeating: .zero, count: n)
            for (k, i) in rest.enumerated() {
                let side: Int = k < perSide ? 0 : 1
                let j: Int = side == 0 ? k : k - perSide
                let x0: CGFloat = side == 0 ? sidePad : rightStart
                let x: CGFloat = x0 + CGFloat(j % cols) * step
                let y: CGFloat = rowsTop + CGFloat(j / cols) * (cellH + spacing)
                frames[i] = CGRect(x: x, y: y, width: cellW, height: cellH)
            }
            let cx: CGFloat = sidePad + sideW + (gap - centerW) / 2
            for (k, i) in top.enumerated() {
                frames[i] = CGRect(x: cx + CGFloat(k) * (bigW + spacing), y: centerTop, width: bigW, height: bigH)
            }
            return (NSSize(width: w, height: h), frames, Set(top))
        }
        let w = pad * 2 + CGFloat(n) * cellW + CGFloat(n - 1) * spacing
        let frames = (0..<n).map { CGRect(x: pad + CGFloat($0) * (cellW + spacing), y: pad, width: cellW, height: cellH) }
        return (NSSize(width: w, height: pad * 2 + cellH), frames, [])
    }

    // MARK: Çubuk

    private func showTab() {
        let p = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        prepare(for: screen)
        let tab = tabRect(on: screen)
        if model.notch > 0 {
            // Çentik: çentiğin altında ince kırmızı çizgi belirir
            panel.setFrame(tab, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(tab.offsetBy(dx: 0, dy: 10), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
                panel.animator().setFrame(tab, display: true)
            }
        }
    }

    private func prepare(for s: NSScreen) {
        model.expanded = false
        model.hoverLayout = nil
        model.hoverZone = nil
        model.notch = Self.notch(of: s)?.height ?? 0
        let l = Self.layout(for: s)
        model.frames = l.frames
        model.featured = l.featured
        panel?.hasShadow = model.notch == 0
    }

    private func setExpanded(_ on: Bool) {
        guard let panel, let screen, model.expanded != on else { return }
        model.expanded = on
        panel.hasShadow = model.notch == 0 || on
        if !on { model.hoverLayout = nil; model.hoverZone = nil; updatePreview() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = model.notch > 0 ? 0.24 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(on ? barRect(on: screen) : tabRect(on: screen), display: true)
        }
    }

    private func track() {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }), s != screen {
            // Başka monitöre geçti: çubuk oraya taşınsın
            screen = s
            prepare(for: s)
            updatePreview()
            panel?.setFrame(tabRect(on: s), display: true)
            return
        }
        guard let screen else { return }

        if !model.expanded {
            let tab = tabRect(on: screen)
            // Çıkıntının / çentiğin çevresi + ekranın üst kenarı da sayılır
            let zone = NSRect(x: tab.minX - 60, y: tab.minY - 30, width: tab.width + 120, height: screen.frame.maxY - tab.minY + 30)
            if zone.contains(p) { setExpanded(true) }
            return
        }

        let bar = barRect(on: screen)
        let keep = NSRect(x: bar.minX - 30, y: bar.minY - 50, width: bar.width + 60, height: screen.frame.maxY - bar.minY + 50)
        guard keep.contains(p) else { setExpanded(false); return }

        // İsabet: imleç hangi düzenin hangi bölmesinde? Düzenin çevresindeki boşlukta en yakın bölme seçili kalır
        let local = CGPoint(x: p.x - bar.minX, y: bar.maxY - p.y)
        var hl: Int?, hz: Int?
        let dy: CGFloat = model.notch > 0 ? -Self.spacing / 2 : -Self.pad   // çentikte 2 satır: satırlar çakışmasın
        if let i = model.frames.firstIndex(where: { $0.insetBy(dx: -Self.spacing / 2, dy: dy).contains(local) }) {
            hl = i
            hz = Self.zone(in: Self.layouts[i], frame: model.frames[i], at: local)
        }
        if hl != model.hoverLayout || hz != model.hoverZone {
            model.hoverLayout = hl
            model.hoverZone = hz
            updatePreview()
        }
    }

    /// Düzen kutusundaki noktanın bölmesi; bölmeler arası çizgide en yakın bölme
    private static func zone(in layout: TileLayout, frame f: CGRect, at p: CGPoint) -> Int? {
        let ux: CGFloat = Swift.min(Swift.max((p.x - f.minX) / f.width, 0), 0.999)
        let uy: CGFloat = Swift.min(Swift.max((p.y - f.minY) / f.height, 0), 0.999)
        let u = CGPoint(x: ux, y: uy)
        let zones = layout.zones
        if let hit = zones.firstIndex(where: { $0.contains(u) }) { return hit }
        var best: Int?
        var bestD: CGFloat = .greatestFiniteMagnitude
        for (i, z) in zones.enumerated() {
            let d: CGFloat = hypot(z.midX - u.x, z.midY - u.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func tabRect(on s: NSScreen) -> NSRect {
        if let n = Self.notch(of: s) {
            // Çentiğin kendisi + altında ince çizgi payı
            let w = n.width + 4, h = n.height + Self.notchLine
            return NSRect(x: (s.frame.midX - w / 2).rounded(), y: s.frame.maxY - h, width: w, height: h)
        }
        let vf = s.visibleFrame
        return NSRect(x: (vf.midX - Self.tabSize.width / 2).rounded(), y: vf.maxY - Self.tabSize.height - 4,
                      width: Self.tabSize.width, height: Self.tabSize.height)
    }

    private func barRect(on s: NSScreen) -> NSRect {
        let size = Self.layout(for: s).size
        if Self.notch(of: s) != nil {
            return NSRect(x: (s.frame.midX - size.width / 2).rounded(), y: s.frame.maxY - size.height,
                          width: size.width, height: size.height)
        }
        let vf = s.visibleFrame
        return NSRect(x: (vf.midX - size.width / 2).rounded(), y: vf.maxY - size.height - 6, width: size.width, height: size.height)
    }

    // MARK: Önizleme (pencerenin gideceği yer)

    private func updatePreview() {
        previewGen += 1
        let gen = previewGen
        guard let screen, let l = model.hoverLayout, let z = model.hoverZone else {
            guard previewShown, let preview else { return }
            previewShown = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                preview.animator().alphaValue = 0
            }, completionHandler: {
                // Bu arada yeni bir bölme seçildiyse gizleme (önizleme kaybolmasın)
                MainActor.assumeIsolated { if self.previewGen == gen && !self.previewShown { preview.orderOut(nil) } }
            })
            return
        }
        let rect = WindowMover.frame(Self.layouts[l].zones[z], on: screen)
        let pv = preview ?? makePreview()
        preview = pv
        if !previewShown || !pv.isVisible {
            pv.setFrame(rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.03), display: true)
            pv.alphaValue = 0
            pv.orderFrontRegardless()
            panel?.orderFrontRegardless()     // çubuk önizlemenin üstünde kalsın
        }
        previewShown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            pv.animator().alphaValue = 1
            pv.animator().setFrame(rect, display: true)
        }
    }

    private func hide() {
        previewGen += 1
        previewShown = false
        panel?.orderOut(nil)
        preview?.orderOut(nil)
        model.expanded = false
        model.hoverLayout = nil
        model.hoverZone = nil
    }

    // MARK: Pencereler

    private static func basePanel(level: NSWindow.Level) -> NSPanel {
        let p = TopPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 20),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = level
        p.ignoresMouseEvents = true          // sürüklemeye karışmasın
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.sharingType = .none
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        return p
    }

    private func makePanel() -> NSPanel {
        let p = Self.basePanel(level: .popUpMenu)
        p.hasShadow = true
        let host = NSHostingView(rootView: SnapBarView(model: model, layouts: Self.layouts))
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    private func makePreview() -> NSPanel {
        let p = Self.basePanel(level: .floating)
        p.hasShadow = false
        let host = NSHostingView(rootView: SnapPreviewView())
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    /// İmlecin altındaki en üstteki normal pencere (pencere sunucusundan)
    private static func windowUnderMouse() -> (wid: CGWindowID, pid: pid_t, bounds: CGRect)? {
        let m = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: m.x, y: primaryH - m.y)        // sol üst başlangıçlı
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.contains(p),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            // Missing'in kendi pencereleri (kayıt göstergesi, kayıt alanı çerçevesi, bildirimler)
            // ve görünmez katmanlar sayılmaz: altındaki pencereye bakılır
            if pid == getpid() { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            // Üstteki tıklama geçiren katmanlar (kayıt göstergeleri, ekran kaydı araçları…) atlanır.
            // Menü / Dock'a tıklanırsa alttaki pencere seçilse de o pencere taşınmadığı için çubuk açılmaz.
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (wid, pid, b)
        }
        return nil
    }

    private static func bounds(of wid: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]],
              let bd = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bd)
    }

    /// Pencere sunucusundaki pencerenin erişilebilirlik karşılığı
    private static func axWindow(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let wins: [AXUIElement] = AX.attr(app, kAXWindowsAttribute) ?? []
        if let f = snapGetWindow {
            for w in wins {
                var id: CGWindowID = 0
                if f(w, &id) == 0, id == wid { return w }
            }
        }
        // Yedek: konumu/boyutu eşleşen pencere, o da yoksa odaktaki pencere
        if let b = bounds(of: wid) {
            for w in wins {
                guard let pv: AXValue = AX.attr(w, kAXPositionAttribute), let sv: AXValue = AX.attr(w, kAXSizeAttribute) else { continue }
                var pt = CGPoint.zero, sz = CGSize.zero
                AXValueGetValue(pv, .cgPoint, &pt); AXValueGetValue(sv, .cgSize, &sz)
                if abs(pt.x - b.minX) < 3, abs(pt.y - b.minY) < 3, abs(sz.width - b.width) < 3 { return w }
            }
        }
        return AX.attr(app, kAXFocusedWindowAttribute)
    }
}

// MARK: - Görünümler

struct SnapBarView: View {
    @ObservedObject var model: SnapBarModel
    let layouts: [TileLayout]

    var body: some View {
        if model.notch > 0 { notchBody } else { floatingBody }
    }

    /// Düzenler, hesaplanan yerlerinde
    private var cells: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layouts.indices, id: \.self) { i in
                if model.frames.indices.contains(i) {
                    let f = model.frames[i]
                    SnapCell(layout: layouts[i], active: model.hoverLayout == i ? model.hoverZone : nil)
                        .frame(width: f.width, height: f.height)
                        .padding(model.featured.contains(i) ? 4 : 0)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(model.featured.contains(i) ? 0.07 : 0)))
                        .padding(model.featured.contains(i) ? -4 : 0)
                        .offset(x: f.minX, y: f.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Çentiksiz ekran: menü çubuğunun altında koyu cam çıkıntı → çubuk
    private var floatingBody: some View {
        ZStack {
            if model.expanded {
                cells.transition(.opacity)
            } else {
                Capsule().fill(.white.opacity(0.7)).frame(width: 32, height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .darkGlass(radius: model.expanded ? 16 : 7)
        .animation(.easeOut(duration: 0.15), value: model.expanded)
        .environment(\.colorScheme, .dark)
    }

    /// Çentikli ekran: kapalıyken çentiğin altında ince koyu kırmızı çizgi; yaklaşınca çentik
    /// iki yana ve aşağı büyüyen siyah bir adaya dönüşür, düzenler çentiğin iki yanında durur
    private var notchBody: some View {
        ZStack(alignment: .top) {
            if model.expanded {
                NotchShape(radius: 24).fill(Color.black)
                    .overlay(NotchShape(radius: 24).stroke(Brand.red.opacity(0.35), lineWidth: 1))
                cells.transition(.opacity)
            } else {
                NotchShape(radius: SnapBar.notchRadius).fill(Color.black)
                    .padding(.horizontal, 2)
                    .padding(.bottom, SnapBar.notchLine - 1)
                NotchUnderline(radius: SnapBar.notchRadius)
                    .padding(.horizontal, 1)
                    .padding(.bottom, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.expanded)
        .environment(\.colorScheme, .dark)
    }
}

/// Üstü düz, alt köşeleri yuvarlak (çentiğin devamı gibi)
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Çentiğin sadece alt kenarı (yuvarlak köşeleriyle): ince koyu kırmızı, hafifçe nefes alan çizgi
struct NotchUnderline: View {
    let radius: CGFloat
    private static let red = Brand.red
    private static let glow = Brand.red

    private static func pulse(_ d: Date) -> Double {
        let t: Double = d.timeIntervalSinceReferenceDate
        return 0.5 + 0.5 * sin(t * 4)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let v: Double = Self.pulse(ctx.date)
            NotchBottomEdge(radius: radius)
                .stroke(Self.red.opacity(0.65 + 0.35 * v), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: Self.glow.opacity(0.5 * v), radius: 2)
        }
    }
}

/// Alt köşelerin kavsiyle birlikte alt kenar çizgisi
struct NotchBottomEdge: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// Çubuktaki tek düzen: bölmeleri; imlecin üstünde olduğu bölme vurgulanır
struct SnapCell: View {
    let layout: TileLayout
    let active: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(layout.zones.indices, id: \.self) { i in
                    let z = layout.zones[i]
                    let g: CGFloat = 3
                    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                    shape
                        .fill(active == i ? Brand.red : Color.white.opacity(0.14))
                        .overlay(shape.strokeBorder(Color.white.opacity(active == i ? 0 : 0.18), lineWidth: 0.75))
                        .frame(width: max(4, z.width * geo.size.width - g), height: max(4, z.height * geo.size.height - g))
                        .position(x: z.midX * geo.size.width, y: z.midY * geo.size.height)
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: active)
    }
}

/// Pencerenin bırakılınca gideceği yer: ekranda koyu yarı saydam cam
struct SnapPreviewView: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(Color.black.opacity(0.22))
            .background(GlassBlur(material: .hudWindow, appearance: .darkAqua).clipShape(shape).opacity(0.7))
            .overlay(shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5))
            .environment(\.colorScheme, .dark)
    }
}
