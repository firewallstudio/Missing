import Foundation
import CoreAudio
import AudioToolbox
import os

// MARK: - Basit ekolayzır (eqMac'siz)
//
// macOS 14.2+ "process tap": sistemin bütün sesi (Missing'inki hariç) yakalanır ve asıl çıkışta susturulur;
// ses 10 bantlı ekolayzırdan ve ön kazançtan geçip aynı çıkış cihazına çalınır. Sürücü kurulmaz.
// Kapalıyken hiçbir şey yapılmaz, izin de istenmez. Çıkış cihazı değişince kendini yeniden kurar.

enum EQSettings {
    private static let d = UserDefaults.standard
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static var enabled: Bool {
        get { d.bool(forKey: "eq.enabled") }
        set { d.set(newValue, forKey: "eq.enabled") }
    }
    /// Ön kazanç (dB, -12…+12)
    static var preamp: Double {
        get { d.object(forKey: "eq.preamp") as? Double ?? 0 }
        set { d.set(newValue, forKey: "eq.preamp") }
    }
    /// Bant kazançları (dB, -12…+12)
    static var gains: [Double] {
        get {
            let g = d.array(forKey: "eq.gains") as? [Double] ?? []
            return g.count == frequencies.count ? g : Array(repeating: 0, count: frequencies.count)
        }
        set { d.set(newValue, forKey: "eq.gains") }
    }

