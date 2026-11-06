import SwiftUI

// MARK: - Özellikler paneli (Ayarlar › Özellikler)
//
// Her özellik canlı bir önizlemeyle bir kart. Kapatılan özelliğin Ayarlar'da, menü panelinde,
// kısayol listesinde ve izinlerde hiçbir izi kalmaz; sadece kullanılanlar görünür.

/// Ana özellikler: her biri bir kısayol. Alt ayarlar ve hızlı özellikler kendi sayfalarında.
enum Feature: String, CaseIterable, Identifiable {
    case switcher, audioKey, capture, tile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .switcher: return L("Pencere değiştirici")
        case .audioKey: return L("Ses cihazı kısayolu")
        case .capture: return L("Ekran görüntüsü ve kayıt")
        case .tile: return L("Ekranı böl")
        }
    }

    var keys: [String] {
        switch self {
        case .switcher: return ["⌘", "Tab"]
        case .audioKey: return DeviceStore.shared.hotkeyChoice == .cmdShift ? ["⌘", "⇧"] : ["⌘", "⇪"]
        case .capture: return ["⌘", "⇧", "3–6"]
        case .tile: return ["⌘", "<"]
        }
    }

    var detail: String {
        switch self {
        case .switcher: return L("Uygulamalar değil pencereler, canlı önizlemeyle")
        case .audioKey: return L("Tek tuşla sıradaki ses çıkışına geç")
        case .capture: return L("Bulunduğun ekran, alan, kaydırmalı sayfa, MP4 kayıt")
        case .tile: return L("⌘< ya da pencereyi ekranın üstüne sürükle")
        }
    }

    /// Kartta oynayan sahne (Kısayollar sayfasındakiyle aynı)
    var demo: ShortcutDemo {
        switch self {
        case .switcher: return .switcher
        case .audioKey: return .audio
        case .capture: return .area
        case .tile: return .tile
        }
    }

    var isOn: Bool {
        switch self {
        case .switcher: return Profile.cmd.enabled || Profile.opt.enabled
        case .audioKey: return DeviceStore.shared.hotkeyEnabled
        case .capture: return CaptureSettings.enabled
        case .tile: return TileSettings.enabled || SnapBarSettings.enabled
        }
    }

    /// Aç/kapat ve çalışan parçalara uygula
    func set(_ on: Bool, model: SettingsModel) {
        switch self {
        case .switcher:
            Profile.cmd.enabled = on
            Profile.opt.enabled = on
            model.onNativeTabChanged(); model.onPreviewsChanged()
        case .audioKey:
            DeviceStore.shared.hotkeyEnabled = on
            model.onHotkeyChanged()
        case .capture:
            CaptureSettings.enabled = on
            model.onShortcutsChanged()
        case .tile:
            TileSettings.enabled = on
            SnapBarSettings.enabled = on
            model.onShortcutsChanged()
        }
        model.refresh()
    }

    /// Ayarlarda hangi sayfalar görünsün: kapalı ana özelliğin sayfası hiç görünmez
    static func pageVisible(_ p: SettingsPage) -> Bool {
        switch p {
        case .switcher: return Feature.switcher.isOn
        case .shortcuts: return ShortcutDemo.allCases.contains { $0.enabled }
        default: return true
        }
    }
}

// MARK: - Görünüm

struct FeaturesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Kullanmadığını kapat: kapattığın özellik ne izin ister ne çalışır, Ayarlar'da da görünmez."))
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
                    KeyCombo(keys: feature.keys, size: 10.5)
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
