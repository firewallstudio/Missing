import AppKit
import Carbon
import SwiftUI

// MARK: - Dosyalar sekme değiştirici (⌘")
//
// ⌘ basılıyken " (ABD klavyesinde `) her basışta bir sonraki sekmeyi seçer, ⇧ ile geri gider.
// ⌘ bırakılınca seçilen sekmeye geçilir; Esc vazgeçer. Görünüm ⌘Tab paneliyle aynı:
// koyu cam, kartlar, seçili kartta kırmızı kenar ve parıltı.

@MainActor final class FilesTabSwitcher {
    static let shared = FilesTabSwitcher()

    /// ⌘" tuşu mu? Türkçe Q (ISO) klavyede " 1'in solundaki tuştur (kod 10); ISO'da 50 kodu
    /// ⌘< (ekranı böl) olduğundan 50 yalnızca ANSI (ABD) klavyede, orada ` tuşu olarak sayılır.
    static func isSwitchKey(_ code: Int64, chars: String? = nil) -> Bool {
        if let chars, ["\"", "é", "`", "~"].contains(chars) { return true }
        if code == 10 { return true }
        if code == 50 { return KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardANSI }
        return false
    }

    /// Önde bir Dosyalar penceresi var mı (genel kısayol dinleyicisi için)
    var filesInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && FilesManager.shared.windows.contains { $0.window?.isKeyWindow == true }
    }

    /// Genel olay dinleyicisinden (⌘Tab'ın tap'i) gelen ⌘" basışı; true: tuş yutuldu
    func press(back: Bool) -> Bool {
        if isVisible { step(back ? -1 : 1); return true }
        guard let c = FilesManager.shared.windows.first(where: { $0.window?.isKeyWindow == true }),
              c.window?.attachedSheet == nil else { return false }
        guard c.model.tabs.count > 1 else { NSSound.beep(); return true }
        show(for: c, back: back)
        return true
    }

    private var panel: NSPanel?
    private let state = FilesTabSwitcherState()
    private weak var controller: FilesWindowController?
    private var monitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// Uygulama içindeki tuşları dinle (Files penceresi önde iken)
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        if e.type == .flagsChanged {
            if isVisible, !e.modifierFlags.contains(.command) { commit() }
            return false
        }
        if isVisible {
            switch e.keyCode {
            case 53: cancel(); return true                                   // Esc
            case 36, 76: commit(); return true                               // Return
            case 123: step(-1); return true                                  // ←
            case 124: step(1); return true                                   // →
            default: break
            }
        }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == .command || mods == [.command, .shift],
              Self.isSwitchKey(Int64(e.keyCode), chars: e.charactersIgnoringModifiers) else { return false }
        return press(back: mods.contains(.shift))
    }

    private func show(for c: FilesWindowController, back: Bool) {
        controller = c
        let n = c.model.tabs.count
        state.tabs = c.model.tabs
        state.selected = (c.model.currentIndex + (back ? -1 : 1) + n) % n
        state.palette = FilesPalette.current(for: c.window?.effectiveAppearance)
        state.onPick = { [weak self] i in
            self?.state.selected = i
            self?.commit()
        }
        let p = panel ?? makePanel()
        panel = p
        let host = p.contentView as! NSHostingView<FilesTabSwitcherView>
        host.rootView = FilesTabSwitcherView(state: state)
        let size = host.fittingSize
        // Pencerenin ortasına; ekrana sığmıyorsa ekranın ortasına
        let wf = c.window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let vf = c.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? wf
        var origin = NSPoint(x: wf.midX - size.width / 2, y: wf.midY - size.height / 2)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 1
        p.orderFront(nil)
    }

    private func step(_ d: Int) {
        let n = state.tabs.count
        guard n > 0 else { return }
        state.selected = (state.selected + d + n) % n
    }

    private func commit() {
        guard isVisible else { return }
        if let c = controller, state.tabs.indices.contains(state.selected) {
            let id = state.tabs[state.selected].id
            if c.model.tabs.contains(where: { $0.id == id }) { c.model.currentID = id }
            c.browser.focus()
        }
        hide()
    }

    private func cancel() { hide() }

    private func hide() {
        panel?.orderOut(nil)
        state.tabs = []
        controller = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: FilesTabSwitcherView(state: state))
        return p
    }
}

@MainActor final class FilesTabSwitcherState: ObservableObject {
    @Published var tabs: [FilesTab] = []
    @Published var selected = 0
    var palette = FilesPalette(theme: .missing, dark: true)
    var onPick: (Int) -> Void = { _ in }
}

struct FilesTabSwitcherView: View {
    @ObservedObject var state: FilesTabSwitcherState

    private static let cardW: CGFloat = 220, cardH: CGFloat = 178, gap: CGFloat = 12, pad: CGFloat = 20
    /// Bir satıra en çok kaç kart
    private var perRow: Int {
        let screenW = NSScreen.main?.visibleFrame.width ?? 1400
        return max(1, min(state.tabs.count, Int((screenW * 0.86 - Self.pad * 2 + Self.gap) / (Self.cardW + Self.gap))))
    }

    var body: some View {
        let rows = stride(from: 0, to: state.tabs.count, by: perRow).map { Array($0..<min($0 + perRow, state.tabs.count)) }
        VStack(spacing: Self.gap) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: Self.gap) {
                    ForEach(row, id: \.self) { i in
                        FilesTabCard(tab: state.tabs[i], selected: i == state.selected)
                            .frame(width: Self.cardW, height: Self.cardH)
                            .onTapGesture { state.onPick(i) }
                    }
                }
            }
        }
        .padding(Self.pad)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow, appearance: .darkAqua)
                Color.black.opacity(0.30)
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// ⌘Tab kartı gibi: üstte simge + ad, altta klasörün içinden küçük bir önizleme
private struct FilesTabCard: View {
    @ObservedObject var tab: FilesTab
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: FileIcons.shared.icon(tab.url))
                    .resizable().interpolation(.high)
                    .frame(width: 24, height: 24)
                Text(tab.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            preview
        }
        .padding(10)
        .background(shape.fill(.white.opacity(selected ? 0.22 : 0.06)))
        .overlay(shape.strokeBorder(selected ? Brand.red : .white.opacity(0.10), lineWidth: selected ? 2.5 : 1))
        .shadow(color: selected ? Brand.red.opacity(0.75) : .clear, radius: 14)
        .contentShape(shape)
    }

    /// İlk birkaç öğenin simgesi; altında konum ve öğe sayısı
    private var preview: some View {
        let shown = Array(tab.items.prefix(8))
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07))
                if shown.isEmpty {
                    Text(tab.loaded ? L("Klasör boş") : "…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 8), count: 4), spacing: 6) {
                        ForEach(shown, id: \.url) { item in
                            Image(nsImage: FileIcons.shared.icon(item.url))
                                .resizable().interpolation(.high)
                                .frame(width: 34, height: 34)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 4) {
                Text(parent).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text(L("%d öğe", tab.totalCount)).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var parent: String {
        let p = tab.url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
