import AppKit
import SwiftUI

// MARK: - Dosyalar penceresi temaları
//
// Hepsi macOS'un açık/koyu ayarını izler.
// missing: cam + kırmızı (ilk tasarım)
// finder:  macOS Finder gibi; tam boy kenar çubuğu, sekmeler araç çubuğunun altında, sistem açık/koyu
// windows: Windows 11 Gezgini gibi; üstte sekmeler, adres + komut çubuğu, mavi vurgu, sistem açık/koyu
// glass:   glassmorphism; renkli bulanık zemin üstünde yüzen yarı saydam kartlar

enum FilesTheme: String, CaseIterable, Identifiable {
    case missing, finder, windows, glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missing: return "Missing"
        case .finder: return "Finder"
        case .windows: return "Windows"
        case .glass: return L("Cam")
        }
    }

    /// Koyu görünümü dayatan tema yok: hepsi macOS'un açık/koyu ayarını izler
    var forcesDark: Bool { false }
}

@MainActor final class FilesThemeStore: ObservableObject {
    static let shared = FilesThemeStore()
    /// Değer yazıldıktan hemen sonra, SwiftUI yeniden çizmeden önce çağrılır (pencere görünümü önce değişsin)
    var onChange: () -> Void = { MainActor.assumeIsolated { FilesManager.shared.windows.forEach { $0.applyTheme() } } }

    @Published var theme: FilesTheme {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: "files.theme")
            onChange()
        }
    }

    private init() {
        theme = FilesTheme(rawValue: UserDefaults.standard.string(forKey: "files.theme") ?? "") ?? .missing
    }
}

/// Bir temanın açık ya da koyu hâlindeki bütün renk ve ölçüleri
struct FilesPalette {
    let theme: FilesTheme
    let dark: Bool

    @MainActor static func current(for appearance: NSAppearance?) -> FilesPalette {
        let t = FilesThemeStore.shared.theme
        let dark = t.forcesDark || (appearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return FilesPalette(theme: t, dark: dark)
    }

    // MARK: Renkler

    var nsAccent: NSColor {
        switch theme {
        case .missing: return Brand.nsRed
        case .finder: return .controlAccentColor
        case .windows: return dark ? NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 1)
                                   : NSColor(srgbRed: 0.0, green: 0.37, blue: 0.72, alpha: 1)
        case .glass: return NSColor(srgbRed: 0.68, green: 0.58, blue: 1.0, alpha: 1)
        }
    }
    var accent: Color { Color(nsColor: nsAccent) }

    /// Metin ve simgelerin taban rengi (opaklıkla kademelenir)
    var fg: Color { dark ? .white : .black }
    var nsFG: NSColor { dark ? .white : .black }

    /// Vurgunun üstündeki metin (Windows koyu modda açık mavi üstüne siyah yazar)
    var onAccent: Color { theme == .windows && dark ? .black : .white }

    var divider: Color { fg.opacity(theme == .windows ? (dark ? 0.10 : 0.09) : 0.08) }
    var hoverFill: Color { fg.opacity(dark ? 0.07 : 0.05) }
    /// Dosya satırı / simgesi fare üstündeyken (hafif gri)
    var nsHover: NSColor { nsFG.withAlphaComponent(theme == .glass ? 0.08 : (dark ? 0.06 : 0.045)) }
    var pressFill: Color { fg.opacity(dark ? 0.16 : 0.10) }
    var controlFill: Color {
        switch theme {
        case .windows: return dark ? Color(white: 0.17) : .white
        case .finder: return fg.opacity(dark ? 0.08 : 0.05)
        default: return fg.opacity(0.07)
        }
    }

    // Windows renkleri
    static func gray(_ v: Double) -> Color { Color(white: v) }
    var winTabBar: Color { dark ? Self.gray(0.12) : Color(red: 0.91, green: 0.93, blue: 0.95) }
    var winChrome: Color { dark ? Self.gray(0.17) : Self.gray(0.975) }
    var winContent: Color { dark ? Self.gray(0.11) : .white }

    // Finder renkleri
    var finderContent: Color { Color(nsColor: .textBackgroundColor) }
    var finderChrome: Color { Color(nsColor: .windowBackgroundColor) }
    var finderTabBar: Color { dark ? Self.gray(0.13) : Self.gray(0.86) }

    // MARK: Ölçüler

    var radius: CGFloat {
        switch theme {
        case .missing: return 8
        case .finder: return 6
        case .windows: return 4
        case .glass: return 12
        }
    }

    var rowHeight: CGFloat {
        switch theme {
        case .missing: return 24
        case .finder: return 22
        case .windows: return 28
        case .glass: return 26
        }
    }

    // MARK: Liste / simge seçimi (AppKit)

