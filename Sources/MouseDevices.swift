import AppKit
import IOKit
import IOKit.hid

// MARK: - Mouse: cihazlar ve imleç ayarları
//
// Bağlı fare/trackpad'ler IOHIDEventSystemClient ile listelenir. Bir CGEvent'in hangi cihazdan
// geldiği, olayın içindeki IOHID olayının gönderen kimliğinden (servisin kayıt kimliği) bulunur.
// İmleç ivmesi ve hızı, LinearMouse'taki gibi servisin HID özelliklerine yazılır
// (Portions adapted from LinearMouse, MIT License, Copyright (c) 2021-2024 LinearMouse; see docs/THIRD-PARTY-NOTICES.md).
//
// Geri alma: bir cihaza ilk kez yazmadan önce orijinal değerleri diske kaydedilir. Missing kapanırken
// geri yazılır; çökerse ayrı bekçi süreç (aynı uygulamanın `--mouse-guard` kipi) geri yazar.

enum MouseDeviceCategory: String { case mouse, trackpad, magicMouse }

struct MouseDevice: Identifiable, Hashable {
    let id: UInt64          // servis kayıt kimliği = olaydaki gönderen kimliği
    let name: String
    let vendor: Int
    let product: Int
    let serial: String
    let transport: String
    let category: MouseDeviceCategory

    var key: String { "\(vendor):\(product):\(serial)" }
    var symbol: String {
        switch category {
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .magicMouse, .mouse: return "computermouse"
        }
    }
}

/// CGEventCopyIOHIDEvent / IOHIDEventGetSenderID özel; dlsym ile bulunur (LinearMouse da aynısını yapar)
private typealias CopyHIDEventFn = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
private typealias SenderIDFn = @convention(c) (CFTypeRef) -> UInt64
private let copyHIDEvent: CopyHIDEventFn? = {
    guard let s = dlsym(dlopen(nil, RTLD_NOW), "CGEventCopyIOHIDEvent") else { return nil }
    return unsafeBitCast(s, to: CopyHIDEventFn.self)
}()
private let senderIDOf: SenderIDFn? = {
    guard let s = dlsym(dlopen(nil, RTLD_NOW), "IOHIDEventGetSenderID") else { return nil }
    return unsafeBitCast(s, to: SenderIDFn.self)
}()

/// Olay thread'inden okunabilen, kilitli cihaz tablosu
final class MouseDeviceTable: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var byID: [UInt64: MouseDevice] = [:]
    private var last: MouseDevice?

    func set(_ devices: [MouseDevice]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Olayın cihazı. Kimliği olmayan olaylar (klavye vb.) son kullanılan cihaza sayılır.
    func device(for event: CGEvent) -> MouseDevice? {
        var sender: UInt64 = 0
        if let copy = copyHIDEvent, let get = senderIDOf, let hid = copy(event) {
            let obj = hid.takeRetainedValue()
            sender = get(obj)
        }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if sender != 0, let d = byID[sender] { last = d; return d }
        return sender == 0 ? last : nil
    }
}

/// Olay thread'inin okuduğu cihaz tablosu
let mouseDeviceTable = MouseDeviceTable()

@MainActor final class MouseDevices: ObservableObject {
    static let shared = MouseDevices()
    private var table: MouseDeviceTable { mouseDeviceTable }
    @Published private(set) var devices: [MouseDevice] = []
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var services: [UInt64: IOHIDServiceClient] = [:]
    private var pollTimer: Timer?

    private init() {}

