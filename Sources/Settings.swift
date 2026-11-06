import Cocoa
import SwiftUI
import ServiceManagement
import ApplicationServices

// MARK: - Ayar taşıma (GlassTab + AudioHop → Missing)

enum Migration {
    /// Eski iki uygulamanın ayarlarını bir kereye mahsus bu uygulamaya kopyalar.
    /// Uygulama sandbox'sız olduğu için diğer uygulamaların tercih dosyaları okunabilir.
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromGlassTabAudioHop") else { return }
        for domain in ["com.firewallstudio.glasstab", "com.audiohop.app"] {
            guard let old = d.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }
        d.set(true, forKey: "migratedFromGlassTabAudioHop")
    }
}

// MARK: - Ayarlar modeli

final class SettingsModel: ObservableObject {
    let store: DeviceStore
    var onNativeTabChanged: () -> Void = {}
    var onHotkeyChanged: () -> Void = {}
    var onPreviewsChanged: () -> Void = {}
    var onDeepScanChanged: () -> Void = {}
    /// ⌘⇧3/4/5/6 veya ⌘< açılıp kapandı → macOS kısayollarını güncelle
    var onShortcutsChanged: () -> Void = {}
    var onFileSearchChanged: () -> Void = {}
    /// Finder sekme şeridi açılıp kapandı
    var onFinderTabsChanged: () -> Void = {}
    /// Pil / şarj profilleri açılıp kapandı
    var onPowerChanged: () -> Void = {}
    /// Ekolayzır açılıp kapandı
    var onEQChanged: () -> Void = {}
    /// Genel › Kurulum: ilk kurulum ekranını yeniden aç
    var onOpenSetup: () -> Void = {}
    /// Dock'a sürükle-bırak hızlandırma açılıp kapandı
    var onDockDragChanged: () -> Void = {}
    /// Güncellemeyi yükle (kayıt sürüyorsa önce bitirilir)
    var onInstallUpdate: (ReleaseInfo?) -> Void = { _ in }

    /// Ayarlarda açık sayfa (menü panelinden belirli bir sayfaya gidilebilir)
    @Published var page: SettingsPage = .features

    init(store: DeviceStore) { self.store = store }

