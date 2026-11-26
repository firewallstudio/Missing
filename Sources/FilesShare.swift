import AppKit

// MARK: - Dosyalar'ın kendi Paylaş menüsü
//
// Sistemin paylaşım seçicisi yerine macOS'un bu dosyalar için sunduğu servisler (AirDrop, Mail, Mesajlar,
// Notlar, …) bizim temalı menümüzde listelenir. Sağ tık menüsünde "Paylaş" alt menüsü olarak (yana açılır),
// önizleme başlığındaki düğmeden ise tek başına açılır. Bir servis seçilince dosya URL'leri o servise verilir;
// servisin kendi penceresi (Mail taslağı, AirDrop, Mesajlar) Dosyalar penceresinden açılır.

@MainActor final class FilesShare: NSObject {
    static let shared = FilesShare()

    /// Seçilen servisi çalıştırır. Deneme düzeneği gerçek paylaşım yapmadan bunu değiştirir.
    static var performer: (NSSharingService, [URL]) -> Void = { service, urls in
        service.perform(withItems: urls)
    }

    /// Önce gelen servisler (Finder'daki sıra): AirDrop, Mail, Mesajlar, Notlar
    static let preferred: [NSSharingService.Name] = [
        .sendViaAirDrop, .composeEmail, .composeMessage, NSSharingService.Name("com.apple.Notes.SharingExtension"),
    ]

    /// Paylaşılan dosyalar ve servisin pencere / çerçeve sorduğu yer
    final class Job: NSObject {
        let urls: [URL]
        weak var window: NSWindow?
        let sourceFrame: ((URL) -> NSRect?)?
        init(urls: [URL], window: NSWindow?, sourceFrame: ((URL) -> NSRect?)?) {
            self.urls = urls; self.window = window; self.sourceFrame = sourceFrame
        }
    }

    /// Menü satırının taşıdığı seçim
    final class Choice: NSObject {
        let service: NSSharingService
        let job: Job
        init(service: NSSharingService, job: Job) { self.service = service; self.job = job }
    }

    /// Alt menüyü ilk açılışta dolduran nesne (servisleri saymak ~30-40 ms sürüyor; sağ tık menüsü bekletilmesin)
    private final class Filler: NSObject, NSMenuDelegate {
        let job: Job
        init(job: Job) { self.job = job }
        func menuNeedsUpdate(_ menu: NSMenu) {
            MainActor.assumeIsolated {
                guard menu.numberOfItems == 0 else { return }
                FilesShare.fill(menu, job: job)
            }
        }
    }

    /// Paylaşım sürerken servis ve işi canlı tut (servisin temsilcisi zayıf tutulur)
    private var active: (service: NSSharingService, job: Job)?

    /// Son tek başına açılışın çapası: aynı düğmeye ikinci tık menüyü kapatsın, yeniden açmasın
    private var lastAnchor: NSPoint?

    // MARK: Menüler

