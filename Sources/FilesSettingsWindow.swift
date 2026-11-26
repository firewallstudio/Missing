import Combine
import SwiftUI

// MARK: - Dosyalar ayarları (Finder'daki Ayarlar gibi, ⌘,)
//
// Genel: yeni pencerelerin görünümü, tema, gizli dosyalar.
// Kenar çubuğu: Sık kullanılanlar, Konumlar ve Etiketler'de hangilerinin görüneceği.
//
// Pencere seçili Dosyalar temasına bürünür ve tema bu pencereden değişince hemen yeniden çizilir:
// missing: koyu cam + kırmızı (Missing Ayarları'yla aynı)
// finder:  macOS Sistem Ayarları gibi gruplu kutular, yerel anahtarlar, sistem açık/koyu
// windows: Windows 11 Ayarlar gibi düz zemin, kenarlı kartlar, Windows anahtarları, sistem açık/koyu
// glass:   ince bulanık cam, yarı saydam kartlar, mor vurgu, sistem açık/koyu

@MainActor final class FilesSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = FilesSettingsWindow()
    private var window: NSWindow?
    private let state = FilesSettingsState()
    private var themeSub: AnyCancellable?

    enum Tab: Hashable { case general, sidebar }

    func show(tab: Tab = .general) {
        state.tab = tab
        if window == nil {
            // Başlıksız kabuk; zemini temaya göre SwiftUI çizer
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = L("Dosyalar Ayarları")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FilesSettingsView(state: state))
            w.delegate = self
            w.center()
            window = w
            applyAppearance(FilesThemeStore.shared.theme)
            // @Published yeni değeri willSet'te verir: pencere görünümü SwiftUI yeniden çizmeden önce değişir
            themeSub = FilesThemeStore.shared.$theme.sink { [weak self] t in
                MainActor.assumeIsolated { self?.applyAppearance(t) }
            }
        }
        FilesPlaces.shared.rebuildLocations()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Missing hep koyu cam; öbür temalar macOS'un açık/koyu ayarını izler
    private func applyAppearance(_ t: FilesTheme) {
        window?.appearance = t == .missing ? NSAppearance(named: .darkAqua) : nil
    }

    func windowWillClose(_ notification: Notification) {}
}

@MainActor final class FilesSettingsState: ObservableObject {
    @Published var tab: FilesSettingsWindow.Tab = .general
}

// MARK: - Tema ölçüleri (yalnızca bu pencere için)

private extension FilesPalette {
    /// İkincil metin (açıklama, alt not)
    var fgSecondary: Color { fg.opacity(theme == .windows ? 0.62 : 0.5) }

    /// Kartların köşesi
    var cardRadius: CGFloat {
        switch theme {
        case .missing: return 16
        case .finder: return 10
        case .windows: return 8
        case .glass: return 14
        }
    }

    /// Windows 11 Ayarlar: düz zemin ve kartlar
    var winSettingsSurface: Color { dark ? Color(red: 0x20 / 255.0, green: 0x20 / 255.0, blue: 0x20 / 255.0)
                                 : Color(red: 0xF3 / 255.0, green: 0xF3 / 255.0, blue: 0xF3 / 255.0) }
    var winCard: Color { dark ? Color(red: 0x2B / 255.0, green: 0x2B / 255.0, blue: 0x2B / 255.0) : .white }
    var winCardStroke: Color { dark ? Color.black.opacity(0.35) : Color.black.opacity(0.07) }
    var winControlStroke: Color { fg.opacity(dark ? 0.09 : 0.12) }

    /// macOS Sistem Ayarları: gruplu kutu
    var finderBox: Color { dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035) }
    var finderBoxStroke: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06) }

    /// Cam: beyaz yazının altındaki vurgu dolgusu; açık modda mor koyulaşır ki yazı okunsun
    var glassAccentFill: Color {
        dark ? accent.opacity(0.75) : Color(red: 0.45, green: 0.33, blue: 0.93).opacity(0.92)
    }

    /// Satır metni
    var rowFont: Font {
        switch theme {
        case .missing, .glass: return .system(size: 13, weight: .medium)
        case .finder, .windows: return .system(size: 13)
        }
    }
}