    func rowSelection(emphasized: Bool) -> NSColor {
        switch theme {
        case .missing:
            return emphasized ? Brand.nsRed.withAlphaComponent(0.85) : nsFG.withAlphaComponent(dark ? 0.16 : 0.10)
        case .finder:
            return emphasized ? .controlAccentColor : .unemphasizedSelectedContentBackgroundColor
        case .windows:
            return emphasized ? nsAccent.withAlphaComponent(dark ? 0.24 : 0.16) : nsFG.withAlphaComponent(dark ? 0.10 : 0.06)
        case .glass:
            return dark ? NSColor.white.withAlphaComponent(emphasized ? 0.22 : 0.12)
                        : NSColor.black.withAlphaComponent(emphasized ? 0.10 : 0.06)
        }
    }

    var rowStroke: NSColor? {
        switch theme {
        case .glass: return dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.10)
        case .windows: return nil
        default: return nil
        }
    }

    /// Seçili satırda metin beyaza dönsün mü (dolu vurgu); Windows ve cam açık dolguda normal metin tutar
    var selectionInvertsText: Bool { theme == .missing || theme == .finder }

    var rowInset: CGFloat { theme == .windows ? 4 : 6 }
    var rowRadius: CGFloat {
        switch theme {
        case .windows: return 4
        case .finder: return 5
        case .glass: return 8
        case .missing: return 6
        }
    }

    var gridBack: NSColor {
        switch theme {
        case .windows: return nsAccent.withAlphaComponent(dark ? 0.24 : 0.16)
        case .glass: return dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.08)
        // Missing: adın değil simgenin çevresi açık kırmızı
        case .missing: return Brand.nsRed.withAlphaComponent(0.30)
        default: return nsFG.withAlphaComponent(dark ? 0.14 : 0.08)
        }
    }

    /// Simge görünümünde seçili kutunun ince kenarı
    var gridStroke: NSColor? {
        switch theme {
        case .glass: return dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.12)
        case .missing: return Brand.nsRed.withAlphaComponent(0.55)
        default: return nil
        }
    }

    /// Simge görünümünde seçili adın arkası; nil ise boyanmaz
    var gridLabelBack: NSColor? {
        switch theme {
        case .finder: return .controlAccentColor
        default: return nil
        }
    }

    var renameBack: NSColor { dark ? NSColor(white: 0.12, alpha: 1) : .white }

    /// Cam temasında beyaz dolgu: koyu zeminde hafif, açık zeminde daha belirgin
    func glassFill(_ level: Double) -> Color { .white.opacity(dark ? level : min(1, level * 3.5)) }
    /// Cam temasında ince kenar
    func glassStroke(_ level: Double) -> Color { dark ? .white.opacity(level) : .black.opacity(level * 0.4) }
}

private struct FilesPaletteKey: EnvironmentKey {
    static let defaultValue = FilesPalette(theme: .missing, dark: true)
}

extension EnvironmentValues {
    var filesPalette: FilesPalette {
        get { self[FilesPaletteKey.self] }
        set { self[FilesPaletteKey.self] = newValue }
    }
}

/// Cam teması zemini: bulanıklığın üstünde yumuşak renk lekeleri
struct GlassmorphBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Açık modda aynı renkler daha soluk, üstünde beyaz pus
        let k = scheme == .dark ? 1.0 : 0.45
        ZStack {
            GlassBlur(material: .hudWindow, appearance: scheme == .dark ? .darkAqua : .aqua)
            LinearGradient(colors: [Color(red: 0.28, green: 0.16, blue: 0.55).opacity(0.55 * k),
                                    Color(red: 0.10, green: 0.22, blue: 0.48).opacity(0.45 * k),
                                    Color(red: 0.50, green: 0.14, blue: 0.40).opacity(0.45 * k)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Circle().fill(Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.35 * k))
                    .frame(width: g.size.width * 0.55).blur(radius: 90)
                    .position(x: g.size.width * 0.15, y: g.size.height * 0.2)
                Circle().fill(Color(red: 0.15, green: 0.75, blue: 0.95).opacity(0.25 * k))
                    .frame(width: g.size.width * 0.5).blur(radius: 100)
                    .position(x: g.size.width * 0.9, y: g.size.height * 0.85)
            }
            scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.30)
        }
    }
}

/// Cam teması kartı: yarı saydam beyaz dolgu + ince parlak kenar
struct GlassCard: ViewModifier {
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background(shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.12 : 0.55), .white.opacity(dark ? 0.05 : 0.35)],
                                                  startPoint: .top, endPoint: .bottom)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.35 : 0.9), .white.opacity(dark ? 0.08 : 0.4)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.25 : 0.10), radius: 14, y: 6)
    }
}
