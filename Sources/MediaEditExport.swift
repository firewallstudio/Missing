import AVFoundation
import CoreAudio

// MARK: - Düzenleyici: kaydetme ve dışa aktarma
//
// Zaman çizelgesi hep önce hedef klasörde gizli bir geçici dosyaya yazılır. Bitince:
//  • üzerine yaz: asıl dosya Çöp Sepeti'ne taşınır (geri alınabilir), yenisi aynı ada konur;
//  • yeni dosya: "Ad (düzenlendi).uzantı", varsa "… 2", "… 3";
//  • dışa aktar: seçilen yer; orada dosya varsa o da önce Çöp Sepeti'ne gider.
// Hata ya da iptalde geçici dosya silinir, asıl dosyaya dokunulmaz.
// Parçaların hepsi aynı biçimdeyse ve hedef kap bu kodekleri taşıyorsa yeniden kodlamadan (pass-through)
// kopyalanır; oturum bunu yapamazsa kendiliğinden en yüksek kalitede yeniden kodlamaya geçilir.
// WAV/AIFF/CAF doğrusal PCM olarak AVAssetReader + AVAssetWriter ile yazılır (kaynağın örnekleme hızı,
// en çok iki kanal). Ortak üst veri (başlık, sanatçı, tarih…) oturumla yazılan biçimlere aktarılır;
// üzerine yazmada dosyanın oluşturulma tarihi korunur.

enum MediaExportFormat: String, CaseIterable, Identifiable {
    case mp4H264, mp4HEVC, mov, m4a, wav, aiff, caf

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .mov: return "mov"
        case .m4a: return "m4a"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        }
    }

    var title: String {
        switch self {
        case .mp4H264: return "MP4 (H.264)"
        case .mp4HEVC: return "MP4 (HEVC)"
        case .mov: return "MOV (QuickTime)"
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        }
    }

    var isAudioOnly: Bool {
        switch self {
        case .m4a, .wav, .aiff, .caf: return true
        default: return false
        }
    }

    var isPCM: Bool { self == .wav || self == .aiff || self == .caf }

    var fileType: AVFileType {
        switch self {
        case .mp4H264, .mp4HEVC: return .mp4
        case .mov: return .mov
        case .m4a: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return .caf
        }
    }

    private static var hevcAvailable: Bool {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }

    @MainActor static func available(for project: MediaEditProject) -> [MediaExportFormat] {
        let audio: [MediaExportFormat] = [.m4a, .wav, .aiff, .caf]
        guard project.kind == .video else { return audio }
        return (hevcAvailable ? [.mp4H264, .mp4HEVC, .mov] : [.mp4H264, .mov]) + audio
    }

    /// Uzantıya göre yazabildiğimiz biçim (.mp3, .mkv, .webm, .flac… için nil). .mp4/.m4v için H.264 döner;
    /// proje, asıl dosya HEVC ise bunu `originalFormat` içinde HEVC'ye çevirir.
    static func matching(_ url: URL) -> MediaExportFormat? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return .mp4H264
        case "mov", "qt": return .mov
        case "m4a": return .m4a
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "caf", "caff": return .caf
        default: return nil
        }
    }
}

enum MediaSaveMode {
    case overwrite
    case newFile
    case export(URL, MediaExportFormat)
}

