import SwiftUI

// MARK: - Özellikler paneli (Ayarlar › Özellikler)
//
// Her özellik canlı bir önizlemeyle bir kart. Kapatılan özelliğin Ayarlar'da, menü panelinde,
// kısayol listesinde ve izinlerde hiçbir izi kalmaz; sadece kullanılanlar görünür.

enum Feature: String, CaseIterable, Identifiable {
    case cmdTab, optTab, grouped, deepScan
    case audioKey, appAudio
    case capture, tile, blackout, monitorMenu
    case search, mouseNav, dockDrag

    var id: String { rawValue }

    enum Group: CaseIterable {
        case windows, sound, screen, finder
        var title: String {
            switch self {
            case .windows: return L("Pencereler")
            case .sound: return L("Ses")
            case .screen: return L("Ekran")
            case .finder: return L("Finder ve Dock")
            }
        }
        var features: [Feature] { Feature.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .cmdTab, .optTab, .grouped, .deepScan: return .windows
        case .audioKey, .appAudio: return .sound
        case .capture, .tile, .blackout, .monitorMenu: return .screen
        case .search, .mouseNav, .dockDrag: return .finder
        }
    }

    var title: String {
        switch self {
        case .cmdTab: return L("Pencere değiştirici")
        case .optTab: return L("Önizlemeli değiştir")
        case .grouped: return L("Gruplu görünüm")
        case .deepScan: return L("Pencereleri her zaman bul")
        case .audioKey: return L("Ses cihazı kısayolu")
        case .appAudio: return L("Uygulamaya göre ses cihazı")
        case .capture: return L("Ekran görüntüsü ve kayıt")
        case .tile: return L("Ekranı böl")
        case .blackout: return L("Monitörleri karart")
        case .monitorMenu: return L("Harici monitörler")
        case .search: return L("Dosya ara")
        case .mouseNav: return L("Finder'da fare tuşları")
        case .dockDrag: return L("Dock'a sürükle-bırak")
        }
    }

    var detail: String {
        switch self {
        case .cmdTab: return L("Uygulamalar değil pencereler, canlı önizlemeyle")
        case .optTab: return L("Kendi ayarlarıyla ikinci bir değiştirici")
        case .grouped: return L("⌘Tab'da Tarayıcılar · Projeler · Uygulamalar · Klasörler bölümleri")
        case .deepScan: return L("Diğer masaüstlerindeki ve tam ekrandaki pencereler de ⌘Tab'da")
        case .audioKey: return L("%@ ile çıkış cihazını değiştir", DeviceStore.shared.hotkeyChoice.symbol)
        case .appAudio: return L("Uygulama öne gelince ses ona atadığın cihaza geçer")
        case .capture: return L("Bulunduğun ekran, alan, kaydırmalı sayfa, MP4 kayıt")
        case .tile: return L("⌘< ya da pencereyi ekranın üstüne sürükle")
        case .blackout: return L("⌘⇧< ile tüm ekranları karart / geri aç")
        case .monitorMenu: return L("Menü çubuğunda parlaklık ve ses kaydırıcıları")
        case .search: return L("Finder öndeyken ⌘Space · Spotlight gibi, sadece dosya adları")
        case .mouseNav: return L("Farenin yan tuşlarıyla klasörlerde geri / ileri")
        case .dockDrag: return L("Dosyayı Dock'taki uygulamanın üstüne getirince hemen açılır")
        }
    }

    var icon: String {
        switch self {
        case .cmdTab: return "command"
        case .optTab: return "option"
        case .grouped: return "square.grid.3x1.below.line.grid.1x2"
        case .deepScan: return "scope"
        case .audioKey: return "speaker.wave.2.fill"
        case .appAudio: return "app.badge"
        case .capture: return "camera.viewfinder"
        case .tile: return "rectangle.split.3x1"
        case .blackout: return "moon.fill"
        case .monitorMenu: return "display.2"
        case .search: return "magnifyingglass"
        case .mouseNav: return "computermouse"
        case .dockDrag: return "dock.arrow.up.rectangle"
        }
    }

    /// Kartta oynayan sahne (Kısayollar sayfasındakiyle aynı)
    var demo: ShortcutDemo? {
        switch self {
        case .cmdTab: return .switcher
        case .optTab: return .preview
        case .audioKey: return .audio
        case .capture: return .area
        case .tile: return .tile
        case .blackout: return .blackout
        case .search: return .search
        default: return nil
        }
    }

    var isOn: Bool {
        switch self {
        case .cmdTab: return Profile.cmd.enabled
        case .optTab: return Profile.opt.enabled
        case .grouped: return Profile.allCases.contains { $0.enabled && $0.grouped && !$0.list }
        case .deepScan: return DeepScanScope.current != .off
        case .audioKey: return DeviceStore.shared.hotkeyEnabled
        case .appAudio: return DeviceStore.shared.autoSwitchByApp
        case .capture: return CaptureSettings.enabled
        case .tile: return TileSettings.enabled || SnapBarSettings.enabled
        case .blackout: return MonitorSettings.blackoutKey
        case .monitorMenu: return MonitorSettings.showInMenu
        case .search: return FileSearchSettings.enabled
        case .mouseNav: return FinderMouseNav.enabled
        case .dockDrag: return DockDragSettings.enabled
        }
    }