    static let presets: [(name: String, gains: [Double])] = [
        (L("Düz"), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        (L("Bas"), [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        (L("Tiz"), [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        (L("Konuşma"), [-4, -3, -1, 0, 2, 3, 3, 2, 0, -2]),
        (L("Gece"), [-6, -4, -2, 0, 0, 0, 0, -1, -2, -3]),
    ]
}

/// Tek kanal için 2. derece tepe süzgeci (RBJ "peaking EQ")
private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func peaking(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let f = min(freq, sampleRate * 0.45)
        let A = pow(10, gainDB / 40)
        let w = 2 * Double.pi * f / sampleRate
        let alpha = sin(w) / (2 * q)
        let c = cos(w)
        let a0 = 1 + alpha / A
        var b = Biquad()
        b.b0 = (1 + alpha * A) / a0
        b.b1 = (-2 * c) / a0
        b.b2 = (1 - alpha * A) / a0
        b.a1 = (-2 * c) / a0
        b.a2 = (1 - alpha / A) / a0
        return b
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Ses iş parçacığının kullandığı durum (kilitsiz okunur; ayar değişince yeni katsayılar hazırlanır)
private final class EQState: @unchecked Sendable {
    var filters: [[Biquad]] = []      // [kanal][bant]
    var gain: Double = 1
    var flat = true
    private var lock = os_unfair_lock()
    private var pending: (filters: [Biquad], gain: Double, flat: Bool)?

    func prepare(sampleRate: Double, channels: Int) {
        let p = Self.design(sampleRate: sampleRate)
        os_unfair_lock_lock(&lock)
        filters = Array(repeating: p.filters, count: max(1, channels))
        gain = p.gain
        flat = p.flat
        pending = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Ayar değişti: yeni katsayılar bir sonraki ses bloğunda devreye girer (kayıtlı süzgeç durumları korunur)
    func update(sampleRate: Double) {
        let p = Self.design(sampleRate: sampleRate)
        os_unfair_lock_lock(&lock)
        pending = p
        os_unfair_lock_unlock(&lock)
    }

    private static func design(sampleRate: Double) -> (filters: [Biquad], gain: Double, flat: Bool) {
        let gains = EQSettings.gains
        let f = zip(EQSettings.frequencies, gains).map { Biquad.peaking(freq: $0.0, gainDB: $0.1, q: 1.2, sampleRate: sampleRate) }
        let flat = gains.allSatisfy { abs($0) < 0.05 } && abs(EQSettings.preamp) < 0.05
        return (f, pow(10, EQSettings.preamp / 20), flat)
    }

    /// Ses iş parçacığında: bekleyen katsayıları kilit beklemeden al
    @inline(__always) func applyPending() {
        guard os_unfair_lock_trylock(&lock) else { return }
        if let p = pending {
            for c in filters.indices {
                for b in filters[c].indices where b < p.filters.count {
                    let z1 = filters[c][b].z1, z2 = filters[c][b].z2
                    filters[c][b] = p.filters[b]
                    filters[c][b].z1 = z1
                    filters[c][b].z2 = z2
                }
            }
            gain = p.gain
            flat = p.flat
            pending = nil
        }
        os_unfair_lock_unlock(&lock)
    }
}

@MainActor final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    /// Bu macOS sürümünde çalışır mı (process tap: macOS 14.2+)
    static var available: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let state = EQState()
    private var sampleRate: Double = 48_000
    private var listening = false

    /// Ayarlara göre aç / kapat
    func apply() {
        if EQSettings.enabled { start() } else { stop() }
    }

    /// Kazançlar değişti: çalışırken anında uygula
    func settingsChanged() {
        state.update(sampleRate: sampleRate)
    }

    func start() {
        guard Self.available, EQSettings.enabled else { return }
        stop()
        guard #available(macOS 14.2, *) else { return }
        do {
            try build()
            running = true
            lastError = nil
        } catch {
            teardown()
            running = false
            lastError = error.localizedDescription
        }
        listenForOutputChanges()
    }

    func stop() {
        teardown()
        running = false
    }

    // MARK: Kurulum

    private struct EQError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @available(macOS 14.2, *)
    private func build() throws {
        let output = try Self.defaultOutputDevice()
        let outputUID = try Self.uid(of: output)

        // 1) Sistemin sesini yakala (Missing hariç), asıl çıkışta sustur
        var excluded: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { excluded.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        desc.name = "Missing EQ"
        var tap: AudioObjectID = 0
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != 0 else { throw EQError(message: L("Sistem sesi yakalanamadı (%@)", "\(st)")) }
        tapID = tap

        // 2) Yakalanan ses + gerçek çıkış: özel bir birleşik cihaz
        let aggUID = "com.firewallstudio.missing.eq.\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Missing EQ",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg: AudioObjectID = 0
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr, agg != 0 else { throw EQError(message: L("Ses cihazı kurulamadı (%@)", "\(st)")) }
        aggregateID = agg

        // 3) Biçim: yakalanan sesin örnekleme hızı ve kanal sayısı
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        if st == noErr, asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
        state.prepare(sampleRate: sampleRate, channels: Int(max(2, asbd.mChannelsPerFrame)))

        // 4) Ses bloğu: girişi süzgeçlerden geçir, çıkışa yaz
        let state = self.state
        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, outData, _ in
            Equalizer.render(state, inData, outData)
        }
        guard st == noErr, let proc else { throw EQError(message: L("Ses işleme başlatılamadı (%@)", "\(st)")) }
        procID = proc
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else { throw EQError(message: L("Ses işleme başlatılamadı (%@)", "\(st)")) }
    }

    private func teardown() {
        if aggregateID != 0, let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = 0
        if tapID != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
    }

    /// Ses iş parçacığı: hiçbir bellek ayırmaz, kilit beklemez
    private nonisolated static func render(_ state: EQState, _ inData: UnsafePointer<AudioBufferList>,
                                           _ outData: UnsafeMutablePointer<AudioBufferList>) {
        state.applyPending()
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        guard !ins.isEmpty, !outs.isEmpty else { return }
        let inCount = inputChannelCount(ins)
        var ch = 0
        for b in outs {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mNumberChannels)
            guard n > 0 else { continue }
            let frames = Int(b.mDataByteSize) / (4 * n)
            for c in 0..<n {
                let o = p + c
                guard inCount > 0, let src = inputChannel(ins, min(ch, inCount - 1)) else {
                    for i in 0..<frames { o[i * n] = 0 }
                    continue
                }
                let count = min(frames, src.2)
                let fi = min(ch, state.filters.count - 1)
                if state.flat || fi < 0 {
                    for i in 0..<count { o[i * n] = src.0[i * src.1] }
                } else {
                    let g = state.gain
                    for i in 0..<count {
                        var x = Double(src.0[i * src.1]) * g
                        for k in state.filters[fi].indices { x = state.filters[fi][k].process(x) }
                        o[i * n] = Float(max(-1, min(1, x)))   // taşmayı kırp
                    }
                }
                for i in count..<frames { o[i * n] = 0 }
                ch += 1
            }
        }
    }

    /// Girişteki toplam kanal sayısı (bellek ayırmadan)
    @inline(__always) private nonisolated static func inputChannelCount(_ ins: UnsafeMutableAudioBufferListPointer) -> Int {
        var n = 0
        for b in ins where b.mData != nil { n += Int(b.mNumberChannels) }
        return n
    }

    /// Girişin idx'inci kanalı: (veri, adım, kare sayısı)
    @inline(__always) private nonisolated static func inputChannel(_ ins: UnsafeMutableAudioBufferListPointer,
                                                                   _ idx: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var k = idx
        for b in ins {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mNumberChannels)
            guard n > 0 else { continue }
            if k < n { return (p + k, n, Int(b.mDataByteSize) / (4 * n)) }
            k -= n
        }
        return nil
    }

    // MARK: Çıkış cihazı değişince yeniden kur

    private func listenForOutputChanges() {
        guard !listening else { return }
        listening = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, EQSettings.enabled else { return }
                self.start()
            }
        }
    }

    // MARK: Yardımcılar

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard st == noErr, id != 0 else { throw EQError(message: L("Çıkış cihazı bulunamadı")) }
        return id
    }

    private static func uid(of device: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard st == noErr, let u = uid?.takeRetainedValue() else { throw EQError(message: L("Çıkış cihazı bulunamadı")) }
        return u as String
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var p = pid
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return st == noErr && obj != 0 ? obj : nil
    }
}