/// Süren bir kaydetme; ilerlemesi ana iş parçacığından okunabilir, iptal her yerden, istenen anda çağrılabilir.
///
/// Durum tek kilitle korunur, böylece iptal ile başlatma yarışamaz:
///  • oturum `start` ile kilit altında başlatılır; iptal önce geldiyse oturum hiç başlatılmaz,
///    sonra geldiyse yalnızca başlamış oturuma `cancelExport()` gönderilir (başlamamış oturuma asla);
///  • dosyanın yerine konması `beginCommit` ile kilit altında başlar: o andan sonra gelen iptal
///    yok sayılır ve kaydetme tamamlanır; daha önce gelen iptal her şeyi geri alır (geçici dosya silinir,
///    asıl dosyaya ve Çöp Sepeti'ne dokunulmaz). Böylece dönen sonuç her zaman diskteki durumla aynıdır;
///  • iki kez ya da bittikten sonra çağrılan `cancel()` hiçbir şey yapmaz.
final class MediaExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var _progress = 0.0
    private var _cancelled = false
    private var _committed = false
    private var _usedPassthrough = false
    private var session: AVAssetExportSession?
    private var sessionStarted = false

    var progress: Double {
        lock.lock(); defer { lock.unlock() }
        if let s = session, sessionStarted { return min(1, max(0, Double(s.progress))) }
        return _progress
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    /// Yazım yeniden kodlamadan mı yapıldı (bittikten sonra anlamlı)
    var usedPassthrough: Bool { lock.lock(); defer { lock.unlock() }; return _usedPassthrough }

    func cancel() {
        lock.lock()
        guard !_cancelled, !_committed else { lock.unlock(); return }
        _cancelled = true
        let s = sessionStarted ? session : nil
        lock.unlock()
        // Yalnızca başlatılmış oturum durdurulur; başlatılmamış olan zaten hiç başlatılmayacak
        s?.cancelExport()
    }

    /// Oturumu kilit altında başlatır. İptal önce geldiyse başlatmaz ve false döner.
    func start(_ s: AVAssetExportSession, completion: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_cancelled else { return false }
        session = s
        sessionStarted = true
        s.exportAsynchronously(completionHandler: completion)
        return true
    }

    /// Bitmiş ya da başarısız oturumu bırakır (kopyalamadan yeniden kodlamaya geçerken)
    func detachSession(progress p: Double = 0) {
        lock.lock(); session = nil; sessionStarted = false; _progress = p; lock.unlock()
    }

    /// Dosyayı yerine koymaya başlamadan çağrılır. İptal önce geldiyse false döner; true döndükten sonra iptal yok sayılır.
    func beginCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_cancelled else { return false }
        _committed = true
        return true
    }

    func setProgress(_ p: Double) { lock.lock(); _progress = p; lock.unlock() }
    func setPassthrough(_ v: Bool) { lock.lock(); _usedPassthrough = v; lock.unlock() }
}

extension MediaEditProject {
    /// Asıl dosyanın yazılabilir biçimi (uzantıdan; .mp4 HEVC ise mp4HEVC). Yazılamıyorsa nil.
    var originalFormat: MediaExportFormat? {
        guard let f = MediaExportFormat.matching(original) else { return nil }
        if kind == .video && f.isAudioOnly { return nil }
        if f == .mp4H264 && originalSource.isHEVC { return .mp4HEVC }
        return f
    }

    var canOverwrite: Bool {
        originalFormat != nil && FileManager.default.isWritableFile(atPath: original.deletingLastPathComponent().path)
    }

    /// `.newFile` ile yazılacak biçim: asıl dosyanınki, yazılamıyorsa en yakını (mp3 → m4a, flac → wav…)
    var newFileFormat: MediaExportFormat {
        if let f = originalFormat { return f }
        if kind == .video { return originalSource.isHEVC ? .mp4HEVC : .mp4H264 }
        return originalSource.isLosslessAudio ? .wav : .m4a
    }