    func start() {
        refresh()
        // Bağlanan/ayrılan cihazlar: hafif yoklama (servis eşleme geri çağrısı her macOS'ta güvenilir değil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { MouseDevices.shared.refresh() }
        }
        pollTimer?.tolerance = 1
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
    }

    func refresh() {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var found: [MouseDevice] = []
        var svc: [UInt64: IOHIDServiceClient] = [:]
        for s in all {
            let page = prop(s, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let usage = prop(s, kIOHIDPrimaryUsageKey) as? Int ?? 0
            let isPointer = page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer)
            // Dahili trackpad sayfa 13 (Digitizer) ile, farklı kullanım koduyla gelir
            let pairs = prop(s, kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? []
            let isTouchpad = page == kHIDPage_Digitizer || pairs.contains { $0[kIOHIDDeviceUsagePageKey] == kHIDPage_Digitizer }
            guard isPointer || isTouchpad else { continue }
            guard let idNum = IOHIDServiceClientGetRegistryID(s) as? NSNumber else { continue }
            let id = idNum.uint64Value
            let vendor = prop(s, kIOHIDVendorIDKey) as? Int ?? 0
            let product = prop(s, kIOHIDProductIDKey) as? Int ?? 0
            let name = prop(s, kIOHIDProductKey) as? String ?? L("Bilinmeyen cihaz")
            let serial = prop(s, kIOHIDSerialNumberKey) as? String ?? ""
            let transport = prop(s, kIOHIDTransportKey) as? String ?? ""
            let category: MouseDeviceCategory
            let apple = vendor == 0x004C || vendor == 0x05AC
            if apple && [0x0269, 0x030D].contains(product) { category = .magicMouse }
            else if isTouchpad || (apple && [0x0265, 0x030E, 0x0273, 0x0276, 0x0278, 0x0340].contains(product))
                        || name.localizedCaseInsensitiveContains("trackpad") { category = .trackpad }
            else { category = .mouse }
            // Aynı cihazın birden fazla servisi olabilir (fare + trackpad yüzü): aynı kimlik bir kez
            guard svc[id] == nil else { continue }
            svc[id] = s
            found.append(MouseDevice(id: id, name: name, vendor: vendor, product: product, serial: serial,
                                     transport: transport, category: category))
        }
        services = svc
        table.set(found)
        let sorted = found.sorted { ($0.category == .mouse ? 0 : 1, $0.name) < ($1.category == .mouse ? 0 : 1, $1.name) }
        if sorted != devices {
            let added = Set(sorted.map(\.id)).subtracting(devices.map(\.id))
            devices = sorted
            if !added.isEmpty { MousePointer.shared.apply() }
        }
    }

    /// Ayarlarda gösterilen tekil cihazlar (aynı cihazın birden fazla servisi tek satır)
    var uniqueDevices: [MouseDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.key).inserted }
    }

    func service(_ id: UInt64) -> IOHIDServiceClient? { services[id] }

    private func prop(_ s: IOHIDServiceClient, _ key: String) -> Any? {
        IOHIDServiceClientCopyProperty(s, key as CFString)
    }
}

// MARK: - İmleç ivmesi ve hızı

/// Bir cihazın değiştirmeden önceki HID değerleri (geri yüklemek için)
struct PointerOriginal: Codable {
    var accelKey: String
    var accel: Int?
    var resolution: Int?
    var linear: Int?
}

@MainActor final class MousePointer {
    static let shared = MousePointer()
    private var applied: [String: (mode: PointerMode, disable: Bool, accel: Double, speed: Double)] = [:]
    /// Değiştirilen cihazların orijinal değerleri (cihaz anahtarına göre)
    private var originals: [String: PointerOriginal] = MousePointer.loadOriginals()
    private var guardProcess: Process?

