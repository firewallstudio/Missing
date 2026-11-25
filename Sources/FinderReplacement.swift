import AppKit

// MARK: - Finder yerine Dosyalar
//
// Finder sistemin parçası, kaldırılamaz (masaüstü simgeleri, Çöp Sepeti, AirDrop onun). Ama Path Finder ve
// ForkLift'in yaptığı gibi Dosyalar macOS'un varsayılan dosya görüntüleyicisi yapılabilir:
// NSFileViewer: başka uygulamalardaki "Finder'da göster" (Chrome indirmeleri, VS Code, Xcode, Spotlight…) Dosyalar'da açılır.
// Kapatınca Finder'a döner. Klasörlerin varsayılan uygulaması (public.folder) macOS'ta Finder'a kilitli: değiştirilemez
// (LSSetDefaultRoleHandlerForContentType ve NSWorkspace.setDefaultApplication -50 döner). Dock'taki Finder simgesi ise
// FinderDockClick ile zaten Dosyalar'ı açıyor.

@MainActor enum FinderReplacement {
    private static let finderID = "com.apple.finder"
    private static let fileViewerKey = "NSFileViewer" as CFString

    /// Ayardaki tercih (varsayılan: kapalı; masaüstündeki klasörleri de Dosyalar açar)
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "files.replaceFinder") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "files.replaceFinder")
            apply()
        }
    }

    /// Dosyalar açıksa ve tercih açıksa sistemi Dosyalar'a, değilse Finder'a yönlendir
    static func apply() {
        let on = enabled && FilesSettings.enabled
        guard let id = Bundle.main.bundleIdentifier else { return }
        if on {
            CFPreferencesSetValue(fileViewerKey, id as CFString, kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        } else {
            // Yalnızca bizi gösteriyorsa geri al (kullanıcı başka bir dosya yöneticisi seçmişse dokunma)
            let viewer = CFPreferencesCopyValue(fileViewerKey, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
            if viewer == id {
                CFPreferencesSetValue(fileViewerKey, nil, kCFPreferencesAnyApplication,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Şu an sistem Dosyalar'ı mı kullanıyor
    static var isActive: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let viewer = CFPreferencesCopyValue(fileViewerKey, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return viewer == id
    }

    // MARK: Gelen istekler

    /// "Finder'da göster" (Apple Event 'misc'/'mvis') ve klasör açma isteklerini dinle
    static func installHandlers() {
        NSAppleEventManager.shared().setEventHandler(RevealHandler.shared,
                                                     andSelector: #selector(RevealHandler.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    /// Klasör ya da dosya: Dosyalar'da aç (dosyaysa klasöründe seçili); Dosyalar kapalıysa Finder'a bırak
    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard FilesSettings.enabled else { openInFinder(urls); return }
        for u in urls { FilesManager.shared.reveal(u) }
    }

    // MARK: Gerçekten Finder'da göster

    /// Dosyalar'ın kendi "Finder'da göster" düğmeleri: sistem Dosyalar'a yönlenmiş olsa da Finder açılır
    static func openInFinder(_ urls: [URL]) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let folders = urls.filter { u in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
                && !NSWorkspace.shared.isFilePackage(atPath: u.path)
        }
        let files = urls.filter { u in !folders.contains(u) }
        if !folders.isEmpty {
            NSWorkspace.shared.open(folders, withApplicationAt: finder, configuration: cfg)
        }
        guard !files.isEmpty else { return }
        // Dosyayı seçili göstermek için Finder'a doğrudan "göster" de; olmazsa klasörünü aç
        if !revealInFinder(files) {
            NSWorkspace.shared.open(Array(Set(files.map { $0.deletingLastPathComponent() })),
                                    withApplicationAt: finder, configuration: cfg)
        }
    }

    private static func revealInFinder(_ urls: [URL]) -> Bool {
        let list = NSAppleEventDescriptor.list()
        for (i, u) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: u), at: i + 1)
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: finderID)
        let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEMakeObjectsVisible),
                                        targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                        transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(list, forKeyword: keyDirectObject)
        do {
            _ = try ev.sendEvent(options: [.noReply], timeout: 3)
            NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first?.activate()
            return true
        } catch {
            return false
        }
    }
}

/// Apple Event alıcısı (seçici için NSObject gerekir)
final class RevealHandler: NSObject {
    static let shared = RevealHandler()

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let d = event.paramDescriptor(forKeyword: keyDirectObject) {
            if d.numberOfItems > 0 {
                for i in 1...d.numberOfItems { if let u = d.atIndex(i).flatMap(Self.url) { urls.append(u) } }
            } else if let u = Self.url(d) {
                urls.append(u)
            }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { FinderReplacement.show(urls) } }
    }

    private static func url(_ d: NSAppleEventDescriptor) -> URL? {
        if let u = d.fileURLValue { return u }
        if let c = d.coerce(toDescriptorType: typeFileURL), let u = URL(dataRepresentation: c.data, relativeTo: nil) { return u }
        return nil
    }
}
