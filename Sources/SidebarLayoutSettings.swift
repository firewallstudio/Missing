import SwiftUI

// MARK: - Ayarlar: Dosyalar kenar çubuğu düzeni ve ⌘Tab'daki başlıklar
//
// Dosyalar'da kurulan kenar çubuğu (bölüm sırası, başlıklar ve içindeki klasörler) Ayarlar'da da görünür
// ve buradan düzenlenir. Değişiklikler açık Dosyalar pencerelerine anında yansır.

/// Dosyalar › Kenar çubuğu düzeni
struct SidebarLayoutEditor: View {
    @ObservedObject private var state = FilesSidebarState.shared
    @ObservedObject private var places = FilesPlaces.shared
    @State private var renaming: UUID?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let keys = state.order
            ForEach(Array(keys.enumerated()), id: \.element) { i, key in
                section(key, first: i == 0, last: i == keys.count - 1)
            }
            HStack {
                Button(L("Yeni başlık")) {
                    let id = state.addGroup()
                    state.editing = nil
                    text = L("Yeni başlık")
                    renaming = id
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func section(_ key: String, first: Bool, last: Bool) -> some View {
        let group = state.groups.first { $0.id.uuidString == key }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: group == nil ? "square.stack" : "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16)
                if let group, renaming == group.id {
                    TextField("", text: $text, onCommit: { commitRename(group.id) })
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button(L("Kaydet")) { commitRename(group.id) }
                } else {
                    Text(state.title(ofSection: key))
                        .font(.system(size: 12.5, weight: .bold))
                        .onTapGesture(count: 2) {
                            guard let group else { return }
                            text = group.title
                            renaming = group.id
                        }
                }
                if group == nil {
                    Text(L("hazır bölüm")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
                iconButton("chevron.up", L("Yukarı taşı"), disabled: first) { state.moveSection(key, by: -1, among: state.order) }
                iconButton("chevron.down", L("Aşağı taşı"), disabled: last) { state.moveSection(key, by: 1, among: state.order) }
                if let group {
                    iconButton("pencil", L("Yeniden adlandır")) { text = group.title; renaming = group.id }
                    iconButton("folder.badge.plus", L("Klasör ekle…")) { state.chooseFolders(for: group.id, window: NSApp.keyWindow) }
                    iconButton("trash", L("Başlığı sil")) { state.remove(group.id) }
                }
            }
            .padding(.vertical, 4)
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            folders(key, group: group)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func folders(_ key: String, group: SidebarGroup?) -> some View {
        if let group {
            let items = state.places(group)
            if items.isEmpty {
                Text(L("Boş: klasör eklemek için + düğmesine bas ya da Dosyalar'da başlığa sürükle"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 24).padding(.vertical, 3)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                folderRow(f) {
                    iconButton("chevron.up", L("Yukarı taşı"), disabled: i == 0) { state.moveItem(f.url, in: group.id, by: -1) }
                    iconButton("chevron.down", L("Aşağı taşı"), disabled: i == items.count - 1) { state.moveItem(f.url, in: group.id, by: 1) }
                    iconButton("xmark", L("Başlıktan kaldır")) { state.removeItem(f.url, from: group.id) }
                }
            }
        } else if key == "fav" || key == "pin" {
            let items = key == "fav" ? places.shownFavorites : places.pinned
            ForEach(items) { f in
                folderRow(f) {
                    if key == "pin" || places.isFinderFavorite(f.url) {
                        iconButton("xmark", L("Kenar çubuğundan kaldır")) { places.unpin(f.url) }
                    }
                }
            }
        } else {
            Text(key == "loc" ? L("Diskler, iCloud, ağ ve Çöp Sepeti") : L("Finder etiketleri"))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 24).padding(.vertical, 3)
        }
    }

    private func folderRow<Buttons: View>(_ f: SidebarPlace, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Image(systemName: f.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)
            Text(f.title).font(.system(size: 12)).lineLimit(1).help(f.url.path)
            Spacer()
            buttons()
        }
        .padding(.leading, 24)
        .padding(.vertical, 2)
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(disabled ? 0.2 : 0.65))
        .disabled(disabled)
        .help(help)
    }

    private func commitRename(_ id: UUID) {
        state.rename(id, text)
        renaming = nil
    }
}

/// ⌘Tab / ⌥Tab kenar çubuğu: Dosyalar'daki hangi başlıklar görünsün
struct SwitcherFilesSectionsPicker: View {
    let profile: Profile
    @ObservedObject private var state = FilesSidebarState.shared
    @ObservedObject private var places = FilesPlaces.shared
    @State private var tick = 0

    var body: some View {
        let sections = state.switcherSections()
        VStack(alignment: .leading, spacing: 6) {
            if sections.isEmpty {
                Text(L("Dosyalar'ın kenar çubuğunda henüz başlık yok."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(sections, id: \.key) { s in
                let on = Binding(get: { _ = tick; return Favorites.isFilesSectionShown(s.key, profile) },
                                 set: { Favorites.setFilesSection(s.key, shown: $0, profile); tick += 1 })
                HStack(spacing: 8) {
                    Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
                    Text(s.title).font(.system(size: 12.5, weight: .semibold))
                    Text(s.places.isEmpty ? L("boş") : s.places.prefix(4).map(\.title).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { on.wrappedValue.toggle() }
            }
            HStack(spacing: 10) {
                Button(L("Hepsi")) { for s in sections { Favorites.setFilesSection(s.key, shown: true, profile) }; tick += 1 }
                Button(L("Hiçbiri")) { for s in sections { Favorites.setFilesSection(s.key, shown: false, profile) }; tick += 1 }
                Spacer()
                Text(L("Sıra ve içerik Dosyalar ayarlarındaki düzenden gelir"))
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 2)
        }
        .padding(.leading, 4)
    }
}
