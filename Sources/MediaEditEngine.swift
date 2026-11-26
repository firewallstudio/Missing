import AVFoundation
import Combine
import CoreGraphics

// MARK: - Ses/görüntü düzenleyici: motor
//
// Önizlemeden açılan küçük düzenleyicinin arayüzsüz yarısı. Zaman çizelgesi, kaynak dosyalardan
// alınmış aralıkların (parça) sıralı listesidir; kesme, kırpma, silme, taşıma ve araya dosya ekleme
// yalnızca bu listeyi değiştirir. Her değişiklik listenin tam kopyasını geri alma yığınına koyar.
// Oynatma ve kaydetme için liste her seferinde AVMutableComposition'a çevrilir (ucuz, dosya okumaz).
// Kaynaklarda birden çok ses izi varsa yalnızca ilk etkin ses izi kullanılır (görüntüde de ilk etkin iz).

enum MediaKind { case video, audio }                 // audio = asıl dosyada görüntü izi yok

struct MediaSegment: Identifiable, Equatable {
    let id: UUID
    let source: URL
    var range: CMTimeRange                            // kaynak dosyanın kendi zamanında
    let hasVideo: Bool
    let hasAudio: Bool
    var duration: CMTime { range.duration }

    init(id: UUID = UUID(), source: URL, range: CMTimeRange, hasVideo: Bool, hasAudio: Bool) {
        self.id = id
        self.source = source
        self.range = range
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }
}

enum MediaEditError: LocalizedError {
    case unreadable(URL), noTracks(URL), protectedContent(URL), exportFailed(String), cancelled, unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unreadable(let u): return L("Dosya açılamadı: %@", u.lastPathComponent)
        case .noTracks(let u): return L("Bu dosyada düzenlenecek ses ya da görüntü yok: %@", u.lastPathComponent)
        case .protectedContent(let u): return L("Korumalı içerik düzenlenemez: %@", u.lastPathComponent)
        case .exportFailed(let m): return L("Kaydedilemedi: %@", m)
        case .cancelled: return L("Kaydetme iptal edildi")
        case .unsupportedFormat: return L("Bu biçimde kaydedilemiyor")
        }
    }
}

// MARK: - Kaynak dosya bilgisi (bir kez yüklenir, sonra hep bellekten)