// MARK: - Kabuk

private struct FilesSettingsView: View {
    @ObservedObject var state: FilesSettingsState
    @ObservedObject private var store = FilesThemeStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Missing her zaman koyu; öbürleri pencerenin (macOS'un) açık/koyu hâlini izler
        let p = FilesPalette(theme: store.theme, dark: store.theme == .missing || scheme == .dark)
        VStack(spacing: 0) {
            header(p)
            ScrollView {
                VStack(alignment: .leading, spacing: p.theme == .finder || p.theme == .windows ? 18 : 14) {
                    switch state.tab {
                    case .general: FilesGeneralSettings()
                    case .sidebar: FilesSidebarSettings()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, p.theme == .missing || p.theme == .glass ? 0 : 14)
                .padding(.bottom, 20)
                .id(state.tab)
            }
        }
        .frame(width: 460, height: 600)
        .background(background(p).ignoresSafeArea())
        .foregroundStyle(p.fg)
        .tint(p.accent)
        .environment(\.filesPalette, p)
        .environment(\.colorScheme, p.dark ? .dark : .light)
    }

    @ViewBuilder private func background(_ p: FilesPalette) -> some View {
        switch p.theme {
        case .missing:
            ZStack { GlassBlur(material: .hudWindow, appearance: .darkAqua); Color.black.opacity(0.32) }
        case .finder:
            ZStack {
                GlassBlur(material: .windowBackground, appearance: p.dark ? .darkAqua : .aqua)
                p.finderChrome.opacity(0.92)
            }
        case .windows:
            p.winSurface
        case .glass:
            // İnce cam: bulanıklık + hafif beyaz pus
            ZStack {
                GlassBlur(material: .hudWindow, appearance: p.dark ? .darkAqua : .aqua)
                LinearGradient(colors: [.white.opacity(p.dark ? 0.08 : 0.30), .white.opacity(p.dark ? 0.03 : 0.16)],
                               startPoint: .top, endPoint: .bottom)
                p.accent.opacity(p.dark ? 0.06 : 0.05)
            }
        }
    }

    @ViewBuilder private func header(_ p: FilesPalette) -> some View {
        switch p.theme {
        case .missing, .glass:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: Brand.leaf).resizable().frame(width: 18, height: 18)
                    Text(L("Dosyalar Ayarları")).font(.system(size: 14, weight: .bold))
                }
                .padding(.top, 12)
                HStack(spacing: 4) {
                    pillTab(.general, L("Genel"), "gearshape", p)
                    pillTab(.sidebar, L("Kenar çubuğu"), "sidebar.left", p)
                }
                .padding(3)
                .background(Capsule().fill(p.theme == .glass ? p.glassFill(0.07) : .white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(p.theme == .glass ? p.glassStroke(0.18) : .white.opacity(0.10), lineWidth: 1))
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
        case .finder:
            // macOS ayar penceresi: ortada başlık, altında simgeli araç çubuğu sekmeleri
            VStack(spacing: 0) {
                Text(L("Dosyalar Ayarları")).font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    toolbarTab(.general, L("Genel"), "gearshape", p)
                    toolbarTab(.sidebar, L("Kenar çubuğu"), "sidebar.left", p)
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                Rectangle().fill(p.fg.opacity(p.dark ? 0.14 : 0.10)).frame(height: 1)
            }
            .frame(maxWidth: .infinity)
            .background(p.fg.opacity(p.dark ? 0.03 : 0.025))
        case .windows:
            // Windows 11 Ayarlar: solda büyük başlık, altında vurgu çizgili sekmeler
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: Brand.leaf).resizable().frame(width: 22, height: 22)
                    Text(L("Dosyalar Ayarları")).font(.system(size: 20, weight: .semibold))
                }
                .padding(.top, 38)
                HStack(spacing: 22) {
                    pivotTab(.general, L("Genel"), p)
                    pivotTab(.sidebar, L("Kenar çubuğu"), p)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func select(_ t: FilesSettingsWindow.Tab) {
        withAnimation(.easeOut(duration: 0.15)) { state.tab = t }
    }

    /// Missing / cam: kapsül içinde hap sekmeler
    private func pillTab(_ t: FilesSettingsWindow.Tab, _ title: String, _ icon: String, _ p: FilesPalette) -> some View {
        let on = state.tab == t
        let glass = p.theme == .glass
        return Button { select(t) } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? (glass ? p.glassAccentFill : Brand.red.opacity(0.85)) : .clear))
                .overlay(Capsule().strokeBorder(on && glass ? Color.white.opacity(0.35) : .clear, lineWidth: 1))
                .foregroundStyle(on ? Color.white : (glass ? p.fg.opacity(0.75) : .white.opacity(0.7)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Finder: simge üstte, ad altta; seçili olan gri kutu içinde, simgesi vurgu renginde
    private func toolbarTab(_ t: FilesSettingsWindow.Tab, _ title: String, _ icon: String, _ p: FilesPalette) -> some View {
        let on = state.tab == t
        return Button { select(t) } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .regular))
                    .foregroundStyle(on ? p.accent : p.fg.opacity(0.6))
                    .frame(height: 22)
                Text(title).font(.system(size: 11))
                    .foregroundStyle(on ? p.fg : p.fg.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minWidth: 72)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? p.fg.opacity(p.dark ? 0.10 : 0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Windows: düz metin sekme, seçilinin altında kısa vurgu çizgisi
    private func pivotTab(_ t: FilesSettingsWindow.Tab, _ title: String, _ p: FilesPalette) -> some View {
        let on = state.tab == t
        return Button { select(t) } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? p.fg : p.fg.opacity(0.62))
                Capsule().fill(on ? p.accent : .clear).frame(width: 18, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Yapı taşları (Settings.swift'tekilerin temaya uyan kopyaları)

/// Ayar kartı: başlık + içerik, katlanmaz
private struct FilesSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    @Environment(\.filesPalette) private var p

    init(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        switch p.theme {
        case .missing, .glass: badgeCard
        case .finder: finderGroup
        case .windows: windowsCard
        }
    }

    /// Missing / cam: rozetli başlık kartın içinde
    private var badgeCard: some View {
        let glass = p.theme == .glass
        let shape = RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(glass ? p.glassAccentFill : Brand.red.opacity(0.85)))
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 9) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Group {
            if glass {
                shape.fill(LinearGradient(colors: [p.glassFill(0.10), p.glassFill(0.04)], startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(.white.opacity(0.06))
            }
        })
        .overlay(shape.strokeBorder(glass ? p.glassStroke(0.22) : .white.opacity(0.10), lineWidth: 1))
    }

    /// Sistem Ayarları: kalın başlık kutunun üstünde, satırlar gri gruplu kutuda
    private var finderGroup: some View {
        let shape = RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .bold))
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 9) { content }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(p.finderBox))
                .overlay(shape.strokeBorder(p.finderBoxStroke, lineWidth: 1))
        }
    }

    /// Windows 11: yarı kalın başlık, 1 px kenarlı düz kart
    private var windowsCard: some View {
        let shape = RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 11) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(p.winCard))
                .overlay(shape.strokeBorder(p.winCardStroke, lineWidth: 1))
        }
    }
}

