import SwiftUI

// MARK: - Kısayollar sayfası (Ayarlar › Kısayollar)
//
// Üstte küçük bir "ekran": seçili kısayolun ne yaptığı döngüyle canlandırılır.
// Altta tüm kısayollar; birine tıklayınca sahne onu oynatır.

enum ShortcutDemo: String, CaseIterable, Identifiable {
    case switcher, preview, audio, shot, area, record, scroll, tile, search
    var id: String { rawValue }

    var keys: [String] {
        switch self {
        case .switcher: return ["⌘", "Tab"]
        case .preview: return ["⌥", "Tab"]
        case .audio: return ["⌘", "⇧"]
        case .shot: return ["⌘", "⇧", "3"]
        case .area: return ["⌘", "⇧", "4"]
        case .record: return ["⌘", "⇧", "5"]
        case .scroll: return ["⌘", "⇧", "6"]
        case .tile: return ["⌘", "<"]
        case .search: return ["⌘", "Space"]
        }
    }

    var title: String {
        switch self {
        case .switcher: return L("Pencere değiştir")
        case .preview: return L("Önizlemeli değiştir")
        case .audio: return L("Ses cihazını değiştir")
        case .shot: return L("Bu monitörün görüntüsü")
        case .area: return L("Ekran alıntısı")
        case .record: return L("Ekran kaydı")
        case .scroll: return L("Kaydırmalı görüntü")
        case .tile: return L("Ekranı böl")
        case .search: return L("Dosya ara (Finder'da)")
        }
    }

    var detail: String {
        switch self {
        case .switcher: return L("⌘ basılıyken Tab ile kartlar arasında gez, ⌘'yi bırakınca o pencereye geç.")
        case .preview: return L("Aynısı, pencerelerin canlı önizlemeleriyle.")
        case .audio: return L("⌘ basılıyken ⇧'ye dokun: sıradaki ses cihazına geçer.")
        case .shot: return L("Farenin olduğu monitörün görüntüsünü alır.")
        case .area: return L("Bir alan seç; Space ile pencere seçimine geç.")
        case .record: return L("Çekim paleti açılır; kayıt sırasında tekrar basınca durur.")
        case .scroll: return L("Alanı seç, sayfa kendiliğinden kayar, uzun tek bir görüntü olur.")
        case .tile: return L("Kaça bölüneceğini seç, pencereler bölmelere yerleşir.")
        case .search: return L("Finder öndeyken: o klasörün içinde dosya adına göre anında arar.")
        }
    }

    /// Bu kısayolun özelliği açık mı
    var enabled: Bool {
        switch self {
        case .switcher: return Profile.cmd.enabled
        case .preview: return Profile.opt.enabled
        case .audio: return DeviceStore.shared.hotkeyEnabled
        case .shot: return CaptureSettings.enabled && CaptureSettings.screenKey
        case .area: return CaptureSettings.enabled && CaptureSettings.areaKey
        case .record: return CaptureSettings.enabled && CaptureSettings.videoKey
        case .scroll: return CaptureSettings.enabled && CaptureSettings.scrollKey
        case .tile: return TileSettings.enabled
        case .search: return FileSearchSettings.enabled
        }
    }
}

