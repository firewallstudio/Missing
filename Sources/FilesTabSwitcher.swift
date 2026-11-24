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
        guard FilesSettings.tabSwitcherEnabled else { return false }
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
        // Kartlar pencerenin içine sığsın: satırdaki kart sayısı pencere genişliğinden
        let wf = c.window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        state.list = FilesSettings.tabSwitcherList
        state.contents = FilesSettings.tabSwitcherContents
        state.favorites = FilesSettings.tabSwitcherFavorites ? Array(FilesPlaces.shared.shownFavorites.prefix(FilesTabSwitcherView.maxFavorites)) : []
        state.onFavorite = { [weak self, weak c] url in
            guard let self, let c else { return }
            self.hide()
            c.model.addTab(url)
            c.browser.focus()
        }
        let favW = state.favorites.isEmpty ? 0 : FilesTabSwitcherView.favW + FilesTabSwitcherView.pad
        state.perRow = FilesTabSwitcherView.perRow(count: n, width: wf.width - 40 - favW)
        var size = state.list ? FilesTabSwitcherView.listSize(count: n) : FilesTabSwitcherView.size(count: n, perRow: state.perRow)
        state.mainSize = size
        if !state.favorites.isEmpty {
            size.width += favW
            size.height = max(size.height, FilesTabSwitcherView.favoritesHeight(state.favorites.count))
        }
        let host = p.contentView as! NSHostingView<FilesTabSwitcherView>
        state.size = size
        host.rootView = FilesTabSwitcherView(state: state)
        host.frame = NSRect(origin: .zero, size: size)
        // Her zaman Dosyalar penceresinin tam ortasında; yalnızca ekrandan taşarsa içeri itilir
        var origin = NSPoint(x: (wf.midX - size.width / 2).rounded(), y: (wf.midY - size.height / 2).rounded())
        if let sf = c.window?.screen?.frame {
            origin.x = min(max(origin.x, sf.minX), sf.maxX - size.width)
            origin.y = min(max(origin.y, sf.minY), sf.maxY - size.height)
        }
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
        let host = NSHostingView(rootView: FilesTabSwitcherView(state: state))
        // Panelin boyunu biz veriyoruz; SwiftUI pencereyi kendi başına büyütüp kaydırmasın
        host.sizingOptions = []
        p.contentView = host
        return p
    }
}

@MainActor final class FilesTabSwitcherState: ObservableObject {
    @Published var tabs: [FilesTab] = []
    @Published var selected = 0
    @Published var perRow = 1
    @Published var list = false
    @Published var contents = true
    @Published var size: CGSize = .zero
    @Published var mainSize: CGSize = .zero
    /// Sağdaki ince sütun: tıklanan sık kullanılan bu pencerede yeni sekmede açılır
    @Published var favorites: [SidebarPlace] = []
    var onFavorite: (URL) -> Void = { _ in }
    var palette = FilesPalette(theme: .missing, dark: true)
    var onPick: (Int) -> Void = { _ in }
}

struct FilesTabSwitcherView: View {
    @ObservedObject var state: FilesTabSwitcherState

    static let cardW: CGFloat = 220, cardH: CGFloat = 178, gap: CGFloat = 12, pad: CGFloat = 20
    private var perRow: Int { max(1, state.perRow) }

    /// Verilen genişliğe sığan kart sayısı (en az 1)
    static func perRow(count: Int, width: CGFloat) -> Int {
        max(1, min(count, Int((width - pad * 2 + gap) / (cardW + gap))))
    }

    /// Panelin tam boyu: kartlar + aralıklar + kenar boşluğu
    static func size(count: Int, perRow: Int) -> CGSize {
        let cols = CGFloat(min(count, perRow)), rows = CGFloat((count + perRow - 1) / perRow)
        return CGSize(width: cols * cardW + (cols - 1) * gap + pad * 2,
                      height: rows * cardH + (rows - 1) * gap + pad * 2)
    }

    // Sık kullanılanlar sütunu: dar ve sade
    static let favW: CGFloat = 164, favRowH: CGFloat = 24, maxFavorites = 10