final class MediaSource: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let duration: CMTime
    let videoTrack: AVAssetTrack?
    let audioTrack: AVAssetTrack?
    let videoTimeRange: CMTimeRange
    let audioTimeRange: CMTimeRange
    let naturalSize: CGSize
    let transform: CGAffineTransform
    /// Bir kare (nominalFrameRate'ten, izin zaman ölçeğinde); görüntü yoksa 1/30
    let frameDuration: CMTime
    let videoCodec: FourCharCode?
    let audioCodec: FourCharCode?
    let sampleRate: Double
    let channels: Int
    let bitsPerChannel: Int
    let commonMetadata: [AVMetadataItem]

    var hasVideo: Bool { videoTrack != nil }
    var hasAudio: Bool { audioTrack != nil }

    /// Döndürme uygulanmış görünen boyut
    var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    var isHEVC: Bool { videoCodec.map { $0 == kCMVideoCodecType_HEVC || $0 == 0x68657631 /* hev1 */ } ?? false }
    var isLosslessAudio: Bool {
        guard let c = audioCodec else { return false }
        return c == kAudioFormatLinearPCM || c == kAudioFormatAppleLossless || c == kAudioFormatFLAC
    }

    private init(url: URL, asset: AVURLAsset, duration: CMTime, videoTrack: AVAssetTrack?, audioTrack: AVAssetTrack?,
                 videoTimeRange: CMTimeRange, audioTimeRange: CMTimeRange, naturalSize: CGSize, transform: CGAffineTransform,
                 frameDuration: CMTime, videoCodec: FourCharCode?, audioCodec: FourCharCode?, sampleRate: Double,
                 channels: Int, bitsPerChannel: Int, commonMetadata: [AVMetadataItem]) {
        self.url = url; self.asset = asset; self.duration = duration
        self.videoTrack = videoTrack; self.audioTrack = audioTrack
        self.videoTimeRange = videoTimeRange; self.audioTimeRange = audioTimeRange
        self.naturalSize = naturalSize; self.transform = transform; self.frameDuration = frameDuration
        self.videoCodec = videoCodec; self.audioCodec = audioCodec
        self.sampleRate = sampleRate; self.channels = channels; self.bitsPerChannel = bitsPerChannel
        self.commonMetadata = commonMetadata
    }

    /// Ana iş parçacığı dışında çalışır; yalnızca özellikleri yükler, dosyanın tamamını okumaz.
    static func load(_ url: URL) async throws -> MediaSource {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaEditError.unreadable(url) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime, tracks: [AVAssetTrack], protected: Bool, readable: Bool
        do {
            (duration, tracks, protected, readable) = try await asset.load(.duration, .tracks, .hasProtectedContent, .isReadable)
        } catch {
            throw MediaEditError.unreadable(url)
        }
        if protected { throw MediaEditError.protectedContent(url) }
        guard readable else { throw MediaEditError.unreadable(url) }

        var video: AVAssetTrack?, audio: AVAssetTrack?
        for t in tracks {
            let enabled = (try? await t.load(.isEnabled)) ?? true
            guard enabled else { continue }
            if t.mediaType == .video, video == nil { video = t }
            if t.mediaType == .audio, audio == nil { audio = t }
        }
        guard video != nil || audio != nil, duration.isNumeric, duration > .zero else { throw MediaEditError.noTracks(url) }

        var size = CGSize.zero, xf = CGAffineTransform.identity, fd = CMTime(value: 1, timescale: 30)
        var vCodec: FourCharCode?, vRange = CMTimeRange.zero
        if let v = video {
            do {
                let (s, t, fps, ts) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .naturalTimeScale)
                let (fds, tr) = try await v.load(.formatDescriptions, .timeRange)
                size = s; xf = t; vRange = tr
                vCodec = fds.first.map { CMFormatDescriptionGetMediaSubType($0) }
                if fps > 0 {
                    let scale = ts > 0 ? ts : 600
                    let v = CMTimeValue((Double(scale) / Double(fps)).rounded())
                    if v > 0 { fd = CMTime(value: v, timescale: scale) }
                }
            } catch {
                video = nil
            }
            if size.width < 1 || size.height < 1 { video = nil }
        }

        var aCodec: FourCharCode?, rate = 0.0, ch = 0, bits = 0, aRange = CMTimeRange.zero
        if let a = audio {
            if let (fds, tr) = try? await a.load(.formatDescriptions, .timeRange) {
                aRange = tr
                if let f = fds.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    aCodec = asbd.mFormatID
                    rate = asbd.mSampleRate
                    ch = Int(asbd.mChannelsPerFrame)
                    bits = Int(asbd.mBitsPerChannel)
                }
            } else {
                audio = nil
            }
        }
        guard video != nil || audio != nil else { throw MediaEditError.noTracks(url) }
        let meta = (try? await asset.load(.commonMetadata)) ?? []

        return MediaSource(url: url, asset: asset, duration: duration, videoTrack: video, audioTrack: audio,
                           videoTimeRange: vRange, audioTimeRange: aRange, naturalSize: size, transform: xf,
                           frameDuration: fd, videoCodec: vCodec, audioCodec: aCodec,
                           sampleRate: rate > 0 ? rate : 44100, channels: max(1, ch), bitsPerChannel: bits,
                           commonMetadata: meta)
    }
}

