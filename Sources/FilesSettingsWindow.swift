import SwiftUI

// MARK: - Dosyalar ayarları (Finder'daki Ayarlar gibi, ⌘,)
//
// Genel: yeni pencerelerin görünümü, tema, gizli dosyalar.
// Kenar çubuğu: Sık kullanılanlar, Konumlar ve Etiketler'de hangilerinin görüneceği.

@MainActor final class FilesSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = FilesSettingsWindow()
    private var window: NSWindow?
    private let state = FilesSettingsState()

    enum Tab: Hashable { case general, sidebar }

    func show(tab: Tab = .general) {
        state.tab = tab
        if window == nil {
            // Missing Ayarları'yla aynı kabuk: başlıksız koyu cam
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = L("Dosyalar Ayarları")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FilesSettingsView(state: state))
            w.delegate = self
            w.center()
            window = w
        }
        FilesPlaces.shared.rebuildLocations()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {}
}

@MainActor final class FilesSettingsState: ObservableObject {
    @Published var tab: FilesSettingsWindow.Tab = .general
}

private struct FilesSettingsView: View {
    @ObservedObject var state: FilesSettingsState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: Brand.leaf).resizable().frame(width: 18, height: 18)
                Text(L("Dosyalar Ayarları")).font(.system(size: 14, weight: .bold))
            }
            .padding(.top, 12)
            HStack(spacing: 4) {
                tabButton(.general, L("Genel"), "gearshape")
                tabButton(.sidebar, L("Kenar çubuğu"), "sidebar.left")
            }
            .padding(3)
            .background(Capsule().fill(.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
            .padding(.top, 12)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state.tab {
                    case .general: FilesGeneralSettings()
                    case .sidebar: FilesSidebarSettings()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .id(state.tab)
            }
        }
        .frame(width: 460, height: 600)
        .background(ZStack { GlassBlur(material: .hudWindow); Color.black.opacity(0.32) }.ignoresSafeArea())
        .foregroundStyle(Color.white)
        .tint(Brand.red)
        .environment(\.colorScheme, .dark)
    }

    private func tabButton(_ t: FilesSettingsWindow.Tab, _ title: String, _ icon: String) -> some View {
        let on = state.tab == t
        return Button { withAnimation(.easeOut(duration: 0.15)) { state.tab = t } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? Brand.red.opacity(0.85) : .clear))
                .foregroundStyle(.white.opacity(on ? 1 : 0.7))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Missing ayar kartı: başlık + içerik, katlanmaz
private struct FilesSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.red.opacity(0.85)))
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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

/// Simge + ad + Missing anahtarı
private struct FilesSettingsToggle<Leading: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            leading.font(.system(size: 13))
            Spacer(minLength: 8)
            BrandToggle(isOn: $isOn)
        }
    }
}

private struct FilesGeneralSettings: View {
    @ObservedObject private var themes = FilesThemeStore.shared
    @ObservedObject private var zoom = FilesGridZoom.shared
    @State private var viewMode = FilesSettings.viewMode
    @State private var showHidden = FilesSettings.showHidden

    var body: some View {
        FilesSettingsSection(L("Görünüm"), "square.grid.2x2") {
            Row(L("Yeni pencerelerde görünüm"), nil) {
                Picker("", selection: $viewMode) {
                    Text(L("Liste")).tag(FilesViewMode.list)
                    Text(L("Simgeler")).tag(FilesViewMode.grid)
                    Text(L("Sütunlar")).tag(FilesViewMode.columns)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .onChange(of: viewMode) { FilesSettings.viewMode = $0 }
            }
            Divider().opacity(0.4)
            Row(L("Simge boyutu"), nil) {
                FilesZoomSlider(value: $zoom.size, range: FilesGridZoom.range, tint: Brand.red, track: .white.opacity(0.18), knob: 16)
                    .frame(width: 200, height: 18)
            }
            Divider().opacity(0.4)
            Row(L("Tema"), nil) {
                Picker("", selection: $themes.theme) {
                    ForEach(FilesTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
        }
        FilesSettingsSection(L("Dosyalar"), "doc.on.doc") {
            ToggleRow(L("Gizli dosyaları göster"), nil, isOn: $showHidden)
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

/// Finder'daki Ayarlar › Kenar Çubuğu gibi: her öğe için bir onay kutusu
private struct FilesSidebarSettings: View {
    @ObservedObject private var places = FilesPlaces.shared

    var body: some View {
        FilesSettingsSection(L("Sık kullanılanlar"), "star") {
            ForEach(places.favorites) { p in
                if let key = p.hideKey { check(p.symbol, p.title, key) }
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
        }
        FilesSettingsSection(L("Etiketler"), "tag") {
            FilesSettingsToggle(isOn: binding("tags")) {
                Text(L("Etiketleri göster")).fontWeight(.medium)
            }
            if !places.tags.isEmpty { Divider().opacity(0.4) }
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
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 4)
    }

    private var cloudNames: String {
        let names = places.locations.filter { $0.hideKey == "cloud" }.map(\.title)
        return names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { places.isVisible(key) }, set: { places.setVisible(key, $0) })
    }

    private func check(_ symbol: String, _ title: String, _ key: String) -> some View {
        FilesSettingsToggle(isOn: binding(key)) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18)
                Text(title).lineLimit(1)
            }
        }
    }
}