    static func favoritesHeight(_ n: Int) -> CGFloat {
        20 + CGFloat(n) * (favRowH + 2) + 12 + pad * 2
    }

    // Liste görünümü: ⌘Tab'ın listesi gibi alt alta satırlar
    static let listW: CGFloat = 480, rowH: CGFloat = 58, rowGap: CGFloat = 4, listPad: CGFloat = 14

    static func listSize(count: Int) -> CGSize {
        let n = CGFloat(count)
        return CGSize(width: listW, height: n * rowH + (n - 1) * rowGap + listPad * 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if state.list { listBody } else { cardsBody }
            }
            .frame(width: state.mainSize.width, height: state.mainSize.height)
            if !state.favorites.isEmpty {
                FilesTabFavorites(places: state.favorites, open: state.onFavorite)
                    .frame(width: Self.favW)
                    .padding(.vertical, state.list ? Self.listPad : Self.pad)
                    .padding(.trailing, Self.pad)
            }
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow, appearance: .darkAqua)
                Color.black.opacity(0.30)
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: state.list ? 22 : 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: state.list ? 22 : 26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(width: state.size.width, height: state.size.height)
    }

    private var listBody: some View {
        VStack(spacing: Self.rowGap) {
            ForEach(state.tabs.indices, id: \.self) { i in
                FilesTabRow(tab: state.tabs[i], selected: i == state.selected)
                    .frame(width: Self.listW - Self.listPad * 2, height: Self.rowH)
                    .onTapGesture { state.onPick(i) }
            }
        }
        .padding(Self.listPad)
    }

    private var cardsBody: some View {
        let rows = stride(from: 0, to: state.tabs.count, by: perRow).map { Array($0..<min($0 + perRow, state.tabs.count)) }
        return VStack(spacing: Self.gap) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: Self.gap) {
                    ForEach(row, id: \.self) { i in
                        FilesTabCard(tab: state.tabs[i], selected: i == state.selected, contents: state.contents)
                            .frame(width: Self.cardW, height: Self.cardH)
                            .onTapGesture { state.onPick(i) }
                    }
                }
            }
        }
        .padding(Self.pad)
    }

}

/// ⌘Tab kartı gibi: üstte simge + ad, altta klasörün içinden küçük bir önizleme
private struct FilesTabCard: View {
    @ObservedObject var tab: FilesTab
    let selected: Bool
    var contents = true

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
            if contents {
                preview
            } else {
                // İçerik kapalı: büyük klasör simgesi ve konum
                VStack(spacing: 8) {
                    Image(nsImage: FileIcons.shared.icon(tab.url))
                        .resizable().interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(parent).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
            }
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

    private var parent: String { Self.parent(of: tab.url) }

    static func parent(of url: URL) -> String {
        let p = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// Liste satırı: ⌘Tab'ın liste görünümündeki gibi simge, ad, konum ve öğe sayısı
private struct FilesTabRow: View {
    @ObservedObject var tab: FilesTab
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.shared.icon(tab.url))
                .resizable().interpolation(.high)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(FilesTabCard.parent(of: tab.url)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(L("%d öğe", tab.totalCount))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.white.opacity(selected ? 0.22 : 0.06)))
        .overlay(shape.strokeBorder(selected ? Brand.red : .white.opacity(0.10), lineWidth: selected ? 2.5 : 1))
        .shadow(color: selected ? Brand.red.opacity(0.75) : .clear, radius: 14)
        .contentShape(shape)
    }
}

/// Panelin sağında sık kullanılanlar: tıklayınca bu pencerede yeni sekmede açılır
private struct FilesTabFavorites: View {
    let places: [SidebarPlace]
    let open: (URL) -> Void
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Sık kullanılanlar"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 8)
                .frame(height: 20, alignment: .leading)
            ForEach(places) { p in
                let on = hover == p.id
                HStack(spacing: 7) {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(on ? Brand.red : .white.opacity(0.7))
                        .frame(width: 16)
                    Text(p.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if on {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: FilesTabSwitcherView.favRowH)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(on ? 0.12 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 ? p.id : (hover == p.id ? nil : hover) }
                .onTapGesture { open(p.url) }
                .help(L("Yeni sekmede aç"))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}