struct ShortcutsPage: View {
    @State private var chosen: ShortcutDemo?
    /// Sadece açık özelliklerin kısayolları
    private var shown: [ShortcutDemo] { ShortcutDemo.allCases.filter(\.enabled) }
    private var selected: ShortcutDemo { chosen.flatMap { shown.contains($0) ? $0 : nil } ?? shown.first ?? .switcher }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DemoStage(demo: selected)
                .frame(maxWidth: .infinity)
                .id(selected)
            VStack(alignment: .leading, spacing: 4) {
                Text(selected.title).font(.system(size: 15, weight: .semibold))
                Text(selected.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(shown) { d in tile(d) }
            }
            if Profile.allCases.contains(where: \.enabled) { panelKeys }
        }
    }

    private func tile(_ d: ShortcutDemo) -> some View {
        let on = d == selected
        return Button { withAnimation(.easeOut(duration: 0.2)) { chosen = d } } label: {
            HStack(spacing: 10) {
                KeyCombo(keys: d.keys, size: 10.5)
                Text(d.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(on ? Brand.red.opacity(0.22) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(on ? Brand.red.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelKeys: some View {
        Card(title: L("⌘Tab paneli açıkken"), icon: "rectangle.on.rectangle") {
            VStack(alignment: .leading, spacing: 7) {
                keyLine(["Tab"], L("İleri / geri (⇧ ile geri)"))
                keyLine(["←", "→", "↑", "↓"], L("Gezin"))
                keyLine(["↩"], L("Seçili pencereye geç"))
                keyLine(["Esc"], L("İptal"))
                keyLine(["W", "M", "H", "Q"], L("Kapat · Küçült · Gizle · Çık"))
                keyLine(["S"], L("Uygulamanın ses cihazını değiştir"))
                keyLine(["A"], L("Sadece bir uygulamanın pencereleri"))
            }
        }
    }

    private func keyLine(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 12) {
            KeyCombo(keys: keys, size: 10.5).frame(width: 150, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
    }
}

// MARK: - Sahne

/// Döngüyle oynayan küçük ekran. t: 0…1 (3,2 sn)
struct DemoStage: View {
    let demo: ShortcutDemo
    private let period = 3.2
    static let size = CGSize(width: 520, height: 250)

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack(alignment: .bottom) {
                DemoScene(demo: demo, t: t)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                pressedKeys(t)
                    .offset(y: 18)
            }
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
    }

    /// Kısayolun tuşları: basılı olduğu sürede kırmızı yanar
    private func pressedKeys(_ t: Double) -> some View {
        let down = DemoScene.keysDown(demo, t)
        return HStack(spacing: 5) {
            ForEach(Array(demo.keys.enumerated()), id: \.offset) { _, k in
                KeyCap(key: k, size: 13)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(down ? Brand.red : Color.black.opacity(0.6)))
                    .scaleEffect(down ? 0.94 : 1)
            }
        }
        .padding(6)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

/// Sahnenin kendisi: masaüstü + kısayola göre hareket eden parçalar
struct DemoScene: View {
    let demo: ShortcutDemo
    let t: Double
    private var W: CGFloat { DemoStage.size.width }
    private var H: CGFloat { DemoStage.size.height }

    static func keysDown(_ d: ShortcutDemo, _ t: Double) -> Bool {
        switch d {
        case .switcher, .preview: return t > 0.08 && t < 0.78
        case .audio: return (t > 0.08 && t < 0.16) || (t > 0.42 && t < 0.5)
        default: return t > 0.06 && t < 0.18
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar
            content
        }
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.14), Color(red: 0.06, green: 0.06, blue: 0.09)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                RadialGradient(colors: [Brand.red.opacity(0.22), .clear], center: UnitPoint(x: 0.8, y: 0.2), startRadius: 0, endRadius: 220)
            )
    }

    private var menuBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "applelogo").font(.system(size: 8))
            Capsule().fill(.white.opacity(0.25)).frame(width: 30, height: 4)
            Capsule().fill(.white.opacity(0.18)).frame(width: 22, height: 4)
            Spacer()
            Image(nsImage: NSImage(named: "MenuIconTemplate") ?? NSImage()).resizable().frame(width: 9, height: 9).opacity(0.8)
            Capsule().fill(.white.opacity(0.25)).frame(width: 24, height: 4)
        }
        .padding(.horizontal, 10)
        .frame(width: W, height: 14)
        .background(.black.opacity(0.35))
    }

    @ViewBuilder private var content: some View {
        switch demo {
        case .switcher: switcher(previews: false)
        case .preview: switcher(previews: true)
        case .audio: audio
        case .shot: shot
        case .area: area
        case .record: record
        case .scroll: scroll
        case .tile: tile
        case .search: search
        }
    }

    // MARK: Ortak parçalar

    /// İlerleme: a…b arasında 0→1 (yumuşak)
    private func p(_ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func window(_ color: Color, _ frame: CGRect, title: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 12)
            .background(.white.opacity(0.10))
            ZStack(alignment: .topLeading) {
                color.opacity(0.85)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(.white.opacity(0.35)).frame(width: frame.width * 0.5, height: 4)
                    Capsule().fill(.white.opacity(0.2)).frame(width: frame.width * 0.7, height: 4)
                    Capsule().fill(.white.opacity(0.2)).frame(width: frame.width * 0.4, height: 4)
                }
                .padding(8)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        .position(x: frame.midX, y: frame.midY)
    }

    private var desktopWindows: some View {
        ZStack(alignment: .topLeading) {
            window(Color(red: 0.20, green: 0.32, blue: 0.55), CGRect(x: 40, y: 34, width: 230, height: 150))
            window(Color(red: 0.24, green: 0.24, blue: 0.28), CGRect(x: 220, y: 60, width: 250, height: 160))
        }
    }

    private func flash(at a: Double) -> some View {
        let f = max(0, 1 - abs(t - a) / 0.05)
        return Color.white.opacity(f * 0.7).frame(width: W, height: H).allowsHitTesting(false)
    }

    private func thumbnail(from: Double) -> some View {
        let k = p(from, from + 0.18)
        let w = W - (W - 90) * k
        let h = H - (H - 44) * k
        let x = (W / 2) + ((W - 56) - W / 2) * k
        let y = (H / 2) + ((H - 34) - H / 2) * k
        return RoundedRectangle(cornerRadius: 4 + 4 * k, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4 + 4 * k).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
            .frame(width: w, height: h)
            .position(x: x, y: y)
            .opacity(t > from && t < 0.92 ? 1 : 0)
    }

    // MARK: Sahneler

    private func switcher(previews: Bool) -> some View {
        let icons = ["safari.fill", "folder.fill", "music.note", "paintbrush.fill"]
        let colors: [Color] = [.blue, .cyan, .pink, .orange]
        let show = t > 0.1 && t < 0.8
        let idx = min(3, max(0, Int((t - 0.12) / 0.16)))
        let cardW: CGFloat = previews ? 86 : 54
        return ZStack(alignment: .topLeading) {
            desktopWindows
            if t >= 0.8 {
                window(colors[3].opacity(0.7), CGRect(x: 120, y: 40, width: 280, height: 175))
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(spacing: 4) {
                        if previews {
                            RoundedRectangle(cornerRadius: 4).fill(colors[i].opacity(0.55)).frame(width: cardW - 12, height: 44)
                        }
                        Image(systemName: icons[i]).font(.system(size: previews ? 16 : 22)).foregroundStyle(colors[i])
                    }
                    .frame(width: cardW, height: previews ? 82 : 58)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(i == idx ? 0.22 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(i == idx ? Brand.red : .clear, lineWidth: 1.5))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
            .position(x: W / 2, y: H / 2)
            .opacity(show ? 1 : 0)
            .scaleEffect(show ? 1 : 0.96)
        }
    }

    private var audio: some View {
        let devices = [("speaker.wave.2.fill", L("Hoparlör")), ("headphones", L("Kulaklık")), ("airpodspro", "AirPods")]
        let cur = t < 0.12 ? 0 : (t < 0.46 ? 1 : 2)
        let visible = (t > 0.12 && t < 0.38) || (t > 0.46 && t < 0.75)
        return ZStack(alignment: .topLeading) {
            desktopWindows
            VStack(spacing: 6) {
                Image(systemName: devices[cur].0).font(.system(size: 22, weight: .semibold))
                Text(devices[cur].1).font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: devices[i].0).font(.system(size: 9))
                            .foregroundStyle(i == cur ? Brand.red : .white.opacity(0.5))
                    }
                }
            }
            .frame(width: 130, height: 84)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
            .position(x: W / 2, y: H - 64)
            .opacity(visible ? 1 : 0)
        }
    }

    private var shot: some View {
        ZStack(alignment: .topLeading) {
            desktopWindows
            flash(at: 0.2)
            thumbnail(from: 0.22)
        }
    }

    private var area: some View {
        let k = p(0.12, 0.55)
        let start = CGPoint(x: 150, y: 60)
        let end = CGPoint(x: 150 + 200 * k, y: 60 + 120 * k)
        let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
        return ZStack(alignment: .topLeading) {
            desktopWindows
            if t < 0.62 {
                Color.black.opacity(0.25).frame(width: W, height: H)
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.08))
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
                Image(systemName: "plus").font(.system(size: 14, weight: .light)).position(end)
            }
            flash(at: 0.62)
            thumbnail(from: 0.64)
        }
    }

    private var record: some View {
        let recording = t > 0.25 && t < 0.9
        let secs = Int(max(0, t - 0.25) * 12)
        return ZStack(alignment: .topLeading) {
            desktopWindows
            if t > 0.12 && t < 0.25 {
                HStack(spacing: 10) {
                    ForEach(["rectangle.dashed", "macwindow", "record.circle"], id: \.self) { s in
                        Image(systemName: s).font(.system(size: 13))
                            .foregroundStyle(s == "record.circle" ? Brand.red : .white)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.75)))
                .position(x: W / 2, y: H - 40)
            }
            if recording {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Brand.red.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: W - 20, height: H - 30)
                    .position(x: W / 2, y: H / 2 + 7)
                HStack(spacing: 5) {
                    Circle().fill(Brand.red).frame(width: 7, height: 7)
                        .opacity(0.5 + 0.5 * sin(t * 40))
                    Text(String(format: "00:%02d", secs)).font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .position(x: W - 50, y: 26)
            }
        }
    }

    private var scroll: some View {
        let k = p(0.2, 0.85)
        let rows = 14
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                Color(white: 0.92)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<rows, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i % 4 == 0 ? Brand.red.opacity(0.6) : Color(white: 0.7))
                            .frame(width: i % 4 == 0 ? 120 : CGFloat(150 + (i * 23) % 90), height: i % 4 == 0 ? 8 : 5)
                    }
                }
                .padding(14)
                .offset(y: -160 * k)
            }
            .frame(width: 260, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .position(x: 170, y: 125)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(white: 0.85))
                .overlay(alignment: .top) {
                    VStack(spacing: 3) {
                        ForEach(0..<Int(4 + 10 * k), id: \.self) { i in
                            Capsule().fill(i % 4 == 0 ? Brand.red.opacity(0.6) : Color(white: 0.6)).frame(width: 46, height: 2)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(width: 70, height: 60 + 140 * k)
                .position(x: 410, y: 30 + (60 + 140 * k) / 2)
                .opacity(t > 0.18 ? 1 : 0)
        }
    }

    private var tile: some View {
        let k = p(0.3, 0.6)
        let starts = [CGRect(x: 40, y: 40, width: 220, height: 150), CGRect(x: 180, y: 70, width: 240, height: 150), CGRect(x: 110, y: 90, width: 200, height: 140)]
        let colW = (W - 24) / 3
        let ends = (0..<3).map { i in CGRect(x: 6 + CGFloat(i) * (colW + 6), y: 20, width: colW, height: H - 26) }
        let colors: [Color] = [Color(red: 0.2, green: 0.32, blue: 0.55), Color(red: 0.24, green: 0.24, blue: 0.28), Color(red: 0.45, green: 0.2, blue: 0.3)]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                window(colors[i], lerp(starts[i], ends[i], k))
            }
            if t > 0.12 && t < 0.32 {
                HStack(spacing: 6) {
                    ForEach([2, 3, 4], id: \.self) { n in
                        HStack(spacing: 1.5) {
                            ForEach(0..<n, id: \.self) { _ in RoundedRectangle(cornerRadius: 1.5).fill(n == 3 ? Brand.red : .white.opacity(0.6)) }
                        }
                        .frame(width: 34, height: 22)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(n == 3 ? 0.18 : 0.06)))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.75)))
                .position(x: W / 2, y: H / 2)
            }
        }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ k: Double) -> CGRect {
        let c = CGFloat(k)
        return CGRect(x: a.minX + (b.minX - a.minX) * c, y: a.minY + (b.minY - a.minY) * c,
                      width: a.width + (b.width - a.width) * c, height: a.height + (b.height - a.height) * c)
    }

    private var search: some View {
        let tr = AppLanguage.active == .tr
        let query = tr ? "rapor" : "report"
        let typed = Int(min(Double(query.count), max(0, (t - 0.25) / 0.06)))
        let text = String(query.prefix(typed))
        let showResults = typed >= 3
        let names = tr ? ["Rapor 2026.pdf", "rapor-taslak.docx", "Raporlar"] : ["Report 2026.pdf", "report-draft.docx", "Reports"]
        let icons = ["doc.richtext.fill", "doc.text.fill", "folder.fill"]
        return ZStack(alignment: .topLeading) {
            finderWindow
            if t > 0.16 && t < 0.92 {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14))
                        Text(text.isEmpty ? L("Ara") : text)
                            .font(.system(size: 15))
                            .foregroundStyle(text.isEmpty ? .white.opacity(0.4) : .white)
                        Spacer()
                        Text(L("Belgeler")).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    if showResults {
                        Divider().opacity(0.3)
                        ForEach(0..<3, id: \.self) { i in
                            HStack(spacing: 8) {
                                Image(systemName: icons[i]).font(.system(size: 12)).foregroundStyle(i == 2 ? .cyan : .white)
                                Text(names[i]).font(.system(size: 11))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(i == 0 ? Brand.red.opacity(0.8) : .clear).padding(.horizontal, 5))
                        }
                        .padding(.bottom, 4)
                    }
                }
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .position(x: W / 2, y: showResults ? 100 : 66)
            }
        }
    }

    private var finderWindow: some View {
        ZStack(alignment: .topLeading) {
            window(Color(red: 0.17, green: 0.17, blue: 0.19), CGRect(x: 60, y: 30, width: 400, height: 200))
            HStack(spacing: 18) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 3) {
                        Image(systemName: i % 2 == 0 ? "folder.fill" : "doc.fill").font(.system(size: 20))
                            .foregroundStyle(i % 2 == 0 ? .cyan : .white.opacity(0.8))
                        Capsule().fill(.white.opacity(0.3)).frame(width: 26, height: 3)
                    }
                }
            }
            .position(x: 260, y: 150)
        }
    }
}