/// Satırlar arası çizgi
private struct FilesSettingsDivider: View {
    @Environment(\.filesPalette) private var p

    var body: some View {
        switch p.theme {
        case .missing: Divider().opacity(0.4)
        case .glass: Rectangle().fill(p.glassStroke(0.12)).frame(height: 1)
        case .finder, .windows: Rectangle().fill(p.divider).frame(height: 1)
        }
    }
}

/// Settings.swift'teki Row gibi: açıklama ipucu olarak çıkar
private struct FilesSettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing
    @Environment(\.filesPalette) private var p

    init(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(p.rowFont)
                .help(detail ?? "")
            // Missing'de Settings.swift'teki Row'la aynı boşluk; öbürlerinde dar satırda ad tek satıra sığsın
            Spacer(minLength: p.theme == .missing ? 8 : 0)
            trailing
        }
    }
}

/// Temaya göre aç/kapa anahtarı
private struct FilesSettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.filesPalette) private var p

    var body: some View {
        switch p.theme {
        case .missing:
            BrandToggle(isOn: $isOn)
        case .finder:
            // macOS'un kendi anahtarı (Sistem Ayarları'ndaki küçük boy)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        case .windows, .glass:
            Toggle("", isOn: $isOn)
                .toggleStyle(FilesThemedSwitchStyle(p: p))
                .labelsHidden()
        }
    }
}

