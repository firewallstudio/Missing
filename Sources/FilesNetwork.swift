import AppKit
import SwiftUI

// MARK: - Ağ (Finder'daki Ağ gibi, Dosyalar'ın içinde)
//
// Yerel ağdaki paylaşım sunucuları Bonjour ile bulunur (SMB, AFP). Tıklayınca macOS'un kendi bağlanma
// penceresi açılır (kullanıcı adı / paylaşım seçimi); paylaşım bağlanınca Dosyalar onun içine geçer.
// Bağlı ağ paylaşımları da burada listelenir. "Sunucuya bağlan" ile adres elle yazılabilir.

@MainActor final class FilesNetworkBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = FilesNetworkBrowser()

    struct Server: Identifiable, Hashable {
        let name: String
        var host: String?
        var kinds: Set<String>
        var id: String { name }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var mounted: [SidebarPlace] = []
    @Published private(set) var searching = false

    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    /// Bağlanma isteği verilen pencere: paylaşım bağlanınca içine geçilir
    private weak var pending: FilesWindowController?
    private var pendingUntil = Date.distantPast

    private override init() {
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.mountChanged(url) }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMounted() }
        }
        refreshMounted()
    }

    /// Ağ sayfası açılınca taramayı başlat (bir kez; sonra canlı güncellenir)
    func start() {
        refreshMounted()
        guard browsers.isEmpty else { return }
        searching = true
        for type in ["_smb._tcp.", "_afpovertcp._tcp."] {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.searching = false }
    }

    func refreshMounted() {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        mounted = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsLocal == false else { return nil }
            return SidebarPlace(url: u, title: v?.volumeLocalizedName ?? u.lastPathComponent, symbol: "server.rack")
        }
    }

    private func mountChanged(_ url: URL?) {
        refreshMounted()
        // Az önce bağlanma istenen paylaşım geldiyse içine geç
        if let url, let c = pending, Date() < pendingUntil, mounted.contains(where: { $0.url.fileKey == url.fileKey }) {
            pending = nil
            c.navigate(url)
            c.bringToFront()
        }
    }

    /// macOS'un bağlanma penceresi: paylaşım seçilip bağlanınca Dosyalar o paylaşıma geçer
    func connect(_ address: String, from controller: FilesWindowController) {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        if !a.contains("://") { a = "smb://" + a }
        guard let url = URL(string: a) else { NSSound.beep(); return }
        pending = controller
        pendingUntil = Date().addingTimeInterval(120)
        NSWorkspace.shared.open(url)
    }

    func connect(_ s: Server, from controller: FilesWindowController) {
        let scheme = s.kinds.contains("_smb._tcp.") ? "smb" : "afp"
        let host = s.host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            ?? (s.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? s.name) + ".local"
        connect("\(scheme)://\(host)", from: controller)
    }

    // MARK: Bonjour

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 5)
            let type = service.type
            if let i = servers.firstIndex(where: { $0.name == service.name }) {
                servers[i].kinds.insert(type)
            } else {
                servers.append(Server(name: service.name, host: nil, kinds: [type]))
                servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            services.removeAll { $0 === service }
            if !services.contains(where: { $0.name == service.name }) { servers.removeAll { $0.name == service.name } }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard let host = sender.hostName, let i = servers.firstIndex(where: { $0.name == sender.name }) else { return }
            servers[i].host = host
        }
    }
}

/// Ağ sayfası
struct FilesNetworkView: View {
    @ObservedObject var net = FilesNetworkBrowser.shared
    let controller: FilesWindowController
    @Environment(\.filesPalette) private var p
    @State private var address = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !net.mounted.isEmpty {
                    section(L("Bağlı paylaşımlar")) {
                        ForEach(net.mounted) { m in
                            tile(icon: Image(nsImage: FileIcons.shared.icon(m.url)), title: m.title,
                                 detail: m.url.path) { controller.navigate(m.url) }
                        }
                    }
                }
                section(L("Ağdaki bilgisayarlar")) {
                    if net.servers.isEmpty {
                        HStack(spacing: 8) {
                            if net.searching { ProgressView().controlSize(.small) }
                            Text(net.searching ? L("Aranıyor…") : L("Paylaşım yapan bilgisayar bulunamadı"))
                                .font(.system(size: 12)).foregroundStyle(p.fg.opacity(0.5))
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(net.servers) { s in
                        tile(icon: Image(systemName: "desktopcomputer"), title: s.name,
                             detail: s.host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? "") {
                            net.connect(s, from: controller)
                        }
                    }
                }
                section(L("Sunucuya bağlan")) {
                    HStack(spacing: 8) {
                        FilesThemedField(text: $address, placeholder: L("smb://sunucu.local"), autofocus: false) {
                            net.connect(address, from: controller)
                        }
                        Button(L("Bağlan")) { net.connect(address, from: controller) }
                            .filesButton(.primary, p)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: 460)
                    Text(L("Bir bilgisayara tıklayınca macOS kullanıcı adı ve paylaşım sorar; bağlanınca paylaşım burada açılır."))
                        .font(.system(size: 11)).foregroundStyle(p.fg.opacity(0.45))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { net.start() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.fg.opacity(0.55))
            content()
        }
    }

    private func tile(icon: Image, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.resizable().scaledToFit().frame(width: 30, height: 30).foregroundStyle(p.fg.opacity(0.75))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(p.fg)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(p.fg.opacity(0.45)).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.fg.opacity(0.3))
            }
            .padding(10)
            .frame(maxWidth: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: p.radius + 2, style: .continuous).fill(p.fg.opacity(p.dark ? 0.06 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Çöp Sepeti

@MainActor enum FilesTrash {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    static func isTrash(_ u: URL) -> Bool { u.fileKey == url.fileKey }

    /// Onay sorup Çöp Sepeti'ni boşaltır. Okunabiliyorsa kendisi siler, okunamıyorsa Finder'a boşalttırır.
    static func empty(in window: NSWindow?) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? nil
        let icon = NSImage(named: NSImage.trashFullName).map(FilesDialog.Icon.image) ?? .warning
        FilesDialog.show(on: window, title: L("Çöp Sepeti'ndeki öğeler kalıcı olarak silinsin mi?"),
                         message: items.map { L("%d öğe silinecek. Bu işlem geri alınamaz.", $0.count) } ?? L("Bu işlem geri alınamaz."),
                         icon: icon,
                         actions: [.init(L("Vazgeç"), .cancel), .init(L("Çöp Sepetini Boşalt"), .destructiveDefault)]) { r, _ in
            guard r == 1 else { return }
            if let items {
                DispatchQueue.global(qos: .userInitiated).async {
                    for u in items { try? FileManager.default.removeItem(at: u) }
                    DispatchQueue.main.async { playEmptySound() }
                }
            } else {
                var err: NSDictionary?
                _ = NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            }
        }
    }

    private static func playEmptySound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}