    func suggestedNewFileURL() -> URL {
        let dir = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let ext = originalFormat != nil ? original.pathExtension : newFileFormat.fileExtension
        let stem = "\(base) (\(L("düzenlendi")))"
        let fm = FileManager.default
        var url = dir.appendingPathComponent(stem).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    func save(_ mode: MediaSaveMode, job: @escaping (MediaExportJob) -> Void, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        var dest: URL
        let format: MediaExportFormat
        switch mode {
        case .overwrite:
            guard canOverwrite, let f = originalFormat else { throw MediaEditError.unsupportedFormat }
            dest = original; format = f
        case .newFile:
            dest = suggestedNewFileURL(); format = newFileFormat
        case .export(let u, let f):
            if kind == .audio && !f.isAudioOnly && f != originalFormat { throw MediaEditError.unsupportedFormat }
            dest = u; format = f
        }

        let dir = dest.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(dest.deletingPathExtension().lastPathComponent).missing-\(UUID().uuidString.prefix(8)).\(format.fileExtension)")
        let theJob = MediaExportJob()
        job(theJob)
        progress(0)

        do {
            let used = try await withTaskCancellationHandler {
                try await self.write(to: tmp, format: format, job: theJob, progress: progress)
            } onCancel: {
                theJob.cancel()
            }
            if Task.isCancelled { theJob.cancel() }
            // Bu noktadan sonra iptal yok sayılır: ya her şey geri alınır (aşağıdaki throw), ya kaydetme tamamlanır
            guard theJob.beginCommit() else { throw MediaEditError.cancelled }

            switch mode {
            case .overwrite:
                let created = (try? fm.attributesOfItem(atPath: original.path))?[.creationDate]
                var trashed: NSURL?
                try fm.trashItem(at: original, resultingItemURL: &trashed)
                do {
                    try fm.moveItem(at: tmp, to: original)
                } catch {
                    if let t = trashed as URL? { try? fm.moveItem(at: t, to: original) }
                    throw error
                }
                if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: original.path) }
                lastTrashedURL = trashed as URL?
            case .newFile:
                if fm.fileExists(atPath: dest.path) { dest = suggestedNewFileURL() }
                try fm.moveItem(at: tmp, to: dest)
            case .export:
                if fm.fileExists(atPath: dest.path) {
                    var trashed: NSURL?
                    try fm.trashItem(at: dest, resultingItemURL: &trashed)
                    lastTrashedURL = trashed as URL?
                }
                try fm.moveItem(at: tmp, to: dest)
            }
            theJob.setPassthrough(used)
            lastSaveUsedPassthrough = used
            theJob.setProgress(1)
            progress(1)
            return dest
        } catch {
            try? fm.removeItem(at: tmp)
            if theJob.isCancelled || error is CancellationError { throw MediaEditError.cancelled }
            if let e = error as? MediaEditError { throw e }
            throw MediaEditError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: Yazma

    /// Geçici dosyaya yazar; yeniden kodlamadan yazıldıysa true döner.
    private func write(to tmp: URL, format: MediaExportFormat, job: MediaExportJob,
                       progress: @escaping (Double) -> Void) async throws -> Bool {
        let built = buildComposition(includeVideo: !format.isAudioOnly)
        guard built.hasVideo || built.hasAudio else { throw MediaEditError.unsupportedFormat }
        if format.isPCM {
            guard built.hasAudio else { throw MediaEditError.unsupportedFormat }
            try await writePCM(built.composition, to: tmp, format: format, job: job, progress: progress)
            return false
        }
        let comp = built.composition
        if passthroughPossible(format, built) {
            if try await runExport(comp, preset: AVAssetExportPresetPassthrough, videoComposition: nil, format: format,
                                   to: tmp, job: job, progress: progress, mayFail: true) {
                return true
            }
            try? FileManager.default.removeItem(at: tmp)
            job.detachSession()
            if job.isCancelled || Task.isCancelled { throw MediaEditError.cancelled }
        }
        _ = try await runExport(comp, preset: reencodePreset(format, built), videoComposition: built.videoComposition,
                                format: format, to: tmp, job: job, progress: progress, mayFail: false)
        return false
    }

    private func reencodePreset(_ format: MediaExportFormat, _ built: Built) -> String {
        switch format {
        case .m4a: return AVAssetExportPresetAppleM4A
        case .mp4HEVC: return AVAssetExportPresetHEVCHighestQuality
        case .mov:
            let hevc = segments.contains { $0.hasVideo && (sources[$0.source]?.isHEVC ?? false) }
            return hevc && built.hasVideo ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        default: return AVAssetExportPresetHighestQuality
        }
    }

    /// Kopyalama ancak her parça aynı biçimdeyse, görüntü için ek işlem (döndürme/sığdırma/siyah boşluk)
    /// gerekmiyorsa ve hedef kap bu kodekleri taşıyabiliyorsa denenir.
    private func passthroughPossible(_ format: MediaExportFormat, _ built: Built) -> Bool {
        if built.videoComposition != nil { return false }
        let used = segments.compactMap { sources[$0.source] }
        if built.hasVideo {
            let vs = segments.filter { $0.hasVideo }.compactMap { sources[$0.source] }
            guard let f = vs.first, let codec = f.videoCodec else { return false }
            guard vs.allSatisfy({ $0.videoCodec == codec && $0.naturalSize == f.naturalSize && $0.transform == f.transform }) else { return false }
            let h264 = codec == kCMVideoCodecType_H264
            switch format {
            case .mp4H264: if !h264 { return false }
            case .mp4HEVC: if !f.isHEVC { return false }
            case .mov: break
            default: return false
            }
        }
        if built.hasAudio {
            let aud = segments.filter { $0.hasAudio }.compactMap { sources[$0.source] }
            guard let f = aud.first, let codec = f.audioCodec else { return false }
            guard aud.allSatisfy({ $0.audioCodec == codec && $0.sampleRate == f.sampleRate && $0.channels == f.channels }) else { return false }
            let aac = codec == kAudioFormatMPEG4AAC
            switch format {
            case .mp4H264, .mp4HEVC: if !aac { return false }
            // Denendi (macOS 26): m4a'ya AAC kopyalama tek aralıkta çalışıyor, birden çok aralıkta oturum
            // "-11838 not supported" ile duruyor ve uyumluluk sorgusu da bunu önceden söylüyor.
            case .m4a: if !(aac || codec == kAudioFormatAppleLossless) || aud.count > 1 { return false }
            case .mov: break
            default: return false
            }
        }
        return !used.isEmpty
    }

    /// Bir AVAssetExportSession çalıştırır. `mayFail` ise başarısızlıkta hata yerine false döner.
    private func runExport(_ asset: AVAsset, preset: String, videoComposition: AVVideoComposition?, format: MediaExportFormat,
                           to tmp: URL, job: MediaExportJob, progress: @escaping (Double) -> Void, mayFail: Bool) async throws -> Bool {
        if job.isCancelled || Task.isCancelled { throw MediaEditError.cancelled }
        let compatible: Bool = await withCheckedContinuation { c in
            AVAssetExportSession.determineCompatibility(ofExportPreset: preset, with: asset, outputFileType: format.fileType) { c.resume(returning: $0) }
        }
        if job.isCancelled || Task.isCancelled { throw MediaEditError.cancelled }
        guard compatible, let s = AVAssetExportSession(asset: asset, presetName: preset) else {
            if mayFail { return false }
            throw MediaEditError.unsupportedFormat
        }
        s.outputURL = tmp
        s.outputFileType = format.fileType
        s.videoComposition = videoComposition
        s.shouldOptimizeForNetworkUse = false
        if !originalSource.commonMetadata.isEmpty { s.metadata = originalSource.commonMetadata }
        if job.isCancelled || Task.isCancelled { throw MediaEditError.cancelled }

        // İlerleme yalnızca yazım sürerken okunur
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(job.progress)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        // Başlatma ile iptal aynı kilit altında: iptal önce geldiyse oturum hiç başlatılmaz
        let started: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            if !job.start(s, completion: { c.resume(returning: true) }) { c.resume(returning: false) }
        }
        poll.cancel()
        guard started else { throw MediaEditError.cancelled }
        switch s.status {
        case .completed:
            return true
        case .cancelled:
            throw MediaEditError.cancelled
        default:
            if job.isCancelled { throw MediaEditError.cancelled }
            if mayFail { return false }
            throw MediaEditError.exportFailed(s.error?.localizedDescription ?? L("Bilinmeyen hata"))
        }
    }