    nonisolated static var restoreFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Missing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mouse-pointer-restore.json")
    }

    nonisolated private static func loadOriginals() -> [String: PointerOriginal] {
        guard let d = try? Data(contentsOf: restoreFile),
              let o = try? JSONDecoder().decode([String: PointerOriginal].self, from: d) else { return [:] }
        return o
    }

    private func saveOriginals() {
        if originals.isEmpty { try? FileManager.default.removeItem(at: Self.restoreFile); return }
        if let d = try? JSONEncoder().encode(originals) { try? d.write(to: Self.restoreFile, options: .atomic) }
    }

    /// Öndeki uygulama + imlecin altındaki ekrana göre her cihazın imleç ayarını uygula
    func apply() {
        let engine = MouseEngine.shared
        guard engine.isRunning else { return }
        let cfg = engine.config
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let display = MouseScreens.nameUnderCursor()
        for dev in MouseDevices.shared.devices where dev.category != .trackpad || cfg.devices.contains(where: { $0.key == dev.key }) {
            let r = cfg.resolve(device: dev.key, display: display, app: app)
            let mode = r.l.pointerMode ?? .system
            let disable = r.l.disableAccel ?? false
            let accel = r.l.pointerAccel ?? 0.6875
            let speed = r.l.pointerSpeed ?? 0.5
            let want = (mode, disable, accel, speed)
            let key = "\(dev.id)"
            if let a = applied[key], a.mode == want.0, a.disable == want.1, a.accel == want.2, a.speed == want.3 { continue }
            guard let s = MouseDevices.shared.service(dev.id) else { continue }
            if mode == .system && !disable {
                // Sistem ayarı isteniyor: değiştirdiysek geri al, hiç değiştirmediysek dokunma
                if originals[dev.key] != nil { restore(s, originals[dev.key]!) }
                applied[key] = want
                continue
            }
            capture(s, dev)
            write(s, disable: disable, custom: mode == .custom, accel: accel, speed: speed, original: originals[dev.key]?.accel)
            applied[key] = want
        }
        // Hiçbir cihazda sistem dışı ayar kalmadıysa orijinal kaydını sil
        let anyCustom = applied.values.contains { $0.mode == .custom || $0.disable }
        if !anyCustom { originals.removeAll(); saveOriginals() }
    }

    private func capture(_ s: IOHIDServiceClient, _ dev: MouseDevice) {
        guard originals[dev.key] == nil else { return }
        let accelKey = (IOHIDServiceClientCopyProperty(s, kIOHIDPointerAccelerationTypeKey as CFString) as? String)
            ?? (IOHIDServiceClientCopyProperty(s, "HIDPointerAcceleration" as CFString) != nil ? "HIDPointerAcceleration" : "HIDMouseAcceleration")
        originals[dev.key] = PointerOriginal(
            accelKey: accelKey,
            accel: IOHIDServiceClientCopyProperty(s, accelKey as CFString) as? Int,
            resolution: IOHIDServiceClientCopyProperty(s, kIOHIDPointerResolutionKey as CFString) as? Int,
            linear: IOHIDServiceClientCopyProperty(s, "HIDUseLinearScalingMouseAcceleration" as CFString) as? Int)
        saveOriginals()
        startGuard()
    }

    private func write(_ s: IOHIDServiceClient, disable: Bool, custom: Bool, accel: Double, speed: Double, original: Int?) {
        let accelKey = (IOHIDServiceClientCopyProperty(s, kIOHIDPointerAccelerationTypeKey as CFString) as? String) ?? "HIDMouseAcceleration"
        func set(_ k: String, _ v: Int) { IOHIDServiceClientSetProperty(s, k as CFString, v as CFNumber) }
        if #available(macOS 14, *) {
            set("HIDUseLinearScalingMouseAcceleration", disable ? 1 : 0)
        }
        if custom {
            // Hız: çözünürlük (dpi) olarak; 0 → 1200 (yavaş), 1 → 40 (hızlı)
            let inv = 1.0 / 1200 + (1.0 / 40 - 1.0 / 1200) * min(max(speed, 0), 1)
            let res = min(max(1 / inv, 10), 1995)
            if !disable || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 {
                set(kIOHIDPointerResolutionKey, Int(res * 65536))
            }
        }
        var a = custom ? min(max(accel, 0), 40) : Double(original ?? 45056) / 65536
        if disable, ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 { a = -1 }
        set(accelKey, Int(a * 65536))   // çözünürlük ancak ivme yeniden yazılınca geçerli olur
    }

    private func restore(_ s: IOHIDServiceClient, _ o: PointerOriginal) {
        Self.restore(s, o)
    }

    nonisolated static func restore(_ s: IOHIDServiceClient, _ o: PointerOriginal) {
        func set(_ k: String, _ v: Int) { IOHIDServiceClientSetProperty(s, k as CFString, v as CFNumber) }
        if #available(macOS 14, *) { set("HIDUseLinearScalingMouseAcceleration", o.linear ?? 0) }
        set(kIOHIDPointerResolutionKey, o.resolution ?? 400 * 65536)
        if let a = o.accel { set(o.accelKey, a) }
    }

    /// Tüm cihazları değiştirmeden önceki haline döndür (özellik kapanınca, Missing kapanırken)
    func restoreAll() {
        for dev in MouseDevices.shared.devices {
            guard let o = originals[dev.key], let s = MouseDevices.shared.service(dev.id) else { continue }
            Self.restore(s, o)
        }
        applied.removeAll()
        originals.removeAll()
        saveOriginals()
        guardProcess?.terminate(); guardProcess = nil
    }

    /// Missing çökerse imleç ayarlarını geri alacak bekçi süreç
    private func startGuard() {
        guard guardProcess?.isRunning != true, let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--mouse-guard", "\(getpid())"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); guardProcess = p } catch { guardProcess = nil }
    }

    /// Açılışta: önceki çalışma kapanmadan çöktüyse (bekçi de yoksa) bekleyen geri alma işini yap
    nonisolated static func restoreLeftovers() {
        guard let d = try? Data(contentsOf: restoreFile),
              let o = try? JSONDecoder().decode([String: PointerOriginal].self, from: d), !o.isEmpty else { return }
        restoreFromFile(o)
        try? FileManager.default.removeItem(at: restoreFile)
    }

    nonisolated static func restoreFromFile(_ o: [String: PointerOriginal]) {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        for s in IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [] {
            let v = IOHIDServiceClientCopyProperty(s, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let p = IOHIDServiceClientCopyProperty(s, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let sn = IOHIDServiceClientCopyProperty(s, kIOHIDSerialNumberKey as CFString) as? String ?? ""
            if let orig = o["\(v):\(p):\(sn)"] { restore(s, orig) }
        }
    }

    /// `Missing --mouse-guard <pid>`: ana süreç bitene kadar bekle, sonra kalan imleç ayarlarını geri al
    nonisolated static func runGuard(parent: pid_t) -> Never {
        let kq = kqueue()
        var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        if kevent(kq, &ev, 1, nil, 0, nil) == 0 {
            var out = kevent()
            _ = kevent(kq, nil, 0, &out, 1, nil)   // ana süreç çıkana kadar bekler
        }
        restoreLeftovers()
        exit(0)
    }
}

// MARK: - Ekranlar

/// İmlecin altındaki ekranın adı. Olay thread'inden de çağrılır: ekran kimliği CG ile bulunur,
/// adı ana thread'de doldurulan önbellekten okunur.
enum MouseScreens {
    private static var lock = os_unfair_lock()
    nonisolated(unsafe) private static var names: [CGDirectDisplayID: String] = [:]

    @MainActor static func refresh() {
        var n: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                n[id] = s.localizedName
            }
        }
        os_unfair_lock_lock(&lock); names = n; os_unfair_lock_unlock(&lock)
    }

    static var allNames: [String] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return Array(Set(names.values)).sorted()
    }

    static func displayID(at p: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    static func name(at p: CGPoint) -> String? {
        guard let id = displayID(at: p) else { return nil }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return names[id]
    }

    static func nameUnderCursor() -> String? {
        name(at: CGEvent(source: nil)?.location ?? .zero)
    }
}