    /// UserDefaults'a yazan ayarlar için Binding; değişince ekranı yeniler.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { [weak self] value in
            self?.objectWillChange.send()
            set(value)
        })
    }

    func refresh() { objectWillChange.send() }

    var axTrusted: Bool { AXIsProcessTrusted() }
    var screenTrusted: Bool { CGPreflightScreenCaptureAccess() }
    var anyPreviews: Bool { Profile.allCases.contains { $0.enabled && $0.previews } }

    func profileBinding(_ p: Profile, _ key: String) -> Binding<Bool> {
        bind({ p.get(key) }, { [weak self] value in
            guard p.get(key) != value else { return }
            p.toggle(key)
            if key == "enabled" && p == .cmd { self?.onNativeTabChanged() }
            if key == "previews" || key == "enabled" { self?.onPreviewsChanged() }
        })
    }

    var loginBinding: Binding<Bool> {
        bind({ SMAppService.mainApp.status == .enabled }, { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSSound.beep() }
        })
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Ayarlar penceresi

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) { self.model = model }

    func show(page: SettingsPage? = nil) {
        if let page { model.page = page }
        let w = window ?? makeWindow()
        window = w
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("Missing Ayarları")
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView(model: model, store: model.store, updater: Updater.shared))
        w.center()
        return w
    }

    private var skipPermissionPrompt = false

    /// Kurulum ekranı açılırken: kapanışta izin sorma (kurulum kendisi soracak)
    func close() {
        skipPermissionPrompt = true
        window?.close()
        skipPermissionPrompt = false
    }

    // İzin durumları pencereye her dönüşte tazelensin
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    /// Ayarlarda izin isteyen bir özellik açıldıysa izni pencere kapanınca iste (kurulumda kapatılanlar için)
    func windowWillClose(_ notification: Notification) {
        guard Onboarding.done, !skipPermissionPrompt else { return }
        if Onboarding.needsAccessibility, !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if Onboarding.needsScreenRecording, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

// MARK: - Görünüm

enum SettingsPage: CaseIterable {
    case features, general, switcher, audio, screen, quick, permissions, shortcuts, request, versions, about

    var title: String {
        switch self {
        case .features: return L("Özellikler")
        case .general: return L("Genel")
        case .switcher: return L("Pencere Değiştirici")
        case .audio: return L("Ses")
        case .screen: return L("Ekran")
        case .quick: return L("Hızlı Özellikler")
        case .permissions: return L("İzinler")
        case .shortcuts: return L("Kısayollar")
        case .versions: return L("Sürümler")
        case .about: return L("Hakkında")
        case .request: return L("Özellik iste")
        }
    }

    var icon: String {
        switch self {
        case .features: return "square.grid.2x2.fill"
        case .general: return "gearshape.fill"
        case .switcher: return "rectangle.on.rectangle"
        case .audio: return "speaker.wave.2.fill"
        case .screen: return "camera.viewfinder"
        case .quick: return "bolt.fill"
        case .permissions: return "lock.shield.fill"
        case .shortcuts: return "keyboard"
        case .versions: return "clock.arrow.circlepath"
        case .about: return "leaf.fill"
        case .request: return "lightbulb.fill"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var store: DeviceStore
    @ObservedObject var updater: Updater
    private var page: SettingsPage { model.page }
    @ObservedObject private var monitors = Monitors.shared
    @State private var confirmRelease: ReleaseInfo?
    /// Sürümler sekmesinde büyütülmüş kutular
    @State private var expandedVersions = Set<String>()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text((Feature.pageVisible(page) ? page : .features).title)
                        .font(.system(size: 22, weight: .bold))
                        .padding(.bottom, 6)
                    pageContent
                }
                .padding(.horizontal, 26)
                .padding(.top, 40)
                .padding(.bottom, 26)
                .id(page)
            }
        }
        .frame(width: 800, height: 620)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow)
                Color.black.opacity(0.32)
            }
            .ignoresSafeArea()
        )
        .foregroundStyle(Color.white)
        .tint(Brand.red)
        .environment(\.colorScheme, .dark)
        .alert(L("Missing %@ yüklensin mi?", confirmRelease?.version ?? ""),
               isPresented: Binding(get: { confirmRelease != nil }, set: { if !$0 { confirmRelease = nil } })) {
            Button(L("Yükle ve yeniden aç")) {
                if let r = confirmRelease { model.onInstallUpdate(r) }
                confirmRelease = nil
            }
            Button(L("Vazgeç"), role: .cancel) { confirmRelease = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder private var pageContent: some View {
        // Kapatılan özelliğin sayfası açıksa Özellikler'e dön
        switch Feature.pageVisible(page) ? page : .features {
        case .features: FeaturesPage(model: model)
        case .request: RequestPage()
        case .general: generalTab
        case .switcher: windowsTab
        case .audio: audioTab
        case .screen: screenTab
        case .quick: quickTab
        case .permissions: permissionsTab
        case .shortcuts: ShortcutsPage()
        case .versions: versionsTab
        case .about: AboutPage()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: Brand.leaf).resizable().frame(width: 22, height: 22)
                Text("Missing").font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 40)
            .padding(.bottom, 14)
            ForEach(SettingsPage.allCases.filter { Feature.pageVisible($0) }, id: \.self) { p in
                if p == .general || p == .permissions || p == .request { Spacer().frame(height: 10) }
                sidebarItem(p)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(Color.black.opacity(0.18))
    }

    private func sidebarItem(_ p: SettingsPage) -> some View {
        let selected = (Feature.pageVisible(page) ? page : .features) == p
        return Button { model.page = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                Text(p.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Brand.red.opacity(0.85) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
    }

    // MARK: Ses

    @ViewBuilder private var audioTab: some View {
        let key = store.hotkeyChoice
        Card(title: L("Ses cihazı kısayolu"), icon: "keyboard",
             isOn: model.bind({ store.hotkeyEnabled }, { v in
                 store.hotkeyEnabled = v
                 model.onHotkeyChanged()
             }),
             subtitle: L("%@ ile çıkış cihazını değiştir", key.symbol)) {
            Row(L("Tuş kombinasyonu"),
                key == .cmdShift ? L("⌘ basılıyken ⇧'ye dokun. ⌘⇧4 gibi kısayolları bozmaz.") : "⌘ + Caps Lock") {
                Picker("", selection: model.bind({ store.hotkeyChoice }, { v in
                    store.hotkeyChoice = v
                    model.onHotkeyChanged()
                })) {
                    Text("⌘⇧").tag(HotkeyChoice.cmdShift)
                    Text("⌘⇪").tag(HotkeyChoice.cmdCaps)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            Divider().opacity(0.4)
            Row(L("%@ basınca", key.symbol), nil) {
                Picker("", selection: model.bind({ store.mode }, { store.mode = $0 })) {
                    Text(L("Sıradakine geç")).tag(HotkeyMode.cycle)
                    Text(L("Listeyi göster")).tag(HotkeyMode.panel)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            if store.mode == .panel {
                ToggleRow(L("⌘ bırakınca seç"), L("⌘+Tab gibi: ⌘'yi bırakınca vurgulu cihaz seçilir"),
                          isOn: model.bind({ store.selectOnRelease }, { store.selectOnRelease = $0 }))
            } else {
                ToggleRow(L("Geçişte bildirim göster"), L("Ekranın altında küçük cam bildirim"),
                          isOn: model.bind({ store.showHUD }, { store.showHUD = $0 }))
            }
            if key == .cmdCaps {
                ToggleRow(L("Caps Lock'u açık bırakma"), L("⌘⇪ sonrası Caps Lock eski haline döner"),
                          isOn: model.bind({ store.keepCapsLock }, { v in
                              store.keepCapsLock = v
                              model.onHotkeyChanged()
                          }))
            }
        }

        Card(title: L("Ses cihazları"), icon: "hifispeaker.2.fill", subtitle: store.current?.name) {
            Row(L("Listede görünenler"), nil) {
                Picker("", selection: model.bind({ store.panelShowAll }, { store.panelShowAll = $0 })) {
                    Text(L("Tümü")).tag(true)
                    Text(L("Seçtiklerim")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Divider().opacity(0.4)

            HStack {
                Text(L("Cihaz")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("%@ döngüsü", key.symbol)).frame(width: 82)
                Text(L("Listede")).frame(width: 60)
                Color.clear.frame(width: 26)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))

            if store.rows.isEmpty {
                Text(L("Henüz cihaz yok")).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(store.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol)
                        .frame(width: 22)
                        .foregroundStyle(row.isCurrent ? Color.accentColor : .white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.isCurrent ? L("Şu an çalıyor") : (row.isConnected ? L("Bağlı") : L("Bağlı değil · hatırlanıyor")))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("", isOn: Binding(get: { row.inCycle }, set: { _ in store.toggleCycle(row.id) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .frame(width: 82)
                    Toggle("", isOn: Binding(get: { store.panelShowAll || row.inPanel },
                                             set: { _ in togglePanel(row.id) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .frame(width: 60)

                    Group {
                        if !row.isConnected {
                            Button { store.forget(row.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.6))
                                .help(L("Bu cihazı unut"))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 26)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(row.isCurrent ? 0.10 : 0.03)))
                .opacity(row.isConnected ? 1 : 0.6)
            }

            if store.passthroughActive {
                Label(L("eqMac algılandı: ses eqMac üzerinden seçtiğin cihaza gidiyor."), systemImage: "slider.vertical.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }

        appAudioCard
        if Equalizer.available { eqCard }
    }

    // MARK: Uygulamaya göre ses

    private func appInfo(_ bid: String) -> (name: String, icon: NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (bid, nil)
    }

    @ViewBuilder private var appAudioCard: some View {
        Card(title: L("Uygulamaya göre ses cihazı"), icon: "app.badge",
             isOn: model.bind({ store.autoSwitchByApp }, { store.autoSwitchByApp = $0 }),
             subtitle: L("Uygulama öne gelince ses ona atadığın cihaza geçer")) {

            let mapped = store.appAudio.keys.sorted { appInfo($0).name.localizedCaseInsensitiveCompare(appInfo($1).name) == .orderedAscending }
            if mapped.isEmpty {
                Text(L("Henüz atama yok."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(mapped, id: \.self) { bid in
                let info = appInfo(bid)
                HStack(spacing: 10) {
                    if let icon = info.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app").frame(width: 24, height: 24)
                    }
                    Text(info.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.appAudio[bid] ?? "" },
                        set: { store.setAppDevice($0.isEmpty ? nil : $0, bundleID: bid) })) {
                        Text(L("Atama yok")).tag("")
                        ForEach(store.rows) { row in
                            Text(row.isConnected ? row.name : L("%@ (bağlı değil)", row.name)).tag(row.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    Button { store.setAppDevice(nil, bundleID: bid) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                        .help(L("Atamayı kaldır"))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.03)))
            }

            let candidates = NSWorkspace.shared.runningApplications
                .filter { app -> Bool in
                    guard app.activationPolicy == .regular, let bid = app.bundleIdentifier else { return false }
                    if bid == Bundle.main.bundleIdentifier { return false }
                    return store.appAudio[bid] == nil
                }
                .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            Menu {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? (app.bundleIdentifier ?? "?")) {
                        if let bid = app.bundleIdentifier, let uid = store.current?.uid ?? store.rows.first(where: \.isConnected)?.id {
                            store.setAppDevice(uid, bundleID: bid)
                        }
                    }
                }
            } label: {
                Label(L("Açık bir uygulama ekle"), systemImage: "plus.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(candidates.isEmpty)
        }
    }

    // MARK: Ekolayzır

    @ViewBuilder private var eqCard: some View {
        let eq = Equalizer.shared
        Card(title: L("Ekolayzır"), icon: "slider.vertical.3",
             isOn: model.bind({ EQSettings.enabled }, { v in
                 EQSettings.enabled = v
                 model.onEQChanged()
             }),
             subtitle: L("Sistemin sesi için 10 bant; eqMac gerekmez")) {
            if let err = eq.lastError, EQSettings.enabled {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            Row(L("Ön kazanç"), L("Bütün sesi yükseltir ya da kısar. Bantları çok artırdıysan biraz düşür, ses bozulmasın.")) {
                HStack(spacing: 8) {
                    Slider(value: model.bind({ EQSettings.preamp }, { v in
                        EQSettings.preamp = (v * 2).rounded() / 2
                        eq.settingsChanged()
                    }), in: -12...12)
                    .frame(width: 200)
                    Text(Self.db(EQSettings.preamp))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 58, alignment: .trailing)
                }
            }
            EQBandsView(model: model)
            HStack(spacing: 8) {
                ForEach(EQSettings.presets.indices, id: \.self) { i in
                    let p = EQSettings.presets[i]
                    Button(p.name) {
                        EQSettings.gains = p.gains
                        eq.settingsChanged()
                        model.refresh()
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                Spacer()
                Button(L("Sıfırla")) {
                    EQSettings.gains = Array(repeating: 0, count: EQSettings.frequencies.count)
                    EQSettings.preamp = 0
                    eq.settingsChanged()
                    model.refresh()
                }
                .buttonStyle(GlassButtonStyle())
            }
            note(L("İlk açılışta macOS ses kaydı izni sorar: ekolayzır sistemin sesini işleyip hoparlöre geri verir, hiçbir şey kaydedilmez."))
        }
    }

    static func db(_ v: Double) -> String {
        let s = String(format: "%.1f dB", v)
        return v > 0.05 ? "+" + s : s
    }

    /// "Tümü" modundayken bir cihazın işaretini kaldırmak: o cihaz hariç hepsini seçili yap.
    private func togglePanel(_ uid: String) {
        if store.panelShowAll {
            for k in store.knownDevices where k.uid != uid && !store.isInPanel(k.uid) { store.togglePanel(k.uid) }
            if store.isInPanel(uid) { store.togglePanel(uid) }
            store.panelShowAll = false
        } else {
            store.togglePanel(uid)
        }
        model.refresh()
    }

    // MARK: Pencereler

    @ViewBuilder private var windowsTab: some View {
        ForEach(Profile.allCases, id: \.self) { p in
            Card(title: p.title, icon: p == .cmd ? "command" : "option",
                 isOn: model.profileBinding(p, "enabled"),
                 subtitle: p == .cmd ? L("Kapatınca macOS'un kendi ⌘Tab'ı geri gelir") : L("Önizlemeli pencere değiştirici")) {
                Row(L("Görünüm"), p.list ? L("Alt alta satırlar, ses listesi gibi")
                                    : p.grouped ? L("Yan yana bölümler: Tarayıcılar · Projeler · Geliştirme · Uygulamalar · Klasörler")
                                    : L("Kartlar yan yana")) {
                    Picker("", selection: model.bind({ p.list ? 1 : (p.grouped ? 2 : 0) }, { v in
                        p.list = v == 1
                        p.grouped = v == 2
                        if v == 2 { p.previews = true }   // gruplu görünüm önizlemelerle tasarlandı
                    })) {
                        Text(L("Izgara")).tag(0)
                        Text(L("Liste")).tag(1)
                        Text(L("Gruplu")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                .disabled(!p.enabled)
                ToggleRow(L("Pencere önizlemeleri"), p.list ? L("Liste görünümünde kullanılmaz") : L("Ekran Kaydı izni gerekir (macOS 14+)"),
                          isOn: model.profileBinding(p, "previews"))
                    .disabled(!p.enabled || p.list)
                ToggleRow(L("Küçültülmüş pencereler"), L("Küçültülmüş ve penceresiz uygulamaları da göster"),
                          isOn: model.profileBinding(p, "showMinimized"))
                    .disabled(!p.enabled)
                Divider().opacity(0.4)
                Row(L("Hangi uygulamalar"), L("Sadece seçilen uygulamanın pencereleri arasında geçer (ör. tüm Chrome pencereleri). Panel açıkken A ile değiştirebilirsin.")) {
                    Picker("", selection: model.bind({ p.appFilter }, { p.appFilter = $0 })) {
                        Text(L("Tüm uygulamalar")).tag("")
                        ForEach(filterChoices(p)) { c in Text(c.name).tag(c.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                .disabled(!p.enabled)
                Divider().opacity(0.4)
                sidebarRows(p)
                    .disabled(!p.enabled)
            }
        }
    }

    // MARK: Hızlı özellikler

    @ViewBuilder private var quickTab: some View {
        Card(title: L("Gruplu görünüm"), icon: "square.grid.3x1.below.line.grid.1x2",
             isOn: model.bind({ Profile.allCases.contains { $0.grouped && !$0.list } }, { v in
                 if v {
                     Profile.cmd.list = false; Profile.cmd.grouped = true; Profile.cmd.previews = true
                 } else {
                     for p in Profile.allCases { p.grouped = false }
                 }
                 model.onPreviewsChanged()
             }),
             subtitle: L("⌘Tab'da Tarayıcılar · Projeler · Uygulamalar · Klasörler bölümleri")) {
            groupedRows
        }
        Card(title: L("Finder sekmeleri"), icon: "rectangle.topthird.inset.filled",
             isOn: model.bind({ FinderTabsSettings.enabled }, { v in
                 FinderTabsSettings.enabled = v
                 model.onFinderTabsChanged()
             }),
             subtitle: L("Windows'taki gibi: sekmeler soldan, belli genişlikte; çoğalınca daralır")) {
            note(L("Finder'ın sekme çubuğunda sekmeler tüm genişliğe yayılmaz; her biri en fazla 220 pt olur, çoğaldıkça daralır, sığmayınca yana kayar. Seçili sekmenin altında kırmızı çizgi, üstüne gelince kapatma düğmesi, sonunda + ile yeni sekme."))
        }
        Card(title: L("Finder'da fare tuşları"), icon: "computermouse",
             isOn: model.bind({ FinderMouseNav.enabled }, { FinderMouseNav.enabled = $0 }),
             subtitle: L("Farenin yan tuşlarıyla klasörlerde geri / ileri")) {
            note(L("Farenin 4. ve 5. tuşları Finder öndeyken klasörlerde geri ve ileri gider."))
        }
        Card(title: L("Dock'a sürükle-bırak"), icon: "dock.arrow.up.rectangle",
             isOn: model.bind({ DockDragSettings.enabled }, { v in
                 DockDragSettings.enabled = v
                 model.onDockDragChanged()
             }),
             subtitle: L("Dosyayı Dock'taki uygulamanın üstüne getirince hemen açılır")) {
            note(L("Bir dosyayı sürüklerken Dock'taki uygulamanın üstüne gelince beklemeden öne gelir (kapalıysa açılır); dosyayı doğrudan penceresine bırakırsın. ⌘Tab panelinde bir uygulamanın üstüne bırakırsan dosya o uygulamayla açılır."))
        }
        Card(title: L("Pencereleri her zaman bul"), icon: "scope",
             isOn: model.bind({ DeepScanScope.current != .off }, { v in
                 DeepScanScope.current = v ? .browsers : .off
                 model.onDeepScanChanged()
             }),
             subtitle: L("Diğer masaüstlerindeki ve tam ekrandaki pencereler de ⌘Tab'da")) {
            deepScanRows
        }
        Card(title: L("Dosya ara"), icon: "magnifyingglass",
             isOn: model.bind({ FileSearchSettings.enabled }, { v in
                 FileSearchSettings.enabled = v
                 model.onFileSearchChanged()
             }),
             subtitle: L("Finder öndeyken ⌘Space · Spotlight gibi, sadece dosya adları")) {
            Row(L("Dosya indeksi"), L("Dosya adları sadece bu Mac'te tutulur; içerikler okunmaz. Tüm diskleri görmek için Tam Disk Erişimi ver.")) {
                HStack(spacing: 10) {
                    Button(L("Tam Disk Erişimi")) { SettingsModel.open("Privacy_AllFiles") }
                    Button(L("Yeniden tara")) { FileIndex.shared.rebuild() }
                }
            }
            note(L("Başka bir uygulama öndeyken ⌘Space her zamanki gibi Spotlight'ı açar."))
            note(L("Finder'ın sağ üstteki arama kutusuna yazınca da kutunun altında aynı anında sonuçlar çıkar."))
        }
        Card(title: L("Monitörleri karart"), icon: "moon.fill",
             isOn: model.bind({ MonitorSettings.blackoutKey }, { MonitorSettings.blackoutKey = $0 }),
             subtitle: L("⌘⇧< ile tüm ekranları karart / geri aç")) {
            ToggleRow(L("Karartınca klavyeyi kilitle"), L("Ekranlar karanlıkken tuşlar hiçbir pencereye gitmez; sadece ⌘⇧< ile geri açarsın"),
                      isOn: model.bind({ MonitorSettings.lockKeysWhenDark }, { MonitorSettings.lockKeysWhenDark = $0 }))
        }
    }

    @ViewBuilder private var deepScanRows: some View {
            Row(L("Kapsam"), L("Diğer masaüstlerindeki, tam ekrandaki ve arkada kalan pencereleri de kesin gösterir (Chrome profilleri dahil). Arka planda, sadece masaüstü değişince ve uygulama açılınca güncellenir.")) {
                Picker("", selection: model.bind({ DeepScanScope.current }, { v in
                    DeepScanScope.current = v
                    model.onDeepScanChanged()
                })) {
                    Text(L("Tarayıcılar")).tag(DeepScanScope.browsers)
                    Text(L("Tümü")).tag(DeepScanScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
            if DeepScanScope.current == .browsers {
                Divider().opacity(0.4)
                Row(L("Eklenen uygulamalar"), L("Tarayıcıların yanında bu uygulamaların pencereleri de her zaman bulunur")) {
                    Menu(L("Ekle")) {
                        ForEach(runningApps().filter { a in
                            !DeepScanScope.extraApps.contains(a.id) && !DeepScanScope.browserPrefixes.contains { a.id.hasPrefix($0) }
                        }) { a in
                            Button(a.name) {
                                DeepScanScope.extraApps.append(a.id)
                                model.onDeepScanChanged(); model.refresh()
                            }
                        }
                    }
                    .frame(width: 110)
                }
                let extra = DeepScanScope.extraApps
                if extra.isEmpty {
                    Text(L("Henüz uygulama eklemedin.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                } else {
                    FlowChips(items: extra.map { bid in
                        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName
                            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                            ?? bid
                        return ChipItem(id: bid, name: name)
                    }) { bid in
                        DeepScanScope.extraApps.removeAll { $0 == bid }
                        model.onDeepScanChanged(); model.refresh()
                    }
                }
            }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Kenar çubuğu: bu kısayola özel (⌘Tab ve ⌥Tab ayrı ayrı)
    @ViewBuilder private func sidebarRows(_ p: Profile) -> some View {
        ToggleRow(L("Kenar çubuğu: sık kullanılan klasörlerim"), L("Panelin en sağında, aşağıda eklediğin klasörler"),
                  isOn: model.bind({ Favorites.showOwn(p) }, { Favorites.setShowOwn($0, p) }))
        ToggleRow(L("Kenar çubuğu: Finder favorileri"), L("Finder'ın kenar çubuğundaki Favoriler, Finder'daki gibi listelenir"),
                  isOn: model.bind({ Favorites.showFinder(p) }, { Favorites.setShowFinder($0, p) }))
        if Favorites.showOwn(p) {
            Row(L("Klasörler"), L("Tıklayınca Finder'da açılır")) {
                Button(L("Klasör ekle…")) { addFavoriteFolders(p) }
            }
            let paths = Favorites.folders(p)
            if paths.isEmpty {
                Text(L("Henüz klasör eklemedin.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else {
                FlowChips(items: paths.map { ChipItem(id: $0, name: FileManager.default.displayName(atPath: $0)) }) { path in
                    Favorites.remove(path, from: p); model.refresh()
                }
            }
        }
    }

    /// Tarayıcı profilleri: rozette yazacak adı buradan değiştir (boş bırakırsan otomatik ad)
    @ViewBuilder private var browserProfilesCard: some View {
        let browsers = BrowserProfiles.shared.browsersForSettings().filter { $0.profiles.count > 1 }
        if !browsers.isEmpty {
            Card(title: L("Tarayıcı profilleri"), icon: "person.crop.circle") {
                Text(L("⌘Tab'daki profil rozetinde yazacak ad. Boş bırakırsan tarayıcıdaki profil adı kullanılır."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                ForEach(browsers) { b in
                    browserSection(b)
                }
                HStack {
                    Spacer()
                    Button(L("Tanı bilgisini kopyala")) {
                        let s = BrowserProfiles.shared.diagnostics()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                    .help(L("Rozet yanlışsa bunu kopyalayıp gönder: pencerelerin düğme yazılarını içerir (e-posta yok)"))
                }
            }
        }
    }

    @ViewBuilder private func browserSection(_ b: BrowserProfiles.BrowserEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(b.app).font(.system(size: 12, weight: .bold)).padding(.top, 4)
            ForEach(b.profiles, id: \.id) { (p: BrowserProfiles.Profile) in
                profileRow(p)
            }
        }
    }

    private func profileRow(_ p: BrowserProfiles.Profile) -> some View {
        let label: Binding<String> = model.bind({ BrowserProfiles.labels[p.id] ?? "" },
                                                { (v: String) in BrowserProfiles.setLabel(v, for: p) })
        let info = [p.accountNames.first, p.email.isEmpty ? nil : p.email].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Circle().fill(Color(nsColor: p.color ?? .controlAccentColor)).frame(width: 9, height: 9)
            TextField(p.autoName, text: label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Text(info)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: Harici monitörler (parlaklık / ses)

    @ViewBuilder private var monitorsCard: some View {
        if PowerProfiles.supported { powerCard }
        Card(title: L("Harici monitörler"), icon: "display.2",
             isOn: model.bind({ MonitorSettings.showInMenu }, { MonitorSettings.showInMenu = $0 }),
             subtitle: L("Menü çubuğunda parlaklık ve ses kaydırıcıları")) {
            if !monitors.ddcAvailable {
                Text(L("Bu Mac'te monitör kontrolü desteklenmiyor (Apple Silicon gerekir)."))
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            } else if monitors.displays.isEmpty {
                Text(L("Bağlı harici monitör yok"))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(monitors.displays) { d in monitorRow(d) }
            }
            HStack {
                Spacer()
                Button { monitors.refresh(rescan: true) } label: { Label(L("Yenile"), systemImage: "arrow.clockwise") }
            }
        }
        .onAppear { monitors.refresh() }
    }

    private func monitorRow(_ d: Monitors.Display) -> some View {
        let id = d.id
        let bright = Binding<Double>(get: { monitors.displays.first { $0.id == id }?.brightness ?? 0 },
                                     set: { monitors.setBrightness($0, for: id) })
        let vol = Binding<Double>(get: { monitors.displays.first { $0.id == id }?.volume ?? 0 },
                                  set: { monitors.setVolume($0, for: id) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                Text(d.name).font(.system(size: 13, weight: .semibold))
                if !d.ddc {
                    Text(L("desteklemiyor")).font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").frame(width: 18).foregroundStyle(.white.opacity(0.7))
                Slider(value: bright, in: 0...100)
                Text("\(Int(bright.wrappedValue))").font(.system(size: 11, design: .monospaced)).frame(width: 30, alignment: .trailing)
            }
            .disabled(!d.ddc)
            if d.volumeSupported {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill").frame(width: 18).foregroundStyle(.white.opacity(0.7))
                    Slider(value: vol, in: 0...100)
                    Text("\(Int(vol.wrappedValue))").font(.system(size: 11, design: .monospaced)).frame(width: 30, alignment: .trailing)
                }
                .disabled(!d.ddc)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.05)))
    }

    // MARK: Pil / şarj profilleri (sadece MacBook Pro 14" M4 Pro)

    @ViewBuilder private var powerCard: some View {
        let power = PowerProfiles.shared
        Card(title: L("Pil ve şarj profilleri"), icon: "battery.75percent",
             isOn: model.bind({ PowerProfileSettings.enabled }, { v in
                 PowerProfileSettings.enabled = v
                 model.onPowerChanged()
             }),
             subtitle: L("Fişten çekince tasarruf, şarja takınca tam performans")) {
            ToggleRow(L("Şarj takılıp çıkarılınca otomatik geç"), nil,
                      isOn: model.bind({ PowerProfileSettings.auto }, { PowerProfileSettings.auto = $0 }))
            Divider().opacity(0.4)
            ForEach([PowerProfile.saver, .performance], id: \.self) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(power.current == p ? Brand.red : Color.white.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p == .saver ? L("Pilde: Tasarruf") : L("Şarjda: Performans")).font(.system(size: 13, weight: .medium))
                        Text(p.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button(L("Şimdi uygula")) { power.apply(p, manual: true); model.refresh() }
                }
            }
            Divider().opacity(0.4)
            Row(L("Düşük / yüksek güç modu"), L("Bir kez kurulur: pilde düşük güç, şarjda yüksek güç; menüden elle geçişte de güç modu değişir. Missing'e sadece güç modunu değiştirme izni verilir. Yönetici şifresini macOS kendi penceresinde sorar.")) {
                if power.fullyConfigured {
                    Label(L("Ayarlı"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.green)
                } else {
                    Button(L("Ayarla…")) { power.configurePowerModes(); model.refresh() }
                }
            }
        }
    }

    private func addFavoriteFolders(_ profile: Profile) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = L("Ekle")
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK {
            Favorites.add(p.urls, to: profile)
            model.refresh()
        }
    }

    // MARK: Gruplu görünüm ayarları

    @ViewBuilder private var groupedRows: some View {
            ToggleRow(L("Klasör adlarını büyük göster"), L("Finder pencerelerinde önizleme yerine klasörün adı"),
                      isOn: model.bind({ GroupSettings.bigFolderNames }, { GroupSettings.bigFolderNames = $0 }))
            ToggleRow(L("Proje adlarını göster"), L("DaVinci, Adobe, Final Cut, Logic, Ableton, Blender… pencere başlığından proje adı okunur ve önizlemenin üstüne yazılır"),
                      isOn: model.bind({ GroupSettings.showProjectNames }, { GroupSettings.showProjectNames = $0 }))
            Divider().opacity(0.4)
            Row(L("Proje uygulamaları"), L("Otomatik algılananlar ve eklediklerin. Bunlar Projeler bölümünde görünür.")) {
                Menu(L("Ekle")) {
                    ForEach(runningApps().filter { !GroupSettings.isProjectApp($0.id) }) { a in
                        Button(a.name) { GroupSettings.addProjectApp(a.id); model.objectWillChange.send() }
                    }
                }
                .frame(width: 110)
            }
            let current = projectAppList()
            if current.isEmpty {
                Text(L("Şu an açık proje uygulaması yok. DaVinci, Adobe gibi uygulamalar açılınca otomatik algılanır."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else {
                FlowChips(items: current.map { ChipItem(id: $0.id, name: $0.name) }) { bid in
                    GroupSettings.removeProjectApp(bid); model.objectWillChange.send()
                }
            }
    }

    /// Açık uygulamalar (paket kimliği + ad), ada göre sıralı
    private func runningApps() -> [AppChoice] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { AppChoice(id: $0, name: a.localizedName ?? $0) } }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Şu an Projeler bölümüne giren uygulamalar: açık olanlar + kullanıcının eklediği (kapalı olsa da)
    private func projectAppList() -> [AppChoice] {
        var list = runningApps().filter { GroupSettings.isProjectApp($0.id) }
        let ids = Set(list.map(\.id))
        for bid in GroupSettings.addedProjectApps where !ids.contains(bid) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bid
            list.append(AppChoice(id: bid, name: name))
        }
        return list
    }

    /// Açık uygulamalar (+ kayıtlı seçim kapalı bir uygulamaysa o da), ada göre sıralı
    private struct AppChoice: Identifiable { let id: String; let name: String }

    private func filterChoices(_ p: Profile) -> [AppChoice] {
        var list: [AppChoice] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { AppChoice(id: $0, name: a.localizedName ?? $0) } }
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let cur = p.appFilter
        if !cur.isEmpty, !seen.contains(cur) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cur)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? cur
            list.insert(AppChoice(id: cur, name: name), at: 0)
        }
        return list
    }

    private func shortcut(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 190, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }

    // MARK: Ekran (bölme + çekim)

    @ViewBuilder private var screenTab: some View {
        Card(title: L("Ekranı böl"), icon: "rectangle.split.3x1",
             isOn: model.bind({ TileSettings.enabled }, { v in
                 TileSettings.enabled = v
                 model.onShortcutsChanged()
             }),
             subtitle: L("⌘< ile pencereleri bölmelere yerleştir")) {
            if TileSettings.enabled {
                Row(L("Düzen seçince"), TileSettings.autoFill
                    ? L("Bölmeler bulunduğun ekrandaki en son kullanılan pencerelerle kendiliğinden dolar")
                    : L("Hangi pencerenin hangi bölmeye gideceğini sen seçersin")) {
                    Picker("", selection: model.bind({ TileSettings.autoFill }, { TileSettings.autoFill = $0 })) {
                        Text(L("Ben seçeyim")).tag(false)
                        Text(L("Son kullanılanlar")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                Row(L("Hedef monitör"), L("Birden fazla monitör varken. Panelde Tab ile her zaman değiştirebilirsin.")) {
                    Picker("", selection: model.bind({ TileSettings.askMonitor }, { TileSettings.askMonitor = $0 })) {
                        Text(L("Farenin olduğu")).tag(false)
                        Text(L("Her seferinde sor")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                ToggleRow(L("Sürükleyince üstte bölme çubuğu"),
                          L("Pencereyi başlığından tutup sürükleyince ekranın üst ortasında küçük bir çıkıntı belirir. Oraya götür, düzen ve bölmeyi seç, bırak: pencere oraya yerleşir (Windows'taki gibi)."),
                          isOn: model.bind({ SnapBarSettings.enabled }, { SnapBarSettings.enabled = $0 }))
                Row(L("Pencere arası boşluk"), "\(Int(TileSettings.gap)) pt") {
                    Slider(value: model.bind({ TileSettings.gap }, { TileSettings.gap = $0 }), in: 0...24, step: 2)
                        .frame(width: 200)
                }
            }
        }

        Card(title: L("Ekran görüntüsü ve kayıt"), icon: "camera.viewfinder",
             isOn: model.bind({ CaptureSettings.enabled }, { v in
                 CaptureSettings.enabled = v
                 model.onShortcutsChanged()
             }),
             subtitle: L("⌘⇧3 · ⌘⇧4 · ⌘⇧5 · ⌘⇧6")) {
            if CaptureSettings.enabled {
                captureRow(.screen, key: "⌘⇧3", title: L("Bu monitörün görüntüsü"), detail: L("Sadece farenin olduğu monitör"),
                           isOn: model.bind({ CaptureSettings.screenKey }, { v in CaptureSettings.screenKey = v; model.onShortcutsChanged() }))
                captureRow(.area, key: "⌘⇧4", title: L("Ekran alıntısı"), detail: L("Alan seç; Space ile pencere seçimi"),
                           isOn: model.bind({ CaptureSettings.areaKey }, { v in CaptureSettings.areaKey = v; model.onShortcutsChanged() }))
                captureRow(.scroll, key: "⌘⇧6", title: L("Kaydırmalı görüntü"), detail: L("Alanı seç, sayfa kendiliğinden kayar · Esc bitirir"),
                           isOn: model.bind({ CaptureSettings.scrollKey }, { v in CaptureSettings.scrollKey = v; model.onShortcutsChanged() }))
                captureRow(.video, key: "⌘⇧5", title: L("Ekran kaydı (MP4 · H.264)"), detail: L("Çekim paleti; kayıt sırasında ⌘⇧5 durdurur"),
                           isOn: model.bind({ CaptureSettings.videoKey }, { v in CaptureSettings.videoKey = v; model.onShortcutsChanged() }))
                folderRow(.window, title: L("Pencere görüntüleri"), detail: L("⌘⇧5 › Sadece pencere"))
                folderRow(.windowVideo, title: L("Pencere kayıtları"), detail: L("⌘⇧5 › Pencereyi kaydet"))
                HStack {
                    Spacer()
                    Button(L("Hepsini tek klasöre kaydet…")) { pickFolderForAll() }
                }
                Divider().opacity(0.4)
                ToggleRow(L("Panoya da kopyala"), L("Görüntüler kaydedilirken panoya da alınır"),
                          isOn: model.bind({ CaptureSettings.copyToClipboard }, { CaptureSettings.copyToClipboard = $0 }))
                ToggleRow(L("Deklanşör sesi"), nil,
                          isOn: model.bind({ CaptureSettings.playSound }, { CaptureSettings.playSound = $0 }))
                if CaptureSettings.playSound {
                    Row(L("Deklanşör ses seviyesi"), nil) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                            Slider(value: model.bind({ CaptureSettings.shutterVolume }, { CaptureSettings.shutterVolume = $0 }),
                                   in: 0.05...1, onEditingChanged: { editing in if !editing { CaptureFiles.playShutter() } })
                                .frame(width: 160)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }

        if CaptureSettings.enabled {
            Card(title: L("Video kaydı"), icon: "record.circle", subtitle: L("Kare hızı, biçim, kalite, ses")) {
                Row(L("Kare hızı"), nil) {
                    Picker("", selection: model.bind({ CaptureSettings.fps }, { CaptureSettings.fps = $0 })) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                Row(L("Biçim"), nil) {
                    Picker("", selection: model.bind({ CaptureSettings.format }, { CaptureSettings.format = $0 })) {
                        Text("H.264").tag(VideoFormat.h264)
                        Text("H.265").tag(VideoFormat.hevc)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                if CaptureSettings.format.usesQuality {
                Row(L("Kalite"), nil) {
                    Picker("", selection: model.bind({ CaptureSettings.quality }, { CaptureSettings.quality = $0 })) {
                        Text(L("Paylaşım")).tag(3)
                        Text(L("Yüksek")).tag(0)
                        Text(L("En yüksek")).tag(1)
                        Text(L("Ham")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }
                }
                ToggleRow(L("Sistem sesini kaydet"), L("Bilgisayardan çıkan ses videoya eklenir"),
                          isOn: model.bind({ CaptureSettings.recordAudio }, { CaptureSettings.recordAudio = $0 }))
                ToggleRow(L("İmleci göster"), nil,
                          isOn: model.bind({ CaptureSettings.showCursor }, { CaptureSettings.showCursor = $0 }))
            }
        }
        monitorsCard
    }

    private func captureRow(_ kind: CaptureKind, key: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        let folder = CaptureSettings.folder(kind)
        return HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .frame(width: 46, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).help(detail)
                Button {
                    NSWorkspace.shared.open(folder)
                } label: {
                    Label((folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.red)
                .help(L("Klasörü Finder'da aç"))
            }
            Spacer(minLength: 8)
            Button(L("Klasör…")) { pickFolder(kind) }
            BrandToggle(isOn: isOn)
        }
        .padding(.vertical, 4)
    }

    /// Kısayolu olmayan çekimler (pencere): sadece kayıt klasörü
    private func folderRow(_ kind: CaptureKind, title: String, detail: String) -> some View {
        let folder = CaptureSettings.folder(kind)
        return HStack(spacing: 10) {
            Image(systemName: kind == .window ? "macwindow" : "macwindow.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 46, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).help(detail)
                Button { NSWorkspace.shared.open(folder) } label: {
                    Label((folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.red)
                .help(L("Klasörü Finder'da aç"))
            }
            Spacer(minLength: 8)
            Button(L("Klasör…")) { pickFolder(kind) }
        }
        .padding(.vertical, 4)
    }

    private func pickFolder(_ kind: CaptureKind) {
        if let url = choose(start: CaptureSettings.folder(kind)) {
            CaptureSettings.setFolder(url, for: kind)
            model.refresh()
        }
    }

    private func pickFolderForAll() {
        if let url = choose(start: CaptureSettings.folder(.screen)) {
            for k in CaptureKind.allCases { CaptureSettings.setFolder(url, for: k) }
            model.refresh()
        }
    }

    private func choose(start: URL) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = L("Seç")
        p.directoryURL = start
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: İzinler

    @ViewBuilder private var permissionsTab: some View {
        let ax = model.axTrusted
        let sc = model.screenTrusted
        let needAX = Onboarding.needsAccessibility
        let needSC = Onboarding.needsScreenRecording
        Card(title: L("Gerekli izinler"), icon: "lock.shield",
             subtitle: needAX || needSC ? L("Sadece açık özelliklerin istediği izinler") : L("Açık özelliklerin hiçbiri izin istemiyor"),
             startOpen: true) {
            if needAX {
                PermissionRow(title: L("Erişilebilirlik"),
                              detail: L("Kısayollar ve pencerelere geçmek, kapatmak, yerleştirmek için."),
                              granted: ax) { SettingsModel.open("Privacy_Accessibility") }
            }
            if needAX && needSC { Divider().opacity(0.4) }
            if needSC {
                PermissionRow(title: L("Ekran Kaydı"),
                              detail: L("Pencere önizlemeleri, ekran görüntüsü ve ekran kaydı için. İzni verdikten sonra uygulamayı bir kez kapatıp aç."),
                              granted: sc) { SettingsModel.open("Privacy_ScreenCapture") }
            }
            if FileSearchSettings.enabled {
                Divider().opacity(0.4)
                PermissionRow(title: L("Tam Disk Erişimi"),
                              detail: L("İsteğe bağlı · tüm diskte arama"),
                              granted: OnboardingModel.hasFullDiskAccess) { SettingsModel.open("Privacy_AllFiles") }
            }
            if !needAX && !needSC && !FileSearchSettings.enabled {
                Text(L("Bir özelliği açarsan gerektirdiği izin burada görünür."))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
            HStack {
                Spacer()
                Button { model.refresh() } label: { Label(L("Yenile"), systemImage: "arrow.clockwise") }
            }
        }
        Card(title: L("Bilgi"), icon: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Kapattığın özellikler için hiçbir izin istenmez."), systemImage: "hand.raised.fill")
                Label(L("Yeniden derledikten sonra izin açık görünüp çalışmıyorsa: listeden Missing'i – ile kaldırıp + ile tekrar ekle."), systemImage: "arrow.triangle.2.circlepath")
                Label(L("Hiçbir şey internete gönderilmez. Diske yazılan tek şey dosya araması için dosya adı indeksi."), systemImage: "externaldrive")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Güncelleme

    private var updateStatus: (String, String, Color) {
        switch updater.state {
        case .idle: return (L("Henüz denetlenmedi"), "clock", .white.opacity(0.6))
        case .checking: return (L("Denetleniyor…"), "arrow.triangle.2.circlepath", .white.opacity(0.8))
        case .upToDate: return (L("Güncel"), "checkmark.circle.fill", .green)
        case .available(let v): return (L("Yeni sürüm var: %@", v), "arrow.down.circle.fill", .accentColor)
        case .downloading: return (L("İndiriliyor…"), "arrow.down.circle", .white.opacity(0.8))
        case .installing: return (L("Yükleniyor, uygulama yeniden açılacak…"), "gearshape.2", .white.opacity(0.8))
        case .failed(let m): return (m, "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder private var updateCard: some View {
        let status = updateStatus
        Card(title: L("Güncellemeler"), icon: "arrow.down.app", subtitle: updateStatus.0, startOpen: true) {
            Row(L("Sürüm %@", updater.currentVersion), nil) {
                HStack(spacing: 10) {
                    Label(status.0, systemImage: status.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.2)
                        .lineLimit(2)
                    if updater.updateAvailable {
                        Button(L("Yükle ve yeniden aç")) { model.onInstallUpdate(nil) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("Şimdi denetle")) { updater.check(userInitiated: true) }
                            .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
                    }
                }
            }
            if let notes = updater.latest?.notes, updater.updateAvailable, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            }
            Divider().opacity(0.4)
            ToggleRow(L("Otomatik denetle"), L("Açılışta ve 6 saatte bir GitHub'a bakar; yeni sürüm olunca haber verir"),
                      isOn: model.bind({ updater.autoCheck }, { updater.autoCheck = $0 }))
            HStack {
                if let last = updater.lastCheck {
                    Text(L("Son denetim: %@", last.formatted(date: .omitted, time: .shortened)))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button(L("GitHub'da aç")) { NSWorkspace.shared.open(UpdateConfig.releasesPage) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.red)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    // MARK: Sürümler

    private struct VersionRow: Identifiable {
        let version: String
        let lines: [String]
        let release: ReleaseInfo?
        let preGitHub: Bool
        var id: String { version }
    }

    /// Uygulamadaki sürüm geçmişi + GitHub'daki sürümler (geçmişte olmayan daha yeni sürümler notlarıyla)
    private var versionRows: [VersionRow] {
        let byVersion = Dictionary(updater.releases.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = Changelog.entries.map {
            VersionRow(version: $0.version, lines: $0.lines, release: byVersion[$0.version], preGitHub: $0.preGitHub)
        }
        let known = Set(rows.map(\.version))
        for r in updater.releases where !known.contains(r.version) {
            let lines = r.notes.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*-# ")) }
                .filter { !$0.isEmpty }
                .prefix(8)
            rows.append(VersionRow(version: r.version, lines: Array(lines), release: r, preGitHub: false))
        }
        return rows.sorted { Updater.isNewer($0.version, than: $1.version) }
    }

    private var confirmMessage: String {
        guard let r = confirmRelease else { return "" }
        if Updater.isNewer(r.version, than: updater.currentVersion) {
            return L("Ayarların ve izinlerin korunur.")
        }
        var msg = L("Eski bir sürüme dönüyorsun. Ayarların ve izinlerin korunur. Otomatik denetim açıksa Missing yeni sürüm olduğunu yine haber verir; istersen Genel'den kapatabilirsin.")
        if Updater.isNewer("2.3.0", than: r.version) { msg += "\n\n" + L("Bu sürümün arayüzü sadece Türkçe.") }
        if Updater.isNewer("2.3.1", than: r.version) { msg += "\n\n" + L("Bu sürüm 2.3.1 güvenlik iyileştirmelerini içermez.") }
        return msg
    }

    private var installBusy: Bool { updater.state == .downloading || updater.state == .installing }

    @ViewBuilder private var versionsTab: some View {
        Card(title: L("Sürümler"), icon: "clock.arrow.circlepath", startOpen: true) {
            HStack(spacing: 10) {
                Text(L("Şu an %@", updater.currentVersion))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if updater.releasesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { updater.fetchReleases() } label: { Label(L("Yenile"), systemImage: "arrow.clockwise") }
                }
            }
            if let err = updater.releasesError {
                Label(L("Sürüm listesi alınamadı: %@", err), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            switch updater.state {
            case .downloading, .installing, .failed:
                let s = updateStatus
                Label(s.0, systemImage: s.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.2)
            default: EmptyView()
            }
        }
        .onAppear { if updater.releases.isEmpty { updater.fetchReleases() } }

        // Sürüm serileri (1.0, 2.0, 2.1, 2.2, 2.3…): eşit boyda kutular, açınca alt sürümler
        VStack(spacing: 12) {
            ForEach(versionSeries) { s in
                seriesBox(s)
            }
        }
    }

    private struct VersionSeries: Identifiable {
        let id: String            // "2.3"
        let versions: [VersionRow]  // yeniden eskiye
        var preGitHub: Bool { versions.allSatisfy(\.preGitHub) }
        var lines: [String] { versions.flatMap(\.lines) }
    }

    /// "2.3.12" → "2.3", "2.1" → "2.1"
    private static func seriesKey(_ v: String) -> String {
        let p = v.split(separator: ".")
        return p.count >= 2 ? "\(p[0]).\(p[1])" : v
    }

    private var versionSeries: [VersionSeries] {
        var order: [String] = []
        var map: [String: [VersionRow]] = [:]
        for r in versionRows {   // zaten yeniden eskiye
            let k = Self.seriesKey(r.version)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(r)
        }
        return order.map { VersionSeries(id: $0, versions: map[$0] ?? []) }
    }

    private static let seriesBoxH: CGFloat = 158

    @ViewBuilder private func seriesBox(_ s: VersionSeries) -> some View {
        let current = updater.currentVersion
        let containsCurrent = s.versions.contains { $0.version == current }
        let open = expandedVersions.contains(s.id)
        let multi = s.versions.count > 1
        let expandable = multi || s.lines.count > 3
        let dates = s.versions.compactMap { $0.release?.date }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Missing \(s.id)").font(.system(size: 17, weight: .heavy))
                if containsCurrent {
                    Text(multi ? L("Kullanılan: %@", current) : L("Kullanılan"))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.3)))
                }
                Spacer(minLength: 0)
                if expandable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if open { expandedVersions.remove(s.id) } else { expandedVersions.insert(s.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(open ? L("Küçült") : (multi ? L("%@ sürüm", "\(s.versions.count)") : L("Tümünü göster")))
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Group {
                if s.preGitHub {
                    Text(L("GitHub öncesi"))
                } else if let lo = dates.min(), let hi = dates.max() {
                    Text(Calendar.current.isDate(lo, inSameDayAs: hi)
                         ? lo.formatted(date: .abbreviated, time: .omitted)
                         : "\(lo.formatted(date: .abbreviated, time: .omitted)) – \(hi.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))

            if open && multi {
                // Alt sürümler: her biri kendi notları ve geçiş düğmesiyle
                VStack(spacing: 8) {
                    ForEach(s.versions) { v in subVersionRow(v) }
                }
            } else {
                bulletList(s.lines)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(maxHeight: open ? nil : .infinity, alignment: .topLeading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: (expandable && !open) ? 0.65 : 1),
                                                 .init(color: .black.opacity((expandable && !open) ? 0 : 1), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: open ? nil : Self.seriesBoxH, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))   // içerik kutudan taşmasın
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(containsCurrent ? 0.10 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(containsCurrent ? Color.green.opacity(0.45) : .white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder private func bulletList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.white.opacity(0.45))
                    Text(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.78))
    }

    @ViewBuilder private func subVersionRow(_ v: VersionRow) -> some View {
        let isCurrent = v.version == updater.currentVersion
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(v.version).font(.system(size: 13, weight: .bold))
                if let d = v.release?.date {
                    Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text(L("Kullanılan")).font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.3)))
                } else if let r = v.release {
                    let newer = Updater.isNewer(r.version, than: updater.currentVersion)
                    Button(newer ? L("Yükle") : L("Bu sürüme dön")) { confirmRelease = r }
                        .controlSize(.small)
                        .disabled(installBusy)
                }
            }
            bulletList(v.lines)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(isCurrent ? 0.10 : 0.05)))
    }

    // MARK: Genel

    @ViewBuilder private var generalTab: some View {
        Card(title: "Language · Dil", icon: "globe", subtitle: AppLanguage.selected.title, startOpen: true) {
            Row(L("Uygulamanın dili"), AppLanguage.selected != AppLanguage.active ? L("Dil değişikliği için Missing yeniden başlatılır") : nil) {
                HStack(spacing: 10) {
                    Picker("", selection: model.bind({ AppLanguage.selected }, { AppLanguage.selected = $0 })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    if AppLanguage.selected != AppLanguage.active {
                        Button(L("Yeniden başlat")) { Updater.relaunchApp() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        Card(title: L("Başlangıç"), icon: "power", startOpen: true) {
            ToggleRow(L("Girişte başlat"), L("Uygulama /Applications klasöründe olmalı"), isOn: model.loginBinding)
            Divider().opacity(0.4)
            Row(L("Kurulum"), L("Hangi özelliklerin açık olacağını baştan seç")) {
                Button(L("Kurulumu aç")) { model.onOpenSetup() }
            }
        }
        updateCard
    }
}

// MARK: - Parçalar

/// Açılır kapanır kart. isOn verilirse başlıkta özelliğin ana aç/kapa düğmesi olur;
/// kapalıyken ayrıntılar gizlenir. Açık/kapalı durumu oturum boyunca hatırlanır.
enum CardMemory { static var open = Set<String>() }

struct Card<Content: View>: View {
    let title: String
    let icon: String
    let isOn: Binding<Bool>?
    let subtitle: String?
    /// true: ana özelliğin kartı; kapalıyken hiç görünmez, aç/kapa Özellikler'de.
    /// false: başlıkta kendi düğmesi var (alt ve hızlı özellikler).
    let hidesWhenOff: Bool
    let content: Content
    @State private var expanded: Bool

    init(title: String, icon: String, isOn: Binding<Bool>? = nil, subtitle: String? = nil,
         hidesWhenOff: Bool = false, startOpen: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.isOn = isOn
        self.subtitle = subtitle
        self.hidesWhenOff = hidesWhenOff
        self.content = content()
        let remembered = CardMemory.open.contains(title)
        _expanded = State(initialValue: remembered || (startOpen && !CardMemory.open.contains("-" + title)))
    }

    private var enabled: Bool { isOn?.wrappedValue ?? true }
    private var showsBody: Bool { expanded && enabled }

    var body: some View {
        // Ana özellik kapalıysa kart hiç görünmez (aç/kapa Ayarlar › Özellikler'de)
        if enabled || !hidesWhenOff { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsBody {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.5))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled && isOn != nil ? Brand.red.opacity(0.85) : Color.white.opacity(0.10)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let isOn, !hidesWhenOff { BrandToggle(isOn: isOn) }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.45 : 0.15))
                .rotationEffect(.degrees(showsBody ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            if expanded {
                CardMemory.open.insert(title); CardMemory.open.remove("-" + title)
            } else {
                CardMemory.open.remove(title); CardMemory.open.insert("-" + title)
            }
        }
    }
}

struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Sade görünüm: açıklama metni gösterilmez, üstüne gelince ipucu olarak çıkar
            Text(title).font(.system(size: 13, weight: .medium))
                .help(detail ?? "")
            Spacer()
            trailing
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Row(title, detail) {
            BrandToggle(isOn: $isOn)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        Row(title, detail) {
            HStack(spacing: 10) {
                Label(granted ? L("Verildi") : L("Verilmedi"),
                      systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Button(L("Ayarları aç"), action: open)
            }
        }
    }
}


/// Kaldırılabilir küçük çipler (satıra sığmayan alta geçer)
struct ChipItem: Identifiable { let id: String; let name: String }

struct FlowChips: View {
    let items: [ChipItem]
    let onRemove: (String) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items) { it in
                HStack(spacing: 6) {
                    Text(it.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { onRemove(it.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.10)))
            }
        }
    }
}


// MARK: - Ekolayzır bantları

/// 10 dikey sürgü: üstte kazanç, altta frekans; çift tıklayınca o bant sıfırlanır
struct EQBandsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let gains = EQSettings.gains
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(EQSettings.frequencies.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(Self.short(gains[i]))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(abs(gains[i]) < 0.05 ? Color.white.opacity(0.45) : Brand.red)
                    VerticalSlider(value: Binding(get: { EQSettings.gains[i] }, set: { v in
                        var g = EQSettings.gains
                        g[i] = (v * 2).rounded() / 2
                        EQSettings.gains = g
                        Equalizer.shared.settingsChanged()
                        model.refresh()
                    }))
                    .frame(width: 26, height: 130)
                    .onTapGesture(count: 2) {
                        var g = EQSettings.gains
                        g[i] = 0
                        EQSettings.gains = g
                        Equalizer.shared.settingsChanged()
                        model.refresh()
                    }
                    Text(Self.freq(EQSettings.frequencies[i]))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
    }

    private static func short(_ v: Double) -> String {
        abs(v) < 0.05 ? "0" : (v > 0 ? String(format: "+%.1f", v) : String(format: "%.1f", v))
    }

    private static func freq(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

/// Dikey sürgü (-12…+12 dB): ortada sıfır çizgisi, değer kırmızı dolgu
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let y = h * CGFloat(1 - (value - range.lowerBound) / span)
            let mid = h / 2
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 4).frame(maxHeight: .infinity)
                Rectangle().fill(.white.opacity(0.25)).frame(width: 12, height: 1).offset(y: mid)
                Capsule().fill(Brand.red)
                    .frame(width: 4, height: abs(mid - y))
                    .offset(y: min(mid, y))
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .offset(y: y - 7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let k = 1 - min(max(g.location.y / h, 0), 1)
                value = range.lowerBound + Double(k) * span
            })
        }
    }
}