    /// Aç/kapat ve çalışan parçalara uygula
    func set(_ on: Bool, model: SettingsModel) {
        switch self {
        case .cmdTab:
            Profile.cmd.enabled = on
            model.onNativeTabChanged(); model.onPreviewsChanged()
        case .optTab:
            Profile.opt.enabled = on
            model.onPreviewsChanged()
        case .grouped:
            if on {
                let p: Profile = Profile.cmd.enabled ? .cmd : .opt
                p.list = false; p.grouped = true; p.previews = true
            } else {
                for p in Profile.allCases { p.grouped = false }
            }
            model.onPreviewsChanged()
        case .deepScan:
            DeepScanScope.current = on ? .browsers : .off
            model.onDeepScanChanged()
        case .audioKey:
            DeviceStore.shared.hotkeyEnabled = on
            model.onHotkeyChanged()
        case .appAudio:
            DeviceStore.shared.autoSwitchByApp = on
        case .capture:
            CaptureSettings.enabled = on
            model.onShortcutsChanged()
        case .tile:
            TileSettings.enabled = on
            SnapBarSettings.enabled = on
            model.onShortcutsChanged()
        case .blackout:
            MonitorSettings.blackoutKey = on
        case .monitorMenu:
            MonitorSettings.showInMenu = on
        case .search:
            FileSearchSettings.enabled = on
            model.onFileSearchChanged()
        case .mouseNav:
            FinderMouseNav.enabled = on
        case .dockDrag:
            DockDragSettings.enabled = on
            model.onDockDragChanged()
        }
        model.refresh()
    }

    /// Ayarlarda hangi sayfalar görünsün: kapalı özelliklerin sayfası hiç görünmez
    static func pageVisible(_ p: SettingsPage) -> Bool {
        switch p {
        case .switcher: return Feature.cmdTab.isOn || Feature.optTab.isOn
        case .screen: return Feature.capture.isOn || Feature.tile.isOn || Feature.monitorMenu.isOn
        case .quick: return [Feature.grouped, .deepScan, .search, .blackout, .mouseNav, .dockDrag].contains { $0.isOn }
        case .shortcuts: return ShortcutDemo.allCases.contains { $0.enabled }
        default: return true
        }
    }
}

// MARK: - Görünüm

struct FeaturesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Kullanmadığını kapat: kapattığın özellik ne izin ister ne çalışır, Ayarlar'da da görünmez."))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Feature.Group.allCases, id: \.self) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Text(g.title.uppercased(with: Locale.current))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, 2)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(g.features) { f in FeatureTile(feature: f, model: model) }
                    }
                }
            }
        }
    }
}

/// Tek özellik: üstte önizleme (sahne ya da büyük simge), altta ad, açıklama ve düğme
struct FeatureTile: View {
    let feature: Feature
    @ObservedObject var model: SettingsModel
    @State private var hover = false

    var body: some View {
        let on = feature.isOn
        VStack(alignment: .leading, spacing: 0) {
            preview(on: on)
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipped()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(feature.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                BrandToggle(isOn: Binding(get: { feature.isOn }, set: { feature.set($0, model: model) }))
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(on ? Brand.red.opacity(0.55) : Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(on ? 1 : 0.6)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: on)
    }

    @ViewBuilder private func preview(on: Bool) -> some View {
        if let d = feature.demo {
            // Üstüne gelince oynar; durduğunda sahnenin en anlatan karesi
            GeometryReader { geo in
                let k = geo.size.width / DemoStage.size.width
                Group {
                    if hover {
                        TimelineView(.animation) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
                            DemoScene(demo: d, t: t)
                        }
                    } else {
                        DemoScene(demo: d, t: 0.5)
                    }
                }
                .frame(width: DemoStage.size.width, height: DemoStage.size.height)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .saturation(on ? 1 : 0)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.14), Color(red: 0.07, green: 0.07, blue: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Brand.red.opacity(on ? 0.30 : 0.08), .clear], center: .center, startRadius: 0, endRadius: 90)
                Image(systemName: feature.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Özellik iste

enum FeatureRequest {
    static var url: URL {
        URL(string: "https://github.com/\(UpdateConfig.repo)/issues/new?template=feature_request.yml")!
    }
}

struct RequestPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: Brand.leaf).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Mac'te sana ne eksik?")).font(.system(size: 18, weight: .bold))
                    Text(L("Unutulmuş, yarım kalmış ya da hiç olmamış bir özellik mi var? Bize yaz, Missing'e ekleyelim."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                tip("lightbulb.fill", L("Neyi istediğini ve Mac'te şu an nasıl yaptığını yaz."))
                tip("keyboard", L("Bir kısayol aklındaysa onu da ekle."))
                tip("hand.thumbsup.fill", L("Başkasının önerisi hoşuna gittiyse 👍 ver: en çok istenenler önce gelir."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
            HStack(spacing: 10) {
                Button(L("Özellik öner")) { NSWorkspace.shared.open(FeatureRequest.url) }
                    .buttonStyle(BrandButtonStyle())
                Button(L("Önerilere bak")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateConfig.repo)/issues?q=label%3Aidea")!)
                }
                .buttonStyle(GlassButtonStyle())
            }
            Text(L("GitHub'da açılır; bir GitHub hesabı gerekir."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Brand.red).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
