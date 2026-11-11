import Cocoa
import SwiftUI
import ApplicationServices

// MARK: - İlk kurulum
//
// İlk açılışta hangi özelliklerin kullanılacağı sorulur. Seçilmeyenler kapatılır ve
// izinleri istenmez; hepsi sonradan Ayarlar'dan (ya da Genel › Kurulum'dan) açılabilir.

enum Onboarding {
    private static let d = UserDefaults.standard
    private static let key = "onboarding.done"

    static var done: Bool {
        get { d.bool(forKey: key) }
        set { d.set(newValue, forKey: key) }
    }

    /// Daha önce kurulmuş bir kopyaysa (eski sürümler her açılışta bu anahtarı yazar) kurulum gösterilmez.
    /// Migration.run()'dan önce çağrılır.
    static func prepare() {
        guard d.object(forKey: key) == nil else { return }
        let existing = d.object(forKey: "migratedFromGlassTabAudioHop") != nil
            || d.object(forKey: "knownDevices") != nil
        done = existing   // yeni kurulumda false yazılır: kurulum bitmeden çıkılırsa bir dahaki açılışta yine sorulur
    }

    /// Klavye kısayolu ya da pencere işi yapan bir özellik açık mı (Erişilebilirlik gerekir)
    static var needsAccessibility: Bool {
        if Profile.allCases.contains(where: { $0.enabled }) { return true }
        if DeviceStore.shared.hotkeyEnabled { return true }
        if CaptureSettings.enabled || TileSettings.enabled || SnapBarSettings.enabled { return true }
        if FileSearchSettings.enabled { return true }
        return DockDragSettings.enabled || FinderMouseNav.enabled || FinderTabsSettings.enabled
    }

    /// Pencere önizlemeleri ya da ekran çekimi açık mı (Ekran Kaydı gerekir)
    static var needsScreenRecording: Bool {
        if CaptureSettings.enabled { return true }
        return Profile.allCases.contains { $0.enabled && $0.previews }
    }
}

// MARK: - Özellik listesi

enum SetupPermission: CaseIterable {
    case accessibility, screen, disk

    var title: String {
        switch self {
        case .accessibility: return L("Erişilebilirlik")
        case .screen: return L("Ekran Kaydı")
        case .disk: return L("Tam Disk Erişimi")
        }
    }

    var icon: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screen: return "rectangle.dashed.badge.record"
        case .disk: return "internaldrive"
        }
    }

    var pane: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screen: return "Privacy_ScreenCapture"
        case .disk: return "Privacy_AllFiles"
        }
    }
}

struct SetupFeature: Identifiable {
    let id: String
    let icon: String
    let title: String
    let keys: String
    let permissions: [SetupPermission]
    let get: () -> Bool
    let set: (Bool) -> Void

    static var all: [SetupFeature] {
        let store = DeviceStore.shared
        return [
            SetupFeature(id: "switcher", icon: "rectangle.on.rectangle", title: L("Pencere değiştirici"),
                         keys: "⌘Tab  ⌥Tab", permissions: [.accessibility],
                         get: { Profile.cmd.enabled || Profile.opt.enabled },
                         set: { v in Profile.cmd.enabled = v; Profile.opt.enabled = v }),
            SetupFeature(id: "previews", icon: "photo.on.rectangle", title: L("Pencere önizlemeleri"),
                         keys: "", permissions: [.screen],
                         get: { Profile.allCases.contains { $0.previews } },
                         set: { v in
                             Profile.opt.previews = v
                             if !v { Profile.cmd.previews = false }
                         }),
            SetupFeature(id: "audio", icon: "speaker.wave.2.fill", title: L("Ses cihazı kısayolu"),
                         keys: store.hotkeyChoice.symbol, permissions: [.accessibility],
                         get: { store.hotkeyEnabled }, set: { store.hotkeyEnabled = $0 }),
            SetupFeature(id: "capture", icon: "camera.viewfinder", title: L("Ekran görüntüsü ve kayıt"),
                         keys: "⌘⇧3  4  5  6", permissions: [.accessibility, .screen],
                         get: { CaptureSettings.enabled }, set: { CaptureSettings.enabled = $0 }),
            SetupFeature(id: "tile", icon: "rectangle.split.3x1", title: L("Ekran bölme"),
                         keys: "⌘<", permissions: [.accessibility],
                         get: { TileSettings.enabled || SnapBarSettings.enabled },
                         set: { v in TileSettings.enabled = v; SnapBarSettings.enabled = v }),
            SetupFeature(id: "search", icon: "magnifyingglass", title: L("Dosya ara"),
                         keys: "⌘Space", permissions: [.accessibility, .disk],
                         get: { FileSearchSettings.enabled }, set: { FileSearchSettings.enabled = $0 }),
            SetupFeature(id: "helpers", icon: "dock.arrow.up.rectangle", title: L("Dock ve fare yardımcıları"),
                         keys: "", permissions: [.accessibility],
                         get: { DockDragSettings.enabled || FinderMouseNav.enabled },
                         set: { v in DockDragSettings.enabled = v; FinderMouseNav.enabled = v }),
        ]
    }
}

// MARK: - Model