/// Düzenleyici kapanınca süren arka plan işlerini (dalga biçimi okuma) durdurmak için
final class MediaTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [AnyHashable: () -> Void] = [:]

    func add(_ key: AnyHashable, cancel: @escaping () -> Void) { lock.lock(); tasks[key] = cancel; lock.unlock() }
    func remove(_ key: AnyHashable) { lock.lock(); tasks[key] = nil; lock.unlock() }
    func cancelAll() {
        lock.lock(); let all = tasks.values; tasks.removeAll(); lock.unlock()
        all.forEach { $0() }
    }
}

// MARK: - Proje

@MainActor final class MediaEditProject: ObservableObject {
    let original: URL
    let kind: MediaKind
    @Published private(set) var segments: [MediaSegment]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var revision = 0

    /// Yüklenmiş kaynaklar (asıl dosya ve sonradan eklenenler)
    private(set) var sources: [URL: MediaSource]
    let originalSource: MediaSource
    private var undoStack: [[MediaSegment]] = []
    private var redoStack: [[MediaSegment]] = []

    // Görseller için önbellekler (MediaEditVisuals.swift)
    var thumbGenerators: [String: AVAssetImageGenerator] = [:]
    var thumbCache: [String: CGImage] = [:]
    var thumbOrder: [String] = []
    var peakCache: [URL: MediaPeaks] = [:]
    var peakTasks: [URL: Task<MediaPeaks?, Never>] = [:]
    nonisolated let backgroundTasks = MediaTaskBag()

    /// Son kaydetmede yeniden kodlamadan (pass-through) mı yazıldı
    var lastSaveUsedPassthrough = false
    /// Son .overwrite / .export ile Çöp Sepeti'ne taşınan eski dosya
    var lastTrashedURL: URL?

    private init(source: MediaSource) {
        original = source.url
        originalSource = source
        kind = source.hasVideo ? .video : .audio
        sources = [source.url: source]
        segments = [MediaSegment(source: source.url, range: CMTimeRange(start: .zero, duration: source.duration),
                                 hasVideo: source.hasVideo, hasAudio: source.hasAudio)]
    }

    deinit { backgroundTasks.cancelAll() }

    static func load(_ url: URL) async throws -> MediaEditProject {
        let src = try await MediaSource.load(url)
        return MediaEditProject(source: src)
    }

    /// Düzenleyici kapanırken çağrılabilir: arka plandaki okumaları durdurur, önbellekleri boşaltır
    func close() {
        backgroundTasks.cancelAll()
        thumbGenerators.values.forEach { $0.cancelAllCGImageGeneration() }
        thumbGenerators.removeAll()
        thumbCache.removeAll()
        thumbOrder.removeAll()
        peakTasks.removeAll()
    }

    // MARK: Ölçüler

    var duration: CMTime { segments.reduce(CMTime.zero) { $0 + $1.duration } }

    var isModified: Bool {
        guard segments.count == 1, let s = segments.first else { return true }
        return s.source != original || s.range != CMTimeRange(start: .zero, duration: originalSource.duration)
    }

    var renderSize: CGSize {
        guard kind == .video else { return .zero }
        let src = segments.first(where: { $0.hasVideo }).flatMap { sources[$0.source] } ?? originalSource
        let d = src.displaySize
        return CGSize(width: max(2, (d.width / 2).rounded() * 2), height: max(2, (d.height / 2).rounded() * 2))
    }

    var frameDuration: CMTime {
        kind == .video ? originalSource.frameDuration : CMTime(value: 1, timescale: 100)
    }

    func source(for seg: MediaSegment) -> MediaSource? { sources[seg.source] }

    // MARK: Kareye / örneğe hizalama