// MARK: - Hakkında

struct AboutPage: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Missing").font(.system(size: 26, weight: .bold))
                    Text(L("Sürüm %@", version)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Text(L("Mac'te eksik kalanlar."))
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                para(L("Mac harika bir bilgisayar, ama her gün kullandığımız bazı şeyler ya hiç yok ya da yarım bırakılmış. ⌘Tab pencereleri değil uygulamaları gösterir. Ses çıkışını değiştirmek menülerde birkaç tıklama ister. Ekranı bölmek, uzun bir sayfanın görüntüsünü almak, Finder'da bir dosyayı adından anında bulmak… hepsi için ayrı bir uygulama aramak gerekir."))
                para(L("Missing, Mac'te unutulmuş ya da atlanmış bu küçük özellikleri tek, hafif bir uygulamada toplar. Her biri macOS'un kendi parçasıymış gibi davranır: aynı kısayollar, aynı cam görünüm, aynı sadelik."))
                para(L("İstemediğin özelliği kapatırsın; kapattığın şey için ne izin istenir ne de arka planda çalışır. Hiçbir şey internete gönderilmez."))
            }
            HStack(spacing: 10) {
                Button(L("GitHub'da aç")) { NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateConfig.repo)")!) }
                Text("Firewall Studio").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func para(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.75))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