final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published private(set) var tick = 0
    let features = SetupFeature.all
    private var timer: Timer?

    func binding(_ f: SetupFeature) -> Binding<Bool> {
        Binding(get: { f.get() }, set: { [weak self] v in
            self?.objectWillChange.send()
            f.set(v)
        })
    }

    func isOn(_ id: String) -> Bool { features.first { $0.id == id }?.get() ?? false }

    /// Seçimlere göre istenecek izinler (Tam Disk Erişimi isteğe bağlı)
    var permissions: [SetupPermission] {
        var out: [SetupPermission] = []
        if Onboarding.needsAccessibility { out.append(.accessibility) }
        if Onboarding.needsScreenRecording { out.append(.screen) }
        if FileSearchSettings.enabled { out.append(.disk) }
        return out
    }

    func granted(_ p: SetupPermission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screen: return CGPreflightScreenCaptureAccess()
        case .disk: return Self.hasFullDiskAccess
        }
    }

    /// Tam Disk Erişimi var mı: korunan dosyalardan biri gerçekten açılabiliyor mu.
    /// (İzin dosya izinleriyle değil açarken denetlendiği için isReadableFile yanılır.)
    static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        let probes = ["/Library/Application Support/com.apple.TCC/TCC.db",
                      home + "/Library/Application Support/com.apple.TCC/TCC.db",
                      home + "/Library/Safari/Bookmarks.plist",
                      home + "/Library/Mail"]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }

    /// İlk basışta macOS'un kendi sorusu, sonrakilerde Sistem Ayarları'ndaki ilgili bölüm
    func request(_ p: SetupPermission) {
        let askedKey = "onboarding.asked.\(p.pane)"
        let asked = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        switch p {
        case .accessibility where !asked:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .screen where !asked:
            _ = CGRequestScreenCaptureAccess()
        default:
            SettingsModel.open(p.pane)
        }
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick += 1
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Pencere

final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var onFinish: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    func show(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let m = OnboardingModel()
        model = m
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("Missing Kurulumu")
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        let view = OnboardingView(model: m) { [weak self] in self?.window?.close() }
        w.contentView = NSHostingView(rootView: view)
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Kapatma düğmesi de "Bitti" sayılır: o anki seçimler geçerli
    func windowWillClose(_ notification: Notification) {
        model?.stopWatching()
        window = nil
        model = nil
        let done = onFinish
        onFinish = nil
        done?()
    }
}

// MARK: - Görünüm

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.step == 0 { featuresStep } else { permissionsStep }
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(width: 520, height: 640)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow)
                Color.black.opacity(0.30)
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        )
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Adım 1: özellikler

    @ViewBuilder private var featuresStep: some View {
        header(icon: nil, title: L("Missing'e hoş geldin"), subtitle: L("Neleri kullanacaksın? Sonra Ayarlar'dan değiştirebilirsin."))
        VStack(spacing: 0) {
            ForEach(model.features) { f in
                featureRow(f)
                if f.id != model.features.last?.id { Divider().opacity(0.35).padding(.leading, 44) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        Spacer(minLength: 12)
        let perms = model.permissions
        HStack {
            Text(perms.isEmpty ? L("İzin gerekmiyor") : perms.map(\.title).joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer()
            Button(perms.isEmpty ? L("Bitti") : L("Devam")) {
                if perms.isEmpty { close() } else {
                    model.step = 1
                    model.startWatching()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(BrandButtonStyle())
        }
    }

    private func featureRow(_ f: SetupFeature) -> some View {
        let disabled = f.id == "previews" && !model.isOn("switcher")
        let on = f.get()
        return HStack(spacing: 12) {
            Image(systemName: f.icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Brand.red.opacity(0.85) : Color.white.opacity(0.10)))
            Text(f.title).font(.system(size: 13.5, weight: .medium))
            Spacer()
            if !f.keys.isEmpty {
                Text(f.keys)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            BrandToggle(isOn: model.binding(f))
        }
        .padding(.vertical, 8)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }

    // MARK: Adım 2: izinler

    @ViewBuilder private var permissionsStep: some View {
        let _ = model.tick
        header(icon: "lock.shield.fill", title: L("İzinler"), subtitle: L("Sadece seçtiklerin için."))
        VStack(spacing: 0) {
            let perms = model.permissions
            ForEach(perms, id: \.self) { p in
                permissionRow(p)
                if p != perms.last { Divider().opacity(0.35).padding(.leading, 44) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        Spacer(minLength: 12)
        HStack {
            Button(L("Geri")) {
                model.stopWatching()
                model.step = 0
            }
            .buttonStyle(GlassButtonStyle())
            Spacer()
            Button(L("Bitti"), action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(BrandButtonStyle())
        }
    }

    private func permissionRow(_ p: SetupPermission) -> some View {
        let ok = model.granted(p)
        return HStack(spacing: 12) {
            Image(systemName: p.icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 13.5, weight: .medium))
                if p == .disk {
                    Text(L("İsteğe bağlı · tüm diskte arama"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.green)
            } else {
                Button(L("İzin ver")) { model.request(p) }.buttonStyle(BrandButtonStyle())
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Başlık

    private func header(icon: String?, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Brand.red).frame(height: 64)
            } else {
                Image(nsImage: Brand.leaf).resizable().frame(width: 64, height: 64)
            }
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 20)
    }
}