/// Windows 11 anahtarı (açıkken vurgu dolgulu hap, kapalıyken kenarlı boş hap) ve cam anahtarı
private struct FilesThemedSwitchStyle: ToggleStyle {
    let p: FilesPalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let win = p.theme == .windows
        return ZStack(alignment: on ? .trailing : .leading) {
            if win {
                Capsule()
                    .fill(on ? p.accent : Color.clear)
                    .overlay(Capsule().strokeBorder(on ? Color.clear : p.fg.opacity(p.dark ? 0.6 : 0.55), lineWidth: 1))
                Circle()
                    .fill(on ? p.onAccent : p.fg.opacity(p.dark ? 0.8 : 0.62))
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 4)
            } else {
                Capsule()
                    .fill(on ? p.glassAccentFill : p.glassFill(0.16))
                    .overlay(Capsule().strokeBorder(on ? Color.white.opacity(0.35) : p.glassStroke(0.25), lineWidth: 1))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .padding(2)
            }
        }
        .frame(width: win ? 40 : 36, height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// Settings.swift'teki ToggleRow gibi
private struct FilesSettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        FilesSettingsRow(title, detail) { FilesSettingsSwitch(isOn: $isOn) }
    }
}

/// Simge + ad + anahtar
private struct FilesSettingsToggle<Leading: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            leading.font(.system(size: 13))
            Spacer(minLength: 8)
            FilesSettingsSwitch(isOn: $isOn)
        }
    }
}

/// Seçim: Missing ve Finder'da macOS'un bölümlü denetimi; Windows ve camda temaya uyan çizim
private struct FilesSettingsSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    let width: CGFloat
    /// Windows / cam çiziminde genişlik (verilmezse width); uzun Türkçe satır adı tek satıra sığsın
    var customWidth: CGFloat? = nil
    /// Finder temasında bölümlü denetim yerine açılır menü
    var finderMenu = false
    @Environment(\.filesPalette) private var p

    var body: some View {
        switch p.theme {
        case .missing:
            native.pickerStyle(.segmented).frame(width: width)
        case .finder:
            // Doğal genişliğinde kalsın (sabit genişlikte kutunun sağ kenarından taşıyor);
            // küçük boy, Türkçe uzun satır adları tek satıra sığsın diye
            if finderMenu {
                // Finder Ayarları'ndaki gibi açılır menü: dar, uzun satır adına yer kalır
                native.pickerStyle(.menu).fixedSize()
            } else {
                native.pickerStyle(.segmented).controlSize(.small).fixedSize()
            }
        case .windows, .glass:
            custom
        }
    }

    private var native: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) }
        }
        .labelsHidden()
    }

    private var custom: some View {
        let win = p.theme == .windows
        let r: CGFloat = win ? 4 : 8
        let outer = RoundedRectangle(cornerRadius: r + 2, style: .continuous)
        return HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(options[i].1)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? (win ? p.onAccent : Color.white) : p.fg.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: r, style: .continuous)
                            .fill(on ? (win ? p.accent : p.glassAccentFill) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: customWidth ?? width)
        .background(outer.fill(win ? p.controlFill : p.glassFill(0.08)))
        .overlay(outer.strokeBorder(win ? p.winControlStroke : p.glassStroke(0.2), lineWidth: 1))
    }
}