    /// Kaynak zamanında kesme noktalarının ızgarası: görüntülü kaynakta bir kare, görüntüsüz kaynakta
    /// video projesinde projenin karesi, ses projesinde bir örnek (sample).
    func snapUnit(for src: MediaSource) -> CMTime {
        if kind == .video { return src.hasVideo ? src.frameDuration : frameDuration }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, src.sampleRate.rounded())))
    }

    func snap(_ t: CMTime, _ src: MediaSource) -> CMTime {
        guard t.isNumeric else { return .zero }
        if t <= .zero { return .zero }
        if t >= src.duration { return src.duration }
        let u = snapUnit(for: src)
        let n = (t.seconds / u.seconds).rounded()
        let r = CMTime(value: u.value * CMTimeValue(n), timescale: u.timescale)
        return min(r, src.duration)
    }

    // MARK: Eşleme

    func start(of id: UUID) -> CMTime? {
        var t = CMTime.zero
        for s in segments {
            if s.id == id { return t }
            t = t + s.duration
        }
        return nil
    }

    func locate(_ time: CMTime) -> (index: Int, offset: CMTime)? {
        guard time.isNumeric, time >= .zero else { return nil }
        var s = CMTime.zero
        for (i, seg) in segments.enumerated() {
            let e = s + seg.duration
            if time < e { return (i, time - s) }
            s = e
        }
        if time == s, let last = segments.last { return (segments.count - 1, last.duration) }
        return nil
    }

    // MARK: Düzenleme (her çağrı bir geri alma adımı)

    func split(at time: CMTime) {
        guard let (i, off) = locate(time), off > .zero else { return }
        let seg = segments[i]
        guard off < seg.duration, let src = sources[seg.source] else { return }
        let p = snap(seg.range.start + off, src)
        guard p > seg.range.start, p < seg.range.end else { return }
        var a = seg
        a.range = CMTimeRange(start: seg.range.start, end: p)
        let b = MediaSegment(source: seg.source, range: CMTimeRange(start: p, end: seg.range.end),
                             hasVideo: seg.hasVideo, hasAudio: seg.hasAudio)
        var new = segments
        new.replaceSubrange(i...i, with: [a, b])
        commit(new)
    }

    func delete(_ ids: Set<UUID>) {
        let new = segments.filter { !ids.contains($0.id) }
        guard !new.isEmpty else { return }
        commit(new)
    }

    func trim(_ id: UUID, to sourceRange: CMTimeRange) {
        guard let i = segments.firstIndex(where: { $0.id == id }), let src = sources[segments[i].source],
              sourceRange.start.isNumeric, sourceRange.duration.isNumeric else { return }
        let minLen = max(frameDuration, snapUnit(for: src))
        var s = snap(sourceRange.start, src)
        var e = snap(min(sourceRange.end, src.duration), src)
        if e - s < minLen {
            e = min(src.duration, s + minLen)
            if e - s < minLen { s = max(.zero, e - minLen) }
        }
        guard e > s else { return }
        var new = segments
        new[i].range = CMTimeRange(start: s, end: e)
        commit(new)
    }

    func removeRange(_ range: CMTimeRange) {
        guard let r = clampToTimeline(range) else { return }
        var out: [MediaSegment] = []
        var s = CMTime.zero
        for seg in segments {
            let e = s + seg.duration
            defer { s = e }
            if e <= r.start || s >= r.end { out.append(seg); continue }
            guard let src = sources[seg.source] else { continue }
            var keptLeft = false
            if r.start > s {
                let cut = snap(seg.range.start + (r.start - s), src)
                if cut > seg.range.start {
                    var a = seg
                    a.range = CMTimeRange(start: seg.range.start, end: min(cut, seg.range.end))
                    out.append(a)
                    keptLeft = true
                }
            }
            if r.end < e {
                let cut = snap(seg.range.start + (r.end - s), src)
                if cut < seg.range.end {
                    out.append(MediaSegment(id: keptLeft ? UUID() : seg.id, source: seg.source,
                                            range: CMTimeRange(start: max(cut, seg.range.start), end: seg.range.end),
                                            hasVideo: seg.hasVideo, hasAudio: seg.hasAudio))
                }
            }
        }
        guard !out.isEmpty else { return }
        commit(out)
    }

    func keepOnly(_ range: CMTimeRange) {
        guard let r = clampToTimeline(range) else { return }
        var out: [MediaSegment] = []
        var s = CMTime.zero
        for seg in segments {
            let e = s + seg.duration
            defer { s = e }
            let a = max(s, r.start), b = min(e, r.end)
            guard b > a, let src = sources[seg.source] else { continue }
            let ca = snap(seg.range.start + (a - s), src)
            let cb = snap(seg.range.start + (b - s), src)
            guard cb > ca else { continue }
            var n = seg
            n.range = CMTimeRange(start: max(ca, seg.range.start), end: min(cb, seg.range.end))
            out.append(n)
        }
        guard !out.isEmpty else { return }
        commit(out)
    }

    /// `index`: parçanın taşındıktan sonraki sırası (0 = en başa, segments.count - 1 ya da fazlası = en sona)
    func move(_ id: UUID, to index: Int) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        var new = segments
        let seg = new.remove(at: i)
        new.insert(seg, at: max(0, min(index, new.count)))
        commit(new)
    }

    /// Dosyayı `index` sırasına ekler (0 = en başa, segments.count = en sona). Video projesine görüntüsüz
    /// dosya eklenebilir (o süre siyah kalır); ses projesine eklenen videonun yalnızca sesi alınır.
    @discardableResult
    func insert(_ url: URL, at index: Int) async throws -> UUID {
        let key = url
        let src: MediaSource
        if let s = sources[key] { src = s } else {
            src = try await MediaSource.load(key)
            sources[key] = src
        }
        let hasV = kind == .video && src.hasVideo
        let hasA = src.hasAudio
        guard hasV || hasA else { throw MediaEditError.noTracks(url) }
        let seg = MediaSegment(source: key, range: CMTimeRange(start: .zero, duration: src.duration), hasVideo: hasV, hasAudio: hasA)
        var new = segments
        new.insert(seg, at: max(0, min(index, new.count)))
        commit(new)
        return seg.id
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(segments)
        segments = prev
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(segments)
        segments = next
        changed()
    }

    private func commit(_ new: [MediaSegment]) {
        guard !new.isEmpty, new != segments else { return }
        undoStack.append(segments)
        redoStack.removeAll()
        segments = new
        changed()
    }

    private func changed() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        revision += 1
    }

    private func clampToTimeline(_ range: CMTimeRange) -> CMTimeRange? {
        guard range.start.isNumeric, range.duration.isNumeric else { return nil }
        let a = max(.zero, range.start), b = min(duration, range.end)
        return b > a ? CMTimeRange(start: a, end: b) : nil
    }

    // MARK: Kompozisyon

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let hasVideo: Bool
        let hasAudio: Bool
    }

    /// Zaman çizelgesini tek görüntü + tek ses izli bir kompozisyona çevirir. Görüntüsüz parçalar görüntü
    /// izinde boş (siyah), sessiz parçalar ses izinde boş kalır. Kaynak izi parçadan kısaysa boşlukla doldurulur,
    /// böylece iki iz de tam olarak zaman çizelgesi kadar sürer.
    func buildComposition(includeVideo: Bool = true, includeAudio: Bool = true) -> Built {
        let comp = AVMutableComposition()
        let wantVideo = includeVideo && kind == .video && segments.contains { $0.hasVideo }
        let wantAudio = includeAudio && segments.contains { $0.hasAudio }
        let vTrack = wantVideo ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let aTrack = wantAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        var cursor = CMTime.zero
        var spans: [(start: CMTime, src: MediaSource)] = []
        var gaps = false
        for seg in segments {
            let src = sources[seg.source]
            if let vt = vTrack {
                if seg.hasVideo, let src, let st = src.videoTrack {
                    if insert(seg.range, of: st, trackRange: src.videoTimeRange, into: vt, at: cursor) { gaps = true }
                    spans.append((cursor, src))
                } else {
                    vt.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: seg.duration))
                    gaps = true
                }
            }
            if let at = aTrack {
                if seg.hasAudio, let src, let st = src.audioTrack {
                    _ = insert(seg.range, of: st, trackRange: src.audioTimeRange, into: at, at: cursor)
                } else {
                    at.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: seg.duration))
                }
            }
            cursor = cursor + seg.duration
        }

        var vc: AVMutableVideoComposition?
        if let vt = vTrack, let first = spans.first?.src {
            let R = renderSize
            let uniform = spans.allSatisfy { $0.src.naturalSize == first.naturalSize && $0.src.transform == first.transform }
            let d = first.displaySize
            if !gaps && uniform && abs(d.width - R.width) < 2.5 && abs(d.height - R.height) < 2.5 {
                vt.preferredTransform = first.transform
            } else {
                // Her parça için ayrı talimat: görüntülü parçada kaynağı dikleştirip sığdıran katman,
                // görüntüsüz parçada katmansız talimat (yalnızca siyah zemin; son kare ekranda kalmaz).
                let c = AVMutableVideoComposition()
                c.renderSize = R
                c.frameDuration = frameDuration
                var list: [AVMutableVideoCompositionInstruction] = []
                var t = CMTime.zero
                for seg in segments {
                    let ins = AVMutableVideoCompositionInstruction()
                    ins.timeRange = CMTimeRange(start: t, duration: seg.duration)
                    ins.backgroundColor = CGColor(gray: 0, alpha: 1)
                    if seg.hasVideo, let src = sources[seg.source], src.hasVideo {
                        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                        li.setTransform(Self.fitTransform(src, into: R), at: t)
                        ins.layerInstructions = [li]
                    } else {
                        ins.layerInstructions = []
                    }
                    list.append(ins)
                    t = t + seg.duration
                }
                c.instructions = list
                vc = c
            }
        }
        return Built(composition: comp, videoComposition: vc, hasVideo: vTrack != nil, hasAudio: aTrack != nil)
    }

    /// Parçanın kaynak izinde karşılığı olmayan kısmını boşlukla doldurarak ekler. Boşluk kaldıysa true döner.
    private func insert(_ range: CMTimeRange, of track: AVAssetTrack, trackRange: CMTimeRange,
                        into ct: AVMutableCompositionTrack, at cursor: CMTime) -> Bool {
        let r = range.intersection(trackRange)
        guard r.duration > .zero else {
            ct.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            return true
        }
        var gap = false
        let pre = r.start - range.start
        if pre > .zero { ct.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: pre)); gap = true }
        do {
            try ct.insertTimeRange(r, of: track, at: cursor + pre)
        } catch {
            ct.insertEmptyTimeRange(CMTimeRange(start: cursor + pre, duration: r.duration))
            gap = true
        }
        let post = range.end - r.end
        if post > .zero { ct.insertEmptyTimeRange(CMTimeRange(start: cursor + pre + r.duration, duration: post)); gap = true }
        return gap
    }

    /// Kaynağı döndürüp `R` içine en-boy oranını koruyarak ortalar
    static func fitTransform(_ src: MediaSource, into R: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: src.naturalSize).applying(src.transform)
        var m = src.transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let d = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard d.width > 0, d.height > 0 else { return m }
        let s = min(R.width / d.width, R.height / d.height)
        m = m.concatenating(CGAffineTransform(scaleX: s, y: s))
        return m.concatenating(CGAffineTransform(translationX: (R.width - d.width * s) / 2, y: (R.height - d.height * s) / 2))
    }

    /// Şimdiki hâlin oynatılabilir öğesi (oynatıcıyı arayüz kurar)
    func makePlayerItem() -> AVPlayerItem {
        let b = buildComposition()
        let item = AVPlayerItem(asset: b.composition)
        item.videoComposition = b.videoComposition
        return item
    }
}
