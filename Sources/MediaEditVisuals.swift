import AVFoundation
import Accelerate
import CoreGraphics

// MARK: - Düzenleyici: küçük resimler ve dalga biçimi
//
// Küçük resimler AVAssetImageGenerator ile, kare tam olmadan (toleranslı) ve küçük boyutta alınır;
// kaynak + zaman + yüksekliğe göre önbelleğe girer, düzenleme yeniden hesaplatmaz.
// Dalga biçimi her kaynak için bir kez, dosya akış hâlinde okunarak çıkarılır: yalnızca saniyede
// 100…1000 tepe değeri bellekte kalır (1 saatlik dosya ≈ 1,4 MB). Zaman çizelgesi değişince
// yalnızca bu tepe değerlerinden yeniden toplanır.

/// Bir kaynağın tepe değerleri: `peaks[i]`, kaynak zamanında [i/bps, (i+1)/bps) aralığının en büyük genliği (0…1)
struct MediaPeaks: Sendable {
    let binsPerSecond: Double
    let peaks: [Float]

    /// Ses izini akış hâlinde okur; iptal edilirse nil döner.
    static func read(_ src: MediaSource) -> MediaPeaks? {
        guard let track = src.audioTrack, let reader = try? AVAssetReader(asset: src.asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let dur = max(0.001, src.duration.seconds)
        let bps = max(100, min(1000, 300_000 / dur))
        var peaks = [Float](repeating: 0, count: Int((dur * bps).rounded(.up)) + 1)
        var scratch: [Float] = []

        while true {
            if Task.isCancelled { reader.cancelReading(); return nil }
            let more: Bool = autoreleasepool {
                guard let sb = output.copyNextSampleBuffer() else { return false }
                guard let fmt = CMSampleBufferGetFormatDescription(sb),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
                      let bb = CMSampleBufferGetDataBuffer(sb) else { return true }
                let ch = max(1, Int(asbd.mChannelsPerFrame))
                let sr = asbd.mSampleRate > 0 ? asbd.mSampleRate : src.sampleRate
                let frames = CMSampleBufferGetNumSamples(sb)
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                guard frames > 0, pts.isFinite else { return true }

                var lenAt = 0, total = 0
                var raw: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &lenAt, totalLengthOut: &total,
                                                  dataPointerOut: &raw) == kCMBlockBufferNoErr else { return true }
                let count = min(frames * ch, total / MemoryLayout<Float>.size)
                let process: (UnsafePointer<Float>) -> Void = { p in
                    var f = 0
                    let usable = count / ch
                    while f < usable {
                        let t = pts + Double(f) / sr
                        let bin = Int(t * bps)
                        var fEnd = Int(((Double(bin + 1) / bps - pts) * sr).rounded(.up))
                        fEnd = min(usable, max(f + 1, fEnd))
                        var m: Float = 0
                        vDSP_maxmgv(p + f * ch, 1, &m, vDSP_Length((fEnd - f) * ch))
                        if bin >= 0 {
                            if bin >= peaks.count { peaks.append(contentsOf: repeatElement(0, count: bin - peaks.count + 1)) }
                            if m > peaks[bin] { peaks[bin] = min(1, m) }
                        }
                        f = fEnd
                    }
                }
                if lenAt >= total, let raw {
                    raw.withMemoryRebound(to: Float.self, capacity: count) { process(UnsafePointer($0)) }
                } else {
                    if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                    scratch.withUnsafeMutableBytes { buf in
                        _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                                       destination: buf.baseAddress!)
                    }
                    scratch.withUnsafeBufferPointer { process($0.baseAddress!) }
                }
                return true
            }
            if !more { break }
        }
        guard reader.status == .completed else { return nil }
        return MediaPeaks(binsPerSecond: bps, peaks: peaks)
    }
}

extension MediaEditProject {
    // MARK: Küçük resim