/// Simge boyutu kaydırıcısı
private struct FilesSettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.filesPalette) private var p

    var body: some View {
        switch p.theme {
        case .missing:
            FilesZoomSlider(value: $value, range: range, tint: Brand.red, track: .white.opacity(0.18), knob: 16)
        case .finder:
            Slider(value: $value, in: range).controlSize(.small).labelsHidden()
        case .glass:
            FilesZoomSlider(value: $value, range: range, tint: p.accent, track: p.glassFill(0.22), knob: 16)
        case .windows:
            windows
        }
    }

    /// Windows 11: ince iz, ortası vurgu noktalı yuvarlak tutamaç
    private var windows: some View {
        let knob: CGFloat = 18
        return GeometryReader { g in
            let w = max(1, g.size.width - knob)
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(p.fg.opacity(p.dark ? 0.5 : 0.45)).frame(height: 4)
                Capsule().fill(p.accent).frame(width: knob / 2 + w * f, height: 4)
                ZStack {
                    Circle().fill(p.dark ? Color(white: 0.27) : .white)
                    Circle().strokeBorder(p.winControlStroke, lineWidth: 1)
                    Circle().fill(p.accent).frame(width: 10, height: 10)
                }
                .frame(width: knob, height: knob)
                .offset(x: w * f)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let t = min(max((d.location.x - knob / 2) / w, 0), 1)
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }
    }
}

// MARK: - Sayfalar

private struct FilesGeneralSettings: View {
    @ObservedObject private var themes = FilesThemeStore.shared
    @ObservedObject private var zoom = FilesGridZoom.shared
    @State private var viewMode = FilesSettings.viewMode
    @State private var showHidden = FilesSettings.showHidden
    @State private var replaceFinder = FinderReplacement.enabled

    var body: some View {
        FilesSettingsSection(L("Görünüm"), "square.grid.2x2") {
            FilesSettingsRow(L("Yeni pencerelerde görünüm"), nil) {
                FilesSettingsSegments(selection: $viewMode,
                                      options: [(FilesViewMode.list, L("Liste")),
                                                (FilesViewMode.grid, L("Simgeler")),
                                                (FilesViewMode.columns, L("Sütunlar"))],
                                      width: 200, customWidth: 180, finderMenu: true)
                .onChange(of: viewMode) { FilesSettings.viewMode = $0 }
            }
            FilesSettingsDivider()
            FilesSettingsRow(L("Simge boyutu"), nil) {
                FilesSettingsSlider(value: $zoom.size, range: FilesGridZoom.range)
                    .frame(width: 200, height: 18)
            }
            FilesSettingsDivider()
            FilesSettingsRow(L("Tema"), nil) {
                FilesSettingsSegments(selection: $themes.theme,
                                      options: FilesTheme.allCases.map { ($0, $0.title) },
                                      width: 260)
            }
        }
        FilesSettingsSection(L("Dosyalar"), "doc.on.doc") {
            FilesSettingsToggleRow(L("Finder yerine Dosyalar'ı kullan"),
                                   L("Başka uygulamalardaki \"Finder'da göster\" (indirmeler, Spotlight, VS Code…) ve masaüstündeki klasörler Dosyalar'da açılır. Açık uygulamalar değişikliği yeniden açılınca görür. Kapatınca Finder'a döner."),
                                   isOn: $replaceFinder)
                .onChange(of: replaceFinder) { FinderReplacement.enabled = $0 }
            FilesSettingsDivider()
            FilesSettingsToggleRow(L("Klasör boyutlarını hesapla"), L("Liste görünümünde klasörlerin boyutu da yazar (arka planda hesaplanır)"),
                                   isOn: Binding(get: { FilesSettings.folderSizes }, set: { v in
                                       FilesSettings.folderSizes = v
                                       FilesManager.shared.windows.forEach { $0.model.tabs.forEach { $0.reload() } }
                                   }))
            FilesSettingsDivider()
            FilesSettingsToggleRow(L("Gizli dosyaları göster"), nil, isOn: $showHidden)
                .onChange(of: showHidden) { v in
                    guard v != FilesSettings.showHidden else { return }
                    if let w = FilesManager.shared.windows.first { w.toggleHidden(nil) } else { FilesSettings.showHidden = v }
                }
        }
        .onAppear {
            viewMode = FilesSettings.viewMode
            showHidden = FilesSettings.showHidden
        }
    }
}