    /// Sağ tık menüsü için "Paylaş" satırı; alt menüsü ilk açılışta dolar
    static func menuItem(for urls: [URL], window: NSWindow?, sourceFrame: ((URL) -> NSRect?)? = nil) -> NSMenuItem {
        let top = NSMenuItem(title: L("Paylaş"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let filler = Filler(job: Job(urls: urls, window: window, sourceFrame: sourceFrame))
        sub.delegate = filler
        top.representedObject = filler      // menünün temsilcisi zayıf: satır tutsun
        top.submenu = sub
        return top
    }

    /// Servis satırlarıyla dolu menü (bizim menümüze alt menü olarak ya da tek başına)
    static func menu(for urls: [URL], window: NSWindow?, sourceFrame: ((URL) -> NSRect?)? = nil) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        fill(m, job: Job(urls: urls, window: window, sourceFrame: sourceFrame))
        return m
    }

    /// Menüyü ekrandaki bir noktada (sol üst köşe) tek başına aç; aynı çapa için açıkken ikinci çağrı kapatır
    static func show(for urls: [URL], at point: NSPoint, window: NSWindow?, sourceFrame: ((URL) -> NSRect?)? = nil) {
        guard !urls.isEmpty else { return }
        let cm = FilesContextMenu.shared
        let now = ProcessInfo.processInfo.systemUptime
        // Düğmeye basış menüyü dışarı tık sayıp kapattıysa (fare inişi), bırakışta yeniden açma: düğme aç/kapa gibi çalışsın
        if let a = shared.lastAnchor, hypot(a.x - point.x, a.y - point.y) < 4, now - cm.closedByClickAt < 0.4 {
            shared.lastAnchor = nil
            return
        }
        if cm.isOpen, let a = shared.lastAnchor, hypot(a.x - point.x, a.y - point.y) < 4 {
            cm.close()
            shared.lastAnchor = nil
            return
        }
        shared.lastAnchor = point
        cm.show(menu(for: urls, window: window, sourceFrame: sourceFrame), at: point, eventTime: now)
    }

    /// Bu dosyalar için sunulan servisler: tercih edilenler önce, sonra kalanlar; aynısı iki kez yok
    static func services(for urls: [URL]) -> [NSSharingService] {
        var out: [NSSharingService] = []
        var seen = Set<String>()
        func add(_ s: NSSharingService) {
            guard s.canPerform(withItems: urls), seen.insert(key(s)).inserted else { return }
            out.append(s)
        }
        let all = available(for: urls)
        for name in preferred {
            if let s = all.first(where: { key($0) == name.rawValue }) ?? NSSharingService(named: name) { add(s) }
        }
        all.forEach(add)
        return out
    }

    private static func available(for urls: [URL]) -> [NSSharingService] {
        // Uyarıyı yalnız burada sustur: önerilmeyen işlevi önerilmeyen bir protokol üzerinden çağır
        (Self.self as DeprecatedShareEnumerating.Type).enumerateServices(urls)
    }

    /// Servisin kimliği (ör. com.apple.share.AirDrop.send); alınamazsa başlığı
    static func key(_ s: NSSharingService) -> String {
        let sel = NSSelectorFromString("name")
        if s.responds(to: sel), let n = s.perform(sel)?.takeUnretainedValue() as? String, !n.isEmpty { return n }
        return s.title
    }

    private static func fill(_ menu: NSMenu, job: Job) {
        menu.removeAllItems()
        let list = services(for: job.urls)
        let firstGroup = Set(preferred.map(\.rawValue))
        var inFirst = true
        for s in list {
            if inFirst, !firstGroup.contains(key(s)) {
                inFirst = false
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            }
            let it = NSMenuItem(title: s.menuItemTitle.isEmpty ? s.title : s.menuItemTitle,
                                action: #selector(FilesShare.choose(_:)), keyEquivalent: "")
            it.target = FilesShare.shared
            it.representedObject = Choice(service: s, job: job)
            if let img = s.image.copy() as? NSImage {
                img.size = NSSize(width: 16, height: 16)
                it.image = img
            }
            menu.addItem(it)
        }
        if list.isEmpty {
            let none = NSMenuItem(title: L("Paylaşma servisi yok"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    // MARK: Seçim

    @objc func choose(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? Choice else { return }
        lastAnchor = nil
        active = (c.service, c.job)
        c.service.delegate = self
        // Missing menü çubuğu uygulaması: servisin penceresi (AirDrop, Mesajlar) öne gelsin, odak alsın
        if !NSApp.isActive {
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
        Self.performer(c.service, c.job.urls)
    }

    private func finished(_ service: NSSharingService) {
        guard active?.service === service else { return }
        service.delegate = nil
        active = nil
    }
}

// MARK: NSSharingServiceDelegate

extension FilesShare: NSSharingServiceDelegate {
    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { active?.job.window }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        MainActor.assumeIsolated {
            guard let job = active?.job, let url = item as? URL else { return .zero }
            return job.sourceFrame?(url) ?? .zero
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finished(sharingService) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated { finished(sharingService) }
    }
}

/// Önerilmeyen sayım işlevini uyarısız çağırmak için (önerilmeyen protokol gereksinimi üzerinden)
private protocol DeprecatedShareEnumerating {
    static func enumerateServices(_ urls: [URL]) -> [NSSharingService]
}

extension FilesShare: DeprecatedShareEnumerating {
    /// macOS 13'ten beri önerilmiyor ama servisleri saymanın tek yolu bu
    @available(macOS, deprecated: 13.0)
    nonisolated static func enumerateServices(_ urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls.map { $0 as NSURL })
    }
}