    /// `maxHeight` piksel cinsindendir. Görüntüsüz parça (video projesinde) siyah kare verir; ses projesinde nil.
    func thumbnail(at time: CMTime, maxHeight: CGFloat) async -> CGImage? {
        guard kind == .video, maxHeight >= 1, let (i, off) = locate(time) else { return nil }
        let seg = segments[i]
        let h = Int(maxHeight.rounded())
        guard seg.hasVideo, let src = sources[seg.source] else { return Self.blackImage(aspect: renderSize, height: h) }

        var st = seg.range.start + off
        if st >= seg.range.end { st = max(seg.range.start, seg.range.end - src.frameDuration) }
        let key = "\(src.url.path)#\(h)#\(Int((st.seconds * 5).rounded()))"
        if let img = thumbCache[key] { return img }
        guard !Task.isCancelled else { return nil }

        let gkey = "\(src.url.path)#\(h)"
        let gen: AVAssetImageGenerator
        if let g = thumbGenerators[gkey] { gen = g } else {
            gen = AVAssetImageGenerator(asset: src.asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: CGFloat(h) * 4, height: CGFloat(h))
            let tol = CMTime(value: 1, timescale: 5)
            gen.requestedTimeToleranceBefore = tol
            gen.requestedTimeToleranceAfter = tol
            thumbGenerators[gkey] = gen
        }
        guard let img = try? await gen.image(at: st).image else { return nil }
        if thumbCache[key] == nil {
            thumbCache[key] = img
            thumbOrder.append(key)
            if thumbOrder.count > 400 { thumbCache[thumbOrder.removeFirst()] = nil }
        }
        return img
    }

    static func blackImage(aspect: CGSize, height: Int) -> CGImage? {
        let w = aspect.height > 0 ? max(1, Int((CGFloat(height) * aspect.width / aspect.height).rounded())) : height
        guard let ctx = CGContext(data: nil, width: w, height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: height))
        return ctx.makeImage()
    }

    // MARK: Dalga biçimi

    func waveform(buckets: Int) async -> [Float] {
        guard buckets > 0 else { return [] }
        let segs = segments
        let total = duration.seconds
        guard total > 0 else { return [Float](repeating: 0, count: buckets) }

        var table: [URL: MediaPeaks] = [:]
        for url in Set(segs.filter { $0.hasAudio }.map { $0.source }) {
            if Task.isCancelled { return [] }
            if let p = await peaks(for: url) { table[url] = p }
        }
        if Task.isCancelled { return [] }

        // Parçaların zaman çizelgesindeki yerleri
        var items: [(start: Double, dur: Double, srcStart: Double, peaks: MediaPeaks)] = []
        var t = CMTime.zero
        for s in segs {
            if s.hasAudio, let p = table[s.source] { items.append((t.seconds, s.duration.seconds, s.range.start.seconds, p)) }
            t = t + s.duration
        }
        return await Task.detached(priority: .userInitiated) {
            var out = [Float](repeating: 0, count: buckets)
            let bd = total / Double(buckets)
            for it in items {
                let e = it.start + it.dur
                let b0 = max(0, Int(it.start / bd))
                let b1 = min(buckets - 1, Int((e / bd).rounded(.up)) - 1)
                guard b1 >= b0 else { continue }
                let pk = it.peaks.peaks, bps = it.peaks.binsPerSecond
                for b in b0...b1 {
                    let t0 = max(it.start, Double(b) * bd), t1 = min(e, Double(b + 1) * bd)
                    guard t1 > t0, !pk.isEmpty else { continue }
                    let s0 = it.srcStart + (t0 - it.start), s1 = it.srcStart + (t1 - it.start)
                    let i0 = min(pk.count - 1, max(0, Int(s0 * bps)))
                    let i1 = min(pk.count - 1, max(i0, Int((s1 * bps).rounded(.up)) - 1))
                    var m: Float = 0
                    pk.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + i0, 1, &m, vDSP_Length(i1 - i0 + 1)) }
                    if m > out[b] { out[b] = min(1, max(0, m)) }
                }
            }
            return out
        }.value
    }

    /// Kaynağın tepe değerleri; ilk istekte arka planda bir kez okunur, aynı anda gelen istekler aynı okumayı bekler.
    func peaks(for url: URL) async -> MediaPeaks? {
        if let p = peakCache[url] { return p }
        guard let src = sources[url], src.hasAudio else { return nil }
        let task: Task<MediaPeaks?, Never>
        if let t = peakTasks[url] { task = t } else {
            task = Task.detached(priority: .utility) { MediaPeaks.read(src) }
            peakTasks[url] = task
            backgroundTasks.add(url) { task.cancel() }
        }
        let p = await task.value
        peakTasks[url] = nil
        backgroundTasks.remove(url)
        if let p { peakCache[url] = p }
        return p
    }
}