/// Finder'daki Ayarlar › Kenar Çubuğu gibi: her öğe için bir anahtar
private struct FilesSidebarSettings: View {
    @ObservedObject private var places = FilesPlaces.shared
    @Environment(\.filesPalette) private var p

    var body: some View {
        FilesSettingsSection(L("Sık kullanılanlar"), "star") {
            ForEach(places.favorites) { f in
                if let key = f.hideKey { check(f.symbol, f.title, key) }
            }
        }
        FilesSettingsSection(L("Konumlar"), "externaldrive") {
            check("internaldrive", L("Sabit diskler"), "disks")
            check("externaldrive", L("Harici diskler"), "external")
            check("cloud", L("Bulut depolama") + cloudNames, "cloud")
            check("house", FileManager.default.displayName(atPath: NSHomeDirectory()), "home")
            check("airplayaudio", "AirDrop", "airdrop")
            check("network", L("Ağ"), "network")
            check("trash", L("Çöp Sepeti"), "trash")
            check("clock", L("Son Kullanılanlar"), "recents")
        }
        FilesSettingsSection(L("Etiketler"), "tag") {
            FilesSettingsToggle(isOn: binding("tags")) {
                Text(L("Etiketleri göster")).fontWeight(.medium)
            }
            if !places.tags.isEmpty { FilesSettingsDivider() }
            ForEach(places.tags) { t in
                FilesSettingsToggle(isOn: binding(FilesPlaces.tagKey(t))) {
                    HStack(spacing: 9) {
                        TagDot(tag: t, size: 10).frame(width: 18)
                        Text(t.name)
                    }
                }
                .disabled(!places.tagsVisible)
                .opacity(places.tagsVisible ? 1 : 0.45)
            }
        }
        Text(L("Sık kullanılanlar Finder'la aynıdır: buradan gizlemek yalnızca Dosyalar'ın kenar çubuğunu etkiler, Finder'dakini değil."))
            .font(.system(size: 11))
            .foregroundStyle(p.fgSecondary)
            .padding(.horizontal, 4)
    }

    private var cloudNames: String {
        let names = places.locations.filter { $0.hideKey == "cloud" }.map(\.title)
        return names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { places.isVisible(key) }, set: { places.setVisible(key, $0) })
    }

    /// Finder'da simgeler sistem vurgusunda (Finder kenar çubuğu gibi), öbürlerinde metin renginde
    private var symbolColor: Color {
        switch p.theme {
        case .finder: return p.accent
        case .windows: return p.fg.opacity(0.8)
        default: return p.fg.opacity(0.7)
        }
    }

    private func check(_ symbol: String, _ title: String, _ key: String) -> some View {
        FilesSettingsToggle(isOn: binding(key)) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                    .frame(width: 18)
                Text(title).lineLimit(1)
            }
        }
    }
}