    /// Doğrusal PCM: kompozisyonun sesi okunur (farklı hız/kanal sayıları burada birleşir), dosyaya yazılır.
    private func writePCM(_ comp: AVComposition, to tmp: URL, format: MediaExportFormat, job: MediaExportJob,
                          progress: @escaping (Double) -> Void) async throws {
        let audioSources = segments.filter { $0.hasAudio }.compactMap { sources[$0.source] }
        guard let first = audioSources.first else { throw MediaEditError.unsupportedFormat }
        let rate = first.sampleRate
        let channels = min(2, audioSources.map { $0.channels }.max() ?? 1)
        let deep = audioSources.contains { $0.audioCodec == kAudioFormatLinearPCM && $0.bitsPerChannel > 16 }
        let bits = deep ? 24 : 16
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

        let readSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData, AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff, AVLinearPCMIsNonInterleaved: false,
        ]
        let tracks = comp.tracks.filter { $0.mediaType == .audio }
        let total = comp.duration.seconds

        let reader: AVAssetReader, writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: comp)
            writer = try AVAssetWriter(outputURL: tmp, fileType: format.fileType)
        } catch {
            throw MediaEditError.exportFailed(error.localizedDescription)
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readSettings)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writeSettings)
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else { throw MediaEditError.unsupportedFormat }
        reader.add(output)
        writer.add(input)
        if job.isCancelled || Task.isCancelled { throw MediaEditError.cancelled }
        guard reader.startReading() else { throw MediaEditError.exportFailed(reader.error?.localizedDescription ?? "") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MediaEditError.exportFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "missing.mediaedit.pcm", qos: .utility)
        var lastReported = -1.0
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    if job.isCancelled {
                        done = true; c.resume(); return
                    }
                    guard let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        done = true; c.resume(); return
                    }
                    if !input.append(sb) {
                        done = true; c.resume(); return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    if total > 0, t.isFinite {
                        let p = min(1, max(0, t / total))
                        job.setProgress(p)
                        if p - lastReported >= 0.01 {
                            lastReported = p
                            Task { @MainActor in progress(p) }
                        }
                    }
                }
            }
        }

        if job.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaEditError.cancelled
        }
        if reader.status == .failed || writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? ""
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaEditError.exportFailed(msg)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if job.isCancelled { throw MediaEditError.cancelled }
        guard writer.status == .completed else {
            throw MediaEditError.exportFailed(writer.error?.localizedDescription ?? L("Bilinmeyen hata"))
        }
    }
}
