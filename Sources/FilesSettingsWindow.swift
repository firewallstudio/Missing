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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Dosyalar Ayarları")
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
        TabView(selection: $state.tab) {
            FilesGeneralSettings()
                .tabItem { Label(L("Genel"), systemImage: "gearshape") }
                .tag(FilesSettingsWindow.Tab.general)
            FilesSidebarSettings()
                .tabItem { Label(L("Kenar çubuğu"), systemImage: "sidebar.left") }
                .tag(FilesSettingsWindow.Tab.sidebar)
        }
        .padding(12)
        .frame(width: 440, height: 560)
    }
}

private struct FilesGeneralSettings: View {
    @ObservedObject private var themes = FilesThemeStore.shared
    @State private var viewMode = FilesSettings.viewMode
    @State private var showHidden = FilesSettings.showHidden

    var body: some View {
        Form {
            Picker(L("Yeni pencerelerde görünüm"), selection: $viewMode) {
                Text(L("Liste")).tag(FilesViewMode.list)
                Text(L("Simgeler")).tag(FilesViewMode.grid)
                Text(L("Sütunlar")).tag(FilesViewMode.columns)
            }
            .onChange(of: viewMode) { FilesSettings.viewMode = $0 }
            Picker(L("Tema"), selection: $themes.theme) {
                ForEach(FilesTheme.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L("Gizli dosyaları göster"), isOn: $showHidden)
                .onChange(of: showHidden) { v in
                    guard v != FilesSettings.showHidden else { return }
                    if let w = FilesManager.shared.windows.first { w.toggleHidden(nil) } else { FilesSettings.showHidden = v }
                }
        }
        .formStyle(.grouped)
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
        Form {
            Section(L("Sık kullanılanlar")) {
                ForEach(places.favorites) { p in
                    if let key = p.hideKey { check(p.symbol, p.title, key) }
                }
            }
            Section(L("Konumlar")) {
                check("internaldrive", L("Sabit diskler"), "disks")
                check("externaldrive", L("Harici diskler"), "external")
                check("cloud", L("Bulut depolama") + cloudNames, "cloud")
                check("house", FileManager.default.displayName(atPath: NSHomeDirectory()), "home")
                check("airplayaudio", "AirDrop", "airdrop")
                check("network", L("Ağ"), "network")
                check("trash", L("Çöp Sepeti"), "trash")
            }
            Section(L("Etiketler")) {
                Toggle(L("Etiketleri göster"), isOn: binding("tags"))
                ForEach(places.tags) { t in
                    Toggle(isOn: binding(FilesPlaces.tagKey(t))) {
                        HStack(spacing: 8) {
                            TagDot(tag: t, size: 10)
                            Text(t.name)
                        }
                    }
                    .disabled(!places.tagsVisible)
                }
            }
            Text(L("Sık kullanılanlar Finder'la aynıdır: buradan gizlemek yalnızca Dosyalar'ın kenar çubuğunu etkiler, Finder'dakini değil."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var cloudNames: String {
        let names = places.locations.filter { $0.hideKey == "cloud" }.map(\.title)
        return names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { places.isVisible(key) }, set: { places.setVisible(key, $0) })
    }

    private func check(_ symbol: String, _ title: String, _ key: String) -> some View {
        Toggle(isOn: binding(key)) {
            Label(title, systemImage: symbol)
        }
    }
}
