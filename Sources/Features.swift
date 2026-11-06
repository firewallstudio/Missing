import SwiftUI

// MARK: - Özellikler paneli (Ayarlar › Özellikler)
//
// Her sekme canlı bir önizlemeyle bir kart. Kapatılan sekmenin Ayarlar'da, menü panelinde,
// kısayol listesinde ve izinlerde hiçbir izi kalmaz; sadece kullanılanlar görünür.

/// Ayarlardaki sekmeler: her biri bir düğmeyle açılır/kapanır. Kapalı sekme kenar çubuğundan
/// kalkar ve içindeki her şey durur; açınca içindeki ayarlar kapatmadan önceki haline döner.
enum Feature: String, CaseIterable, Identifiable {
    case switcher, sound, screen, quick

    var id: String { rawValue }

    var page: SettingsPage {
        switch self {
        case .switcher: return .switcher
        case .sound: return .audio
        case .screen: return .screen
        case .quick: return .quick
        }
    }

    var title: String { page.title }
    var icon: String { page.icon }

    var detail: String {
        switch self {
        case .switcher: return L("⌘Tab · ⌥Tab · önizlemeler · tarayıcı profilleri")
        case .sound: return L("Ses kısayolu · uygulamaya göre ses cihazı")
        case .screen: return L("Ekran görüntüsü ve kayıt · ekranı böl · harici monitörler")
        case .quick: return L("Ekolayzır · dosya ara · karartma · Finder ve Dock")
        }
    }

    /// Kartta oynayan sahne (Kısayollar sayfasındakiyle aynı)
    var demo: ShortcutDemo {
        switch self {
        case .switcher: return .switcher
        case .sound: return .audio
        case .screen: return .tile
        case .quick: return .search
        }
    }

    /// Sekmenin içindeki ayarlar (kapatınca hepsi kapanır, açınca eski halleri geri gelir)
    private var items: [(key: String, get: () -> Bool, set: (Bool) -> Void, fresh: Bool)] {
        let store = DeviceStore.shared
        switch self {
        case .switcher:
            return [("cmd", { Profile.cmd.enabled }, { Profile.cmd.enabled = $0 }, true),
                    ("opt", { Profile.opt.enabled }, { Profile.opt.enabled = $0 }, true)]
        case .sound:
            return [("hotkey", { store.hotkeyEnabled }, { store.hotkeyEnabled = $0 }, true),
                    ("appAudio", { store.autoSwitchByApp }, { store.autoSwitchByApp = $0 }, true)]
        case .screen:
            return [("capture", { CaptureSettings.enabled }, { CaptureSettings.enabled = $0 }, true),
                    ("tile", { TileSettings.enabled }, { TileSettings.enabled = $0 }, true),
                    ("snapBar", { SnapBarSettings.enabled }, { SnapBarSettings.enabled = $0 }, true),
                    ("monitors", { MonitorSettings.showInMenu }, { MonitorSettings.showInMenu = $0 }, true)]
        case .quick:
            return [("eq", { EQSettings.enabled }, { EQSettings.enabled = $0 }, false),
                    ("search", { FileSearchSettings.enabled }, { FileSearchSettings.enabled = $0 }, true),
                    ("blackout", { MonitorSettings.blackoutKey }, { MonitorSettings.blackoutKey = $0 }, true),
                    ("grouped", { Profile.cmd.grouped }, { Profile.cmd.grouped = $0 }, false),
                    ("deepScan", { DeepScanScope.current != .off }, { DeepScanScope.current = $0 ? .browsers : .off }, true),
                    ("mouseNav", { FinderMouseNav.enabled }, { FinderMouseNav.enabled = $0 }, true),
                    ("finderTabs", { FinderTabsSettings.enabled }, { FinderTabsSettings.enabled = $0 }, true),
                    ("dockDrag", { DockDragSettings.enabled }, { DockDragSettings.enabled = $0 }, true)]
        }
    }

    private var flagKey: String { "section.\(rawValue).enabled" }
    private var savedKey: String { "section.\(rawValue).saved" }

    var isOn: Bool { UserDefaults.standard.object(forKey: flagKey) as? Bool ?? true }

    /// Sekmeyi aç/kapat ve çalışan parçalara uygula
    func set(_ on: Bool, model: SettingsModel) {
        guard on != isOn else { return }
        let d = UserDefaults.standard
        if on {
            let saved = d.dictionary(forKey: savedKey) as? [String: Bool] ?? [:]
            for it in items { it.set(saved[it.key] ?? it.fresh) }
        } else {
            var saved: [String: Bool] = [:]
            for it in items { saved[it.key] = it.get(); it.set(false) }
            d.set(saved, forKey: savedKey)
        }
        d.set(on, forKey: flagKey)
        // Çalışan parçalar yeni ayarlara uysun
        model.onNativeTabChanged()
        model.onPreviewsChanged()
        model.onHotkeyChanged()
        model.onShortcutsChanged()
        model.onFileSearchChanged()
        model.onDockDragChanged()
        model.onDeepScanChanged()
        model.onFinderTabsChanged()
        model.onEQChanged()
        model.refresh()
    }

    /// Kenar çubuğunda hangi sekmeler görünsün
    static func pageVisible(_ p: SettingsPage) -> Bool {
        if let f = Feature.allCases.first(where: { $0.page == p }) { return f.isOn }
        if p == .shortcuts { return ShortcutDemo.allCases.contains { $0.enabled } }
        if p == .power { return PowerProfiles.supported }   // sadece MacBook Pro 14" M4 Pro
        return true
    }
}

// MARK: - Görünüm

struct FeaturesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Kullanmadığın sekmeyi kapat: içindeki hiçbir şey çalışmaz, izin istemez ve Ayarlar'da görünmez. Açınca ayarların kaldığı gibi geri gelir."))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Feature.allCases) { f in FeatureTile(feature: f, model: model) }
            }
        }
    }
}

/// Tek özellik: üstte canlı sahne, altta kısayol, ad, açıklama ve düğme
struct FeatureTile: View {
    let feature: Feature
    @ObservedObject var model: SettingsModel
    @State private var hover = false

    var body: some View {
        let on = feature.isOn
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipped()
                .saturation(on ? 1 : 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: feature.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Brand.red : Color.white.opacity(0.12)))
                    Spacer()
                    BrandToggle(isOn: Binding(get: { feature.isOn }, set: { feature.set($0, model: model) }))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(feature.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                }
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

    /// Üstüne gelince oynar; durduğunda sahnenin en anlatan karesi
    private var preview: some View {
        GeometryReader { geo in
            let k = geo.size.width / DemoStage.size.width
            Group {
                if hover {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
                        DemoScene(demo: feature.demo, t: t)
                    }
                } else {
                    DemoScene(demo: feature.demo, t: 0.5)
                }
            }
            .frame(width: DemoStage.size.width, height: DemoStage.size.height)
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
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
