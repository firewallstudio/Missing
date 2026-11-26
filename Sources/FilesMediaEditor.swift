import AppKit
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dosyalar: küçük ses / video düzenleyici
//
// Önizlemedeki makas düğmesinden ya da sağ tıktaki "Düzenle…" ile açılır. Her dosya için bir pencere; aynı dosya
// yeniden açılınca var olan pencere öne gelir. Pencere anahtar olur (klavye kısayolları ona gider).
// Üstte sahne (video: görüntü, ses: büyük dalga biçimi), altta araç şeridi ve zaman çizelgesi (AppKit, bkz.
// FilesMediaEditorTimeline.swift). İşlerin hepsi MediaEditProject'te (MediaEditEngine.swift); burası yalnız arayüz.
//
// missing: koyu cam, kırmızı vurgu · finder: sistem penceresi ve denetimleri · windows: Windows 11 yüzeyi, başlık
// şeridi, köşe 4 düğmeler · glass: ince cam, mor vurgu. finder / windows / glass sistemin açık/koyu ayarını izler.
//
// Yük: açık düzenleyici yoksa hiçbir şey çalışmaz. Oynatırken yalnız ekranla eş zamanlı oynatma başı güncellemesi
// (CVDisplayLink) çalışır, duraklayınca durur. Küçük resim ve dalga biçimi yalnız görünen kısım için, gerektiğinde
// istenir, önbelleğe alınır; pencere kapanınca istekler iptal edilir, oynatıcı bırakılır. Uygulama uzun süre arkada
// kalırsa oynatıcı bırakılır (geri gelince yeniden kurulur).

@MainActor enum FilesMediaEditor {
    /// Açık düzenleyiciler (dosya anahtarına göre)
    private(set) static var editors: [String: FilesMediaEditorController] = [:]

    /// Deneme düzeneği: bütün oynatıcılar sessiz (ses hiç çıkmaz)
    static var forceMute = false
    /// Uyarı / soru (deneme düzeneği yanıtı kendisi verir). `done(seçilen düğmenin sırası)`
    static var ask: (NSWindow?, String, String?, [FilesDialog.Action], @escaping (Int) -> Void) -> Void = { w, title, msg, actions, done in
        FilesDialog.show(on: w, title: title, message: msg, icon: .app, actions: actions) { i, _ in done(i) }
    }
    /// Hata (deneme düzeneği kaydeder)
    static var showError: (Error, NSWindow?) -> Void = { e, w in FilesDialog.error(e, in: w) }
    /// Eklenecek ses / video dosyalarını seç (deneme düzeneği seçimi kendisi verir)
    static var chooseFiles: (NSWindow?, @escaping ([URL]) -> Void) -> Void = { w, done in
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        panel.prompt = L("Ekle")
        panel.message = L("Eklenecek ses ya da video dosyasını seçin")
        let handle: (NSApplication.ModalResponse) -> Void = { r in done(r == .OK ? panel.urls : []) }
        if let w { panel.beginSheetModal(for: w, completionHandler: handle) } else { handle(panel.runModal()) }
    }
    /// Dışa aktarma klasörünü seç
    static var chooseFolder: (NSWindow?, URL, @escaping (URL?) -> Void) -> Void = { w, start, done in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.prompt = L("Seç")
        let handle: (NSApplication.ModalResponse) -> Void = { r in done(r == .OK ? panel.url : nil) }
        if let w { panel.beginSheetModal(for: w, completionHandler: handle) } else { handle(panel.runModal()) }
    }
    static var beep: () -> Void = { NSSound.beep() }

    /// Düzenlenebilir mi: ses ya da video dosyası (klasör / paket değil)
    static func canEdit(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]), v.isDirectory != true,
              let t = v.contentType else { return false }
        return t.conforms(to: .audiovisualContent) && !t.conforms(to: .m3uPlaylist)
    }

    /// Düzenleyiciyi aç. `controller`: geldiği Dosyalar penceresi (kaydedince yazılan dosya orada seçilir);
    /// `sourceFrame`: açılış canlandırmasının başladığı yer (ekran koordinatı).
    static func open(_ url: URL, from controller: FilesWindowController?, sourceFrame: NSRect?) {
        let key = url.fileKey
        if let e = editors[key] { e.bringToFront(); return }
        let e = FilesMediaEditorController(url: url, controller: controller)
        editors[key] = e
        e.present(from: sourceFrame)
    }

    static func editor(for url: URL) -> FilesMediaEditorController? { editors[url.fileKey] }

    fileprivate static func closed(_ e: FilesMediaEditorController) {
        if editors[e.key] === e { editors[e.key] = nil }
    }

    // MARK: Zaman yazısı

    /// "1:05.25" (saatlik dosyada "1:02:05.25"); `centis` false: "1:05"
    static func clock(_ seconds: Double, long: Bool = false, centis: Bool = true) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        let total = Int((s * 100).rounded(.down))
        let cs = total % 100, sec = (total / 100) % 60, min = (total / 6000) % 60, h = total / 360000
        var out = (h > 0 || long) ? String(format: "%d:%02d:%02d", h, min, sec) : String(format: "%d:%02d", min, sec)
        if centis { out += String(format: ".%02d", cs) }
        return out
    }

    /// Seçim uzunluğu: "2,40 sn" / "1:05.20"
    static func length(_ seconds: Double) -> String {
        if seconds < 60 {
            let f = NumberFormatter()
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
            f.minimumIntegerDigits = 1
            return L("%@ sn", f.string(from: NSNumber(value: seconds)) ?? String(format: "%.2f", seconds))
        }
        return clock(seconds)
    }
}

// MARK: - Durum

/// Oynatma başının zamanı ayrı tutulur: oynarken yalnız zaman yazısı yeniden çizilir, araç şeridi değil
@MainActor final class FilesMediaEditorClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor final class FilesMediaEditorState: ObservableObject {
    enum Overlay: Equatable { case save, progress }

    @Published var project: MediaEditProject?
    @Published var selectedID: UUID?
    /// Zaman çizelgesindeki aralık seçimi (çizelge zamanı)
    @Published var selection: CMTimeRange?
    @Published var isPlaying = false
    @Published var muted = false
    /// 0: hepsi sığar, 1: en yakın
    @Published var zoom: Double = 0
    @Published var overlay: Overlay?
    @Published var progress: Double = 0
    @Published var progressTitle = ""
    /// İlerleme kartı görünsün mü: kısa (kopyalayarak) yazımlar bir anda biter; kart ancak ~250 ms sonra gelir,
    /// o zamana kadar üst katman saydam kalır (yalnız tıkları tutar)
    @Published var progressShown = false
    let clock = FilesMediaEditorClock()
    let save = FilesMediaSaveModel()

    var hasSelection: Bool { (selection?.duration.seconds ?? 0) > 0.01 }
}

/// Kaydet penceresinin seçimleri
@MainActor final class FilesMediaSaveModel: ObservableObject {
    enum Choice { case overwrite, newFile, export }
    @Published var choice: Choice = .newFile
    @Published var name = ""
    @Published var format: MediaExportFormat = .mp4H264
    @Published var folder: URL = URL(fileURLWithPath: NSHomeDirectory())
    var formats: [MediaExportFormat] = []
    var canOverwrite = true
    var newFileName = ""
    var originalName = ""

    func reset(for project: MediaEditProject) {
        canOverwrite = project.canOverwrite
        newFileName = project.suggestedNewFileURL().lastPathComponent
        originalName = project.original.lastPathComponent
        formats = MediaExportFormat.available(for: project)
        let same = MediaExportFormat.matching(project.original)
        format = formats.first { $0 != same } ?? formats.first ?? .mp4H264
        name = project.suggestedNewFileURL().deletingPathExtension().lastPathComponent
        folder = project.original.deletingLastPathComponent()
        if choice == .overwrite && !canOverwrite { choice = .newFile }
    }

    /// Dışa aktarılacak dosya: ad + biçimin uzantısı, klasörde aynı adda dosya varsa numaralanır
    var exportURL: URL {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let n = (base.isEmpty ? L("Adsız") : base) + "." + format.fileExtension
        return FilesQuickActions.uniqueURL(n, in: folder)
    }

    var canConfirm: Bool {
        switch choice {
        case .overwrite: return canOverwrite
        case .newFile: return true
        case .export: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && formats.contains(format)
        }
    }
}

// MARK: - Pencere

/// Düzenleyici penceresi: anahtar olur; kısayollar önce buraya gelir (menüdeki ⌘Z / ⌘S / ⌘W'den önce)
final class FilesMediaEditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// CVDisplayLink iş parçacığından ana iş parçacığına bir seferde tek güncelleme gitsin
final class FilesMediaTickFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    weak var target: FilesMediaEditorController?

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pending { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); pending = false; lock.unlock()
    }
}

// MARK: - Denetleyici

@MainActor final class FilesMediaEditorController: NSObject, NSWindowDelegate {
    let url: URL
    let key: String
    private(set) weak var filesController: FilesWindowController?
    let state = FilesMediaEditorState()
    let window: FilesMediaEditorWindow
    let stage = FilesMediaStageView()
    let timeline = FilesMediaTimelineContainer()
    private(set) var player: AVPlayer?
    /// Oynatma başı (duraklamışken asıl kaynak; oynarken oynatıcıdan okunur)
    private(set) var playhead: CMTime = .zero
    private var bag = Set<AnyCancellable>()
    private var projectBag = Set<AnyCancellable>()
    private var statusObservation: NSKeyValueObservation?
    private var displayLink: CVDisplayLink?
    private let tick = FilesMediaTickFlag()
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var stageWaveTask: Task<Void, Never>?
    private(set) var job: MediaExportJob?
    /// Uygulama arkaya geçince bir süre sonra oynatıcı bırakılır
    private var releaseWork: DispatchWorkItem?
    private var closeConfirmed = false
    private(set) var isClosed = false
    /// Kaydet seçimi kapatma sorusundan geldiyse, vazgeçilirse pencere açık kalır
    private var stageWaveRevision = -1

    init(url: URL, controller: FilesWindowController?) {
        self.url = url
        self.key = url.fileKey
        self.filesController = controller
        window = FilesMediaEditorWindow(contentRect: NSRect(x: 0, y: 0, width: FilesMediaEditorLayout.defaultSize.width,
                                                            height: FilesMediaEditorLayout.defaultSize.height),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                        backing: .buffered, defer: false)
        super.init()
        tick.target = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Pencere zeminden taşınmaz (düğmelere basarken kayıyordu): taşımak için başlık şeridi
        window.isMovableByWindowBackground = false
        window.minSize = FilesMediaEditorLayout.minSize
        window.title = FileManager.default.displayName(atPath: url.path)
        window.representedURL = url
        window.delegate = self
        window.animationBehavior = .documentWindow
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }

        stage.title = window.title
        stage.icon = FileIcons.shared.icon(url)
        stage.onSeek = { [weak self] f in self?.seekFraction(f) }
        timeline.editor = self

        let root = FilesThemedRoot { _ in
            FilesMediaEditorView(state: self.state, editor: self)
        }
        let host = FilesDialogHostingView(rootView: AnyView(root.ignoresSafeArea()))
        window.contentView = host
        style()

        FilesThemeStore.shared.$theme.dropFirst().sink { [weak self] _ in
            // @Published değeri yazılmadan önce yayınlar: bir tur sonra uygula
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.style() } }
        }.store(in: &bag)
        state.$zoom.removeDuplicates().sink { [weak self] z in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timeline.zoomChanged(to: z) } }
        }.store(in: &bag)
        state.$muted.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyMute() } }
        }.store(in: &bag)
        state.$selection.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timeline.document.needsDisplay = true } }
        }.store(in: &bag)
        state.$selectedID.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timeline.document.needsDisplay = true } }
        }.store(in: &bag)
        let nc = NotificationCenter.default
        nc.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.appDeactivated() }
        }.store(in: &bag)
        nc.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.appActivated() }
        }.store(in: &bag)
        nc.publisher(for: NSWindow.willMiniaturizeNotification, object: window).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }.store(in: &bag)

        load()
    }

    // MARK: Açılış

    func present(from source: NSRect?) {
        let target = initialFrame()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let src = source, src.width > 1, src.height > 1, !reduce,
           NSScreen.screens.contains(where: { $0.frame.intersects(src) }) {
            window.alphaValue = 0
            window.setFrame(src, display: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            window.setFrame(target, display: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Geldiği Dosyalar penceresinin ekranında ortada; ekrandan büyükse sığar
    private func initialFrame() -> NSRect {
        let screen = filesController?.window?.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let d = FilesMediaEditorLayout.defaultSize
        let size = NSSize(width: min(d.width, vf.width - 40), height: min(d.height, vf.height - 40))
        var center = NSPoint(x: vf.midX, y: vf.midY)
        if let f = filesController?.window?.frame, vf.intersects(f) { center = NSPoint(x: f.midX, y: f.midY) }
        var r = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r.integral
    }

    /// Pencere çerçevesi temaya göre: finder normal başlık çubuğu; diğerleri başlıksız, içerik en üstten başlar
    func style() {
        let t = FilesThemeStore.shared.theme
        if t == .finder { window.styleMask.remove(.fullSizeContentView) } else { window.styleMask.insert(.fullSizeContentView) }
        window.titlebarAppearsTransparent = t != .finder
        window.titleVisibility = t == .finder ? .visible : .hidden
        let clear = t == .missing || t == .glass
        window.isOpaque = !clear
        window.backgroundColor = clear ? .clear : .windowBackgroundColor
        window.appearance = t == .missing ? NSAppearance(named: .darkAqua) : nil
        // windows: kendi başlık düğmelerimiz (simge durumuna küçült / büyüt / kapat) şeridin sağında
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = t == .windows
        }
        window.invalidateShadow()
    }

    private func load() {
        loadTask = Task { [weak self] in
            guard let url = self?.url else { return }
            do {
                let p = try await MediaEditProject.load(url)
                guard let self, !self.isClosed else { return }
                self.attach(p)
            } catch {
                guard let self, !self.isClosed else { return }
                FilesMediaEditor.showError(error, self.window.isVisible ? self.window : nil)
                self.closeConfirmed = true
                self.window.close()
            }
        }
    }

    private func attach(_ p: MediaEditProject) {
        state.project = p
        stage.kind = p.kind
        stage.renderSize = p.renderSize
        timeline.document.project = p
        p.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.projectChanged() } }
        }.store(in: &projectBag)
        makePlayer()
        projectChanged()
    }

    // MARK: Oynatıcı

    private func makePlayer() {
        guard player == nil, let p = state.project else { return }
        let pl = AVPlayer()
        pl.isMuted = true          // önce sessiz; ayar aşağıda
        pl.volume = FilesMediaEditor.forceMute ? 0 : 1
        pl.actionAtItemEnd = .pause
        pl.allowsExternalPlayback = false
        player = pl
        applyMute()
        pl.replaceCurrentItem(with: p.makePlayerItem())
        stage.player = p.kind == .video ? pl : nil
        statusObservation = pl.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.playbackStatusChanged() } }
        }
        if playhead > .zero { pl.seek(to: playhead, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    /// Oynatıcıyı bırak (pencere kapanınca, uygulama uzun süre arkadayken)
    func releasePlayer() {
        stopLink()
        statusObservation?.invalidate()
        statusObservation = nil
        if let pl = player {
            playhead = pl.currentTime().isValid ? clamp(pl.currentTime()) : playhead
            pl.pause()
            pl.replaceCurrentItem(with: nil)
        }
        player = nil
        stage.player = nil
        state.isPlaying = false
    }

    private func applyMute() {
        guard let pl = player else { return }
        pl.isMuted = FilesMediaEditor.forceMute || state.muted
        if FilesMediaEditor.forceMute { pl.volume = 0 }
    }

    private func appDeactivated() {
        pause()
        releaseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.releasePlayer() } }
        releaseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    private func appActivated() {
        releaseWork?.cancel()
        releaseWork = nil
        if player == nil, !isClosed { makePlayer() }
    }

    /// Düzenleme değişti: oynatıcı öğesi yeniden kurulur, oynatma başı yerinde kalır (süreden uzunsa sona çekilir)
    private func projectChanged() {
        guard let p = state.project else { return }
        playhead = clamp(playhead)
        if let sel = state.selection {
            let d = p.duration
            if sel.start >= d { state.selection = nil } else if sel.end > d { state.selection = CMTimeRange(start: sel.start, end: d) }
        }
        if let id = state.selectedID, !p.segments.contains(where: { $0.id == id }) { state.selectedID = nil }
        if let pl = player {
            let playing = pl.timeControlStatus != .paused || pl.rate != 0
            pl.pause()
            pl.replaceCurrentItem(with: p.makePlayerItem())
            pl.seek(to: playhead, toleranceBefore: .zero, toleranceAfter: .zero)
            if playing { pl.play() }
        }
        window.isDocumentEdited = p.isModified
        state.clock.time = playhead.seconds
        timeline.projectChanged()
        timeline.document.playhead = playhead
        refreshStageWave()
        stage.progress = fraction(playhead)
    }

    private func refreshStageWave() {
        guard let p = state.project, p.kind == .audio, stageWaveRevision != p.revision else { return }
        stageWaveRevision = p.revision
        stageWaveTask?.cancel()
        let rev = p.revision
        stageWaveTask = Task { [weak self, weak p] in
            guard let p else { return }
            let w = await p.waveform(buckets: 600)
            guard !Task.isCancelled, let self, !self.isClosed, p.revision == rev else { return }
            self.stage.waveform = w
        }
    }

    private func clamp(_ t: CMTime) -> CMTime {
        guard let d = state.project?.duration, t.isValid, t.isNumeric else { return .zero }
        return max(.zero, min(t, d))
    }

    private func fraction(_ t: CMTime) -> Double {
        guard let d = state.project?.duration.seconds, d > 0 else { return 0 }
        return max(0, min(1, t.seconds / d))
    }

    private func playbackStatusChanged() {
        guard let pl = player else { return }
        let playing = pl.timeControlStatus != .paused
        if state.isPlaying != playing { state.isPlaying = playing }
        if playing { startLink() } else { stopLink(); updatePlayheadFromPlayer() }
    }

    private func startLink() {
        guard displayLink == nil else { return }
        var l: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&l) == kCVReturnSuccess, let l else { return }
        let flag = tick
        CVDisplayLinkSetOutputHandler(l) { _, _, _, _, _ in
            if flag.claim() {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        flag.release()
                        flag.target?.displayTick()
                    }
                }
            }
            return kCVReturnSuccess
        }
        if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            CVDisplayLinkSetCurrentCGDisplay(l, id)
        }
        displayLink = l
        CVDisplayLinkStart(l)
    }

    private func stopLink() {
        guard let l = displayLink else { return }
        CVDisplayLinkStop(l)
        displayLink = nil
    }

    var isLinkRunning: Bool { displayLink.map { CVDisplayLinkIsRunning($0) } ?? false }

    fileprivate func displayTick() {
        guard displayLink != nil else { return }
        updatePlayheadFromPlayer()
        if player?.timeControlStatus == .paused { stopLink() }
    }

    private func updatePlayheadFromPlayer() {
        guard let pl = player, pl.currentItem != nil else { return }
        let t = pl.currentTime()
        guard t.isValid, t.isNumeric else { return }
        setPlayhead(clamp(t), follow: true)
    }

    private func setPlayhead(_ t: CMTime, follow: Bool = false) {
        playhead = t
        state.clock.time = t.seconds
        timeline.document.playhead = t
        if follow { timeline.follow(t) }
        stage.progress = fraction(t)
    }

    // MARK: İşler (araç şeridi ve kısayollar)

    var currentTime: CMTime { playhead }

    func togglePlay() {
        guard let p = state.project else { return }
        if player == nil { makePlayer() }
        guard let pl = player else { return }
        if pl.timeControlStatus != .paused || pl.rate != 0 {
            pause()
            return
        }
        // Sondaysa baştan
        if (p.duration - playhead).seconds < 0.05 { seek(.zero) }
        applyMute()
        pl.play()
        state.isPlaying = true
        startLink()
    }

    func pause() {
        guard let pl = player else { return }
        pl.pause()
        state.isPlaying = false
        stopLink()
        updatePlayheadFromPlayer()
    }

    func seek(_ t: CMTime) {
        let c = clamp(t)
        setPlayhead(c)
        if player == nil, !isClosed, state.project != nil { makePlayer() }
        player?.seek(to: c, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekFraction(_ f: Double) {
        guard let d = state.project?.duration else { return }
        seek(CMTimeMultiplyByFloat64(d, multiplier: max(0, min(1, f))))
    }

    /// Kare kare (⇧ ile bir saniye)
    func step(frames: Int, seconds: Bool) {
        guard let p = state.project else { return }
        if state.isPlaying { pause() }
        let fd = p.frameDuration.isValid && p.frameDuration > .zero ? p.frameDuration : CMTime(value: 1, timescale: 30)
        let delta = seconds ? CMTime(value: CMTimeValue(frames), timescale: 1) : CMTimeMultiply(fd, multiplier: Int32(frames))
        seek(playhead + delta)
    }

    func split() {
        guard let p = state.project else { return }
        let before = p.segments.count
        p.split(at: playhead)
        if p.segments.count == before { FilesMediaEditor.beep() }
    }

    /// Sil: aralık seçiliyse o kısım çıkar, değilse seçili parça silinir (son parça silinmez)
    func deleteSelection() {
        guard let p = state.project else { return }
        if let r = state.selection, state.hasSelection {
            if r.start <= .zero && r.end >= p.duration { FilesMediaEditor.beep(); return }
            p.removeRange(r)
            state.selection = nil
            seek(r.start)
            return
        }
        if let id = state.selectedID {
            guard p.segments.count > 1 else { FilesMediaEditor.beep(); return }
            let start = p.start(of: id)
            p.delete([id])
            state.selectedID = nil
            if let start { seek(start) }
            return
        }
        FilesMediaEditor.beep()
    }

    var canDelete: Bool {
        guard let p = state.project else { return false }
        if state.hasSelection { return true }
        return state.selectedID != nil && p.segments.count > 1
    }

    /// Kırp: yalnız seçili aralık kalır
    func keepSelection() {
        guard let p = state.project, let r = state.selection, state.hasSelection else { FilesMediaEditor.beep(); return }
        p.keepOnly(r)
        state.selection = nil
        seek(.zero)
    }

    func setIn() {
        guard let p = state.project else { return }
        let t = playhead
        if let s = state.selection, s.end > t { state.selection = CMTimeRange(start: t, end: s.end) }
        else { state.selection = CMTimeRange(start: t, end: p.duration) }
    }

    func setOut() {
        let t = playhead
        if let s = state.selection, s.start < t { state.selection = CMTimeRange(start: s.start, end: t) }
        else { state.selection = CMTimeRange(start: .zero, end: t) }
    }

    func undo() { state.project?.undo() }
    func redo() { state.project?.redo() }

    func trim(_ id: UUID, to range: CMTimeRange) { state.project?.trim(id, to: range) }
    func move(_ id: UUID, to index: Int) { state.project?.move(id, to: index) }

    /// "+" / Başa ekle / Sona ekle
    func addClip(atStart: Bool) {
        guard state.project != nil, state.overlay == nil else { return }
        FilesMediaEditor.chooseFiles(window) { [weak self] urls in
            guard let self, let p = self.state.project, !urls.isEmpty else { return }
            self.insert(urls, at: atStart ? 0 : p.segments.count)
        }
    }

    /// Dosyaları bu sınıra ekle (sırayla); ilk eklenen seçili olur
    func insert(_ urls: [URL], at index: Int) {
        guard let p = state.project else { return }
        let urls = urls.filter { FilesMediaEditor.canEdit($0) }
        guard !urls.isEmpty else { FilesMediaEditor.beep(); return }
        let prev = insertTask
        insertTask = Task { [weak self] in
            await prev?.value
            var at = min(max(0, index), p.segments.count)
            var first: UUID?
            for u in urls {
                do {
                    let id = try await p.insert(u, at: at)
                    if first == nil { first = id }
                    at += 1
                } catch {
                    guard let self, !self.isClosed else { return }
                    FilesMediaEditor.showError(error, self.window)
                    break
                }
            }
            guard let self, !self.isClosed, let first else { return }
            self.state.selectedID = first
            if let s = p.start(of: first) { self.seek(s) }
        }
    }

    func toggleMute() { state.muted.toggle() }

    func zoom(by d: Double) { state.zoom = max(0, min(1, state.zoom + d)) }

    // MARK: Kaydetme

    func showSave() {
        guard let p = state.project, state.overlay == nil else { return }
        if state.isPlaying { pause() }
        state.save.reset(for: p)
        state.overlay = .save
    }

    func cancelOverlay() {
        switch state.overlay {
        case .save: state.overlay = nil
        case .progress: cancelExport()
        case nil: break
        }
    }

    /// Kaydet penceresindeki seçimle
    func confirmSave() {
        let m = state.save
        guard state.overlay == .save, m.canConfirm else { return }
        switch m.choice {
        case .overwrite: save(.overwrite)
        case .newFile: save(.newFile)
        case .export: save(.export(m.exportURL, m.format))
        }
    }

    /// Kaydetme işini başlat (deneme düzeneği de doğrudan çağırır)
    func save(_ mode: MediaSaveMode) {
        guard let p = state.project, saveTask == nil else { return }
        if state.isPlaying { pause() }
        if case .export = mode { state.progressTitle = L("Dışa aktarılıyor…") } else { state.progressTitle = L("Kaydediliyor…") }
        state.progress = 0
        state.progressShown = false
        state.overlay = .progress
        job = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isSaving, self.state.overlay == .progress else { return }
                self.state.progressShown = true
            }
        }
        saveTask = Task { [weak self] in
            do {
                let written = try await p.save(mode, job: { j in
                    if Thread.isMainThread { MainActor.assumeIsolated { self?.job = j } }
                    else { DispatchQueue.main.async { MainActor.assumeIsolated { self?.job = j } } }
                }, progress: { v in
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self?.state.overlay == .progress { self?.state.progress = v } } }
                })
                guard let self else { return }
                self.saveTask = nil
                self.job = nil
                self.saved(written)
            } catch {
                guard let self else { return }
                self.saveTask = nil
                self.job = nil
                self.state.overlay = nil
                if Self.isCancel(error) { return }
                FilesMediaEditor.showError(error, self.window)
            }
        }
    }

    var isSaving: Bool { saveTask != nil }

    static func isCancel(_ e: Error) -> Bool {
        if e is CancellationError { return true }
        if let m = e as? MediaEditError, case .cancelled = m { return true }
        let n = e as NSError
        return (n.domain == AVFoundationErrorDomain && n.code == AVError.operationCancelled.rawValue)
            || (n.domain == NSCocoaErrorDomain && n.code == NSUserCancelledError)
    }

    func cancelExport() {
        job?.cancel()
        saveTask?.cancel()
    }

    /// Yazıldı: düzenleyici kapanır, dosya geldiği Dosyalar penceresinde seçili gelir
    private func saved(_ written: URL) {
        state.overlay = nil
        closeConfirmed = true
        window.close()
        let dir = written.deletingLastPathComponent()
        if let c = filesController, c.window?.isVisible == true {
            let tab = c.tab
            if tab.url.fileKey == dir.fileKey {
                FileIcons.shared.forget(written)
                tab.pendingSelect = [written]
                tab.reload()
                return
            }
        }
        if FilesManager.shared.hasWindows { FilesManager.shared.reveal(written) }
    }

    // MARK: Kapatma

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        if isSaving { return false }
        guard let p = state.project, p.isModified else { return true }
        if state.overlay == .save { state.overlay = nil }
        if state.isPlaying { pause() }
        let name = FileManager.default.displayName(atPath: url.path)
        FilesMediaEditor.ask(window, L("“%@” dosyasındaki değişiklikler kaydedilsin mi?", name),
                             L("Kaydetmezseniz yaptığınız düzenlemeler kaybolur."),
                             [FilesDialog.Action(L("Kaydetme"), .destructive),
                              FilesDialog.Action(L("Vazgeç"), .cancel),
                              FilesDialog.Action(L("Kaydet…"), .primary)]) { [weak self] i in
            guard let self else { return }
            switch i {
            case 0:
                self.closeConfirmed = true
                self.window.close()
            case 2:
                self.showSave()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }

    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        loadTask?.cancel()
        insertTask?.cancel()
        stageWaveTask?.cancel()
        job?.cancel()
        saveTask?.cancel()
        releaseWork?.cancel()
        releaseWork = nil
        releasePlayer()
        state.project?.close()
        timeline.teardown()
        stage.teardown()
        bag.removeAll()
        projectBag.removeAll()
        tick.target = nil
        window.keyHandler = nil
        window.delegate = nil
        FilesMediaEditor.closed(self)
        // Kök görünüm denetleyiciyi tutuyor (pencere → görünüm → denetleyici → pencere): kapanınca bırak
        DispatchQueue.main.async { [window] in window.contentView = nil }
    }

    // MARK: Klavye

    /// Kısayollar. true: olay kullanıldı
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        // Yazım (IME) sürerken tuşlar ona ait
        if let tv = window.firstResponder as? NSTextView, tv.hasMarkedText() { return false }

        if mods == .command && chars == "w" { window.performClose(nil); return true }

        if let o = state.overlay {
            // Kaydet penceresi açıkken yalnız Return / Esc; metin alanı geri kalanını alır
            if code == 53 && mods.isEmpty { cancelOverlay(); return true }
            if (code == 36 || code == 76) && mods.isEmpty && o == .save { confirmSave(); return true }
            return o == .progress
        }
        guard state.project != nil else {
            if code == 53 && mods.isEmpty { window.performClose(nil); return true }
            return false
        }
        // Metin alanı odaktaysa (ör. yakınlaştırma kaydırıcısı değil, gerçek bir alan) yazıya dokunma
        if window.firstResponder is NSText { return false }

        switch (mods, code, chars) {
        case ([], 49, _): togglePlay(); return true                          // Space
        case ([], 123, _), ([.shift], 123, _):                               // ←
            step(frames: -1, seconds: mods.contains(.shift)); return true
        case ([], 124, _), ([.shift], 124, _):                               // →
            step(frames: 1, seconds: mods.contains(.shift)); return true
        case ([], _, "i"): setIn(); return true
        case ([], _, "o"): setOut(); return true
        case ([], _, "s"), ([.command], _, "b"): split(); return true
        case ([], 51, _), ([], 117, _): deleteSelection(); return true       // ⌫, ⌦
        case ([.command], _, "z"): undo(); return true
        case ([.command, .shift], _, "z"): redo(); return true
        case ([.command], _, "s"): showSave(); return true
        case ([], 53, _):                                                    // Esc
            if state.selection != nil { state.selection = nil }
            else if state.selectedID != nil { state.selectedID = nil }
            else { window.performClose(nil) }
            return true
        case ([.command], _, "="), ([.command], _, "+"): zoom(by: 0.15); return true
        case ([.command], _, "-"): zoom(by: -0.15); return true
        default: return false
        }
    }
}

// MARK: - Ölçüler

enum FilesMediaEditorLayout {
    static let defaultSize = NSSize(width: 980, height: 660)
    static let minSize = NSSize(width: 720, height: 480)
    static let timelineHeight: CGFloat = 156

    /// Başlık şeridi (finder'da sistem başlık çubuğu var, şerit yok)
    static func headerHeight(_ t: FilesTheme) -> CGFloat {
        switch t {
        case .missing, .glass: return 40
        case .windows: return 32
        case .finder: return 0
        }
    }
}

// MARK: - Sahne (AppKit)

/// Üstteki sahne: video → görüntü (AVPlayerLayer, sistem denetimleri yok), ses → simge, ad ve büyük dalga biçimi
@MainActor final class FilesMediaStageView: NSView {
    var kind: MediaKind = .video { didSet { needsDisplay = true; needsLayout = true } }
    var renderSize: CGSize = .zero { didSet { needsLayout = true } }
    var palette = FilesPalette(theme: .missing, dark: true) { didSet { needsDisplay = true } }
    var title = ""
    var icon: NSImage?
    /// Ses: dalga biçimi (0…1) ve oynatma başının oranı
    var waveform: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 {
        didSet {
            guard kind == .audio, progress != oldValue else { return }
            needsDisplay = true
        }
    }
    /// Ekran dışı görüntü için (oynatıcı katmanı ekran dışında çizilmez): yerine konan kare
    var still: CGImage? { didSet { needsDisplay = true } }
    var onSeek: (Double) -> Void = { _ in }
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Videonun sahnedeki yeri (oranı korunmuş)
    var videoRect: NSRect {
        let b = bounds.insetBy(dx: 12, dy: 12)
        guard renderSize.width > 0, renderSize.height > 0, b.width > 0, b.height > 0 else { return b }
        let s = min(b.width / renderSize.width, b.height / renderSize.height)
        let w = (renderSize.width * s).rounded(), h = (renderSize.height * s).rounded()
        return NSRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = kind == .video ? videoRect : .zero
        playerLayer.isHidden = kind != .video
        CATransaction.commit()
    }

    func teardown() {
        playerLayer.player = nil
        waveform = []
        still = nil
    }

    /// Ses sahnesindeki dalga biçimi alanı
    var waveRect: NSRect {
        let b = bounds
        let top = b.minY + min(150, b.height * 0.42)
        return NSRect(x: b.minX + 32, y: top, width: max(0, b.width - 64), height: max(0, b.maxY - top - 28))
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        if kind == .video {
            if let still {
                NSGraphicsContext.current?.cgContext.saveGState()
                let r = videoRect
                // Çevrilmiş görünüm: resmi düz çiz
                let img = NSImage(cgImage: still, size: r.size)
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
            return
        }
        // Ses: simge + ad, altında dalga biçimi
        let b = bounds
        let iconSize: CGFloat = min(72, max(36, b.height * 0.18))
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: p.nsFG.withAlphaComponent(0.9)]
        let tSize = (title as NSString).size(withAttributes: titleAttr)
        let blockH = iconSize + 8 + tSize.height
        let wave = waveRect
        let top = max(b.minY + 12, (wave.minY - blockH) / 2)
        if let icon {
            icon.draw(in: NSRect(x: b.midX - iconSize / 2, y: top, width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let tw = min(tSize.width, b.width - 40)
        (title as NSString).draw(with: NSRect(x: b.midX - tw / 2, y: top + iconSize + 8, width: tw, height: tSize.height),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttr)
        guard wave.width > 10, wave.height > 10 else { return }
        let mid = wave.midY
        let n = waveform.count
        let bar: CGFloat = 3, gap: CGFloat = 2
        let count = Int(wave.width / (bar + gap))
        let played = wave.minX + wave.width * CGFloat(progress)
        let base = p.nsFG.withAlphaComponent(p.dark ? 0.30 : 0.25)
        let lit = p.nsAccent
        for i in 0..<max(0, count) {
            let x = wave.minX + CGFloat(i) * (bar + gap)
            var v: CGFloat = 0.04
            if n > 0 {
                let a = i * n / max(count, 1), z = max(a + 1, (i + 1) * n / max(count, 1))
                var m: Float = 0
                for k in a..<min(z, n) { m = max(m, waveform[k]) }
                v = max(0.03, CGFloat(m))
            }
            let h = max(2, v * wave.height)
            (x < played ? lit : base).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: mid - h / 2, width: bar, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        // Oynatma başı
        p.nsFG.withAlphaComponent(0.85).setFill()
        NSRect(x: played - 0.75, y: wave.minY - 6, width: 1.5, height: wave.height + 12).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard kind == .audio else { return }
        seek(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard kind == .audio else { return }
        seek(event)
    }

    private func seek(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let w = waveRect
        guard w.width > 0 else { return }
        onSeek(Double((p.x - w.minX) / w.width))
    }
}

/// Sahneyi SwiftUI içine koyar; temanın paletini iletir
struct FilesMediaStageRepresentable: NSViewRepresentable {
    let view: FilesMediaStageView
    func makeNSView(context: Context) -> FilesMediaStageView { view }
    func updateNSView(_ v: FilesMediaStageView, context: Context) {
        let p = context.environment.filesPalette
        if v.palette.theme != p.theme || v.palette.dark != p.dark { v.palette = p }
    }
}

struct FilesMediaTimelineRepresentable: NSViewRepresentable {
    let view: FilesMediaTimelineContainer
    func makeNSView(context: Context) -> FilesMediaTimelineContainer { view }
    func updateNSView(_ v: FilesMediaTimelineContainer, context: Context) {
        let p = context.environment.filesPalette
        if v.document.palette.theme != p.theme || v.document.palette.dark != p.dark { v.document.palette = p }
    }
}

// MARK: - Görünüm (SwiftUI)

struct FilesMediaEditorView: View {
    @ObservedObject var state: FilesMediaEditorState
    let editor: FilesMediaEditorController
    @Environment(\.filesPalette) private var p

    var body: some View {
        VStack(spacing: 0) {
            header
            stageArea
            Rectangle().fill(p.divider).frame(height: 1)
            Group {
                if let project = state.project {
                    FilesMediaToolbar(state: state, project: project, editor: editor)
                } else {
                    FilesMediaToolbarPlaceholder()
                }
            }
            .frame(height: FilesMediaToolbar.height(p.theme))
            Rectangle().fill(p.divider).frame(height: 1)
            FilesMediaTimelineRepresentable(view: editor.timeline)
                .frame(height: FilesMediaEditorLayout.timelineHeight)
                .background(timelineBackground)
        }
        .foregroundStyle(p.fg)
        .background(windowBackground)
        .overlay { overlay }
    }

    // MARK: Zeminler

    @ViewBuilder private var windowBackground: some View {
        switch p.theme {
        case .missing, .glass: Color.clear.modifier(FilesDialogSurface(shaped: false))
        case .windows: p.winBand
        case .finder: Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder private var stageBackground: some View {
        switch p.theme {
        case .missing: Color.black.opacity(0.30)
        case .glass: p.dark ? Color.black.opacity(0.16) : Color.white.opacity(0.22)
        case .windows: p.dark ? Color(white: 0.08) : Color(white: 0.93)
        case .finder: p.dark ? Color.black.opacity(0.55) : Color(white: 0.88)
        }
    }

    @ViewBuilder private var timelineBackground: some View {
        switch p.theme {
        case .missing: Color.black.opacity(0.18)
        case .glass: p.dark ? Color.black.opacity(0.08) : Color.white.opacity(0.25)
        case .windows: p.winSurface
        case .finder: Color(nsColor: .controlBackgroundColor)
        }
    }

    // MARK: Başlık şeridi

    @ViewBuilder private var header: some View {
        switch p.theme {
        case .finder:
            EmptyView()
        case .windows:
            HStack(spacing: 0) {
                Image(nsImage: FileIcons.shared.icon(editor.url)).resizable().interpolation(.high)
                    .frame(width: 16, height: 16).padding(.leading, 12).padding(.trailing, 10)
                titleText(size: 12, weight: .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { editor.window.miniaturize(nil) } label: { Image(systemName: "minus") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p, caption: true))
                    .help(L("Simge durumuna küçült"))
                Button { editor.window.zoom(nil) } label: { Image(systemName: "square") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p, caption: true))
                    .help(L("Büyüt"))
                Button { editor.window.performClose(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(FilesPreviewIconButtonStyle(p: p, caption: true, danger: true))
                    .help(L("Kapat"))
            }
            .frame(height: FilesMediaEditorLayout.headerHeight(.windows))
            .background(FilesWindowDragArea())
            .background(p.winBand)
        case .missing, .glass:
            HStack(spacing: 8) {
                Image(nsImage: FileIcons.shared.icon(editor.url)).resizable().interpolation(.high)
                    .frame(width: 18, height: 18)
                titleText(size: 13, weight: .semibold)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            .padding(.leading, 80)       // trafik ışıkları
            .padding(.trailing, 14)
            .frame(height: FilesMediaEditorLayout.headerHeight(p.theme))
            .background(FilesWindowDragArea())
            .overlay(alignment: .bottom) { Rectangle().fill(p.divider).frame(height: 1) }
        }
    }

    private func titleText(size: CGFloat, weight: Font.Weight) -> some View {
        FilesMediaTitle(state: state, name: editor.window.title, size: size, weight: weight)
    }

    // MARK: Sahne

    private var stageArea: some View {
        ZStack {
            stageBackground
            FilesMediaStageRepresentable(view: editor.stage)
            if state.project == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("Yükleniyor…")).font(.system(size: 12)).foregroundStyle(p.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: Üst katman

    @ViewBuilder private var overlay: some View {
        if let o = state.overlay {
            let hidden = o == .progress && !state.progressShown
            ZStack {
                Color.black.opacity(hidden ? 0.001 : (p.theme == .windows ? (p.dark ? 0.45 : 0.30) : 0.38))
                    .contentShape(Rectangle())
                    .onTapGesture {}
                switch o {
                case .save:
                    FilesMediaSaveCard(model: state.save, editor: editor)
                case .progress:
                    if !hidden { FilesMediaProgressCard(state: state, editor: editor) }
                }
            }
            .transition(.opacity)
        }
    }
}

/// Başlıktaki ad; değişiklik varsa yanında küçük nokta
private struct FilesMediaTitle: View {
    @ObservedObject var state: FilesMediaEditorState
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: size, weight: weight)).lineLimit(1).truncationMode(.middle)
            Text(L("Düzenleniyor")).font(.system(size: size - 1.5)).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
            if let project = state.project { FilesMediaModifiedDot(project: project) }
        }
    }
}

private struct FilesMediaModifiedDot: View {
    @ObservedObject var project: MediaEditProject
    @Environment(\.filesPalette) private var p
    var body: some View {
        if project.isModified {
            Circle().fill(p.accent).frame(width: 6, height: 6).help(L("Kaydedilmemiş değişiklikler var"))
        }
    }
}

// MARK: - Araç şeridi

private struct FilesMediaToolbarPlaceholder: View {
    var body: some View { Color.clear }
}

struct FilesMediaToolbar: View {
    @ObservedObject var state: FilesMediaEditorState
    @ObservedObject var project: MediaEditProject
    let editor: FilesMediaEditorController
    @Environment(\.filesPalette) private var p

    static func height(_ t: FilesTheme) -> CGFloat { t == .windows ? 48 : 46 }

    /// Sıkışma kademesi: full → bütün düğmeler yazılı; medium → ekle düğmeleri yalnız simge; compact → hepsi simge
    enum Level: Int, CaseIterable { case full, medium, compact }

    /// Düğme yazıları (sırayla: Böl, Sil, Kırp, Başa ekle, Sona ekle)
    static var labels: [String] { [L("Böl"), L("Sil"), L("Kırp"), L("Başa ekle"), L("Sona ekle")] }

    static func textWidth(_ s: String, _ size: CGFloat = 12, _ w: NSFont.Weight = .regular) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w)]).width.rounded(.up)
    }

    /// Simgeli düğmenin genişliği (yazısız: kare)
    static func buttonWidth(_ label: String?, _ t: FilesTheme) -> CGFloat {
        guard let label else { return t == .windows ? 34 : 30 }
        return 10 + 15 + 5 + textWidth(label) + 10
    }

    /// compact: yalnız şimdiki zaman (toplam ipucunda)
    static func timeWidth(total: Double, compact: Bool = false) -> CGFloat {
        let s = FilesMediaEditor.clock(total) + (compact ? "" : " / " + FilesMediaEditor.clock(total))
        return (s as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]).width.rounded(.up) + 6
    }

    static func saveWidth(_ t: FilesTheme) -> CGFloat {
        max(t == .windows ? 96 : 76, textWidth(L("Kaydet"), 13, .semibold) + 32)
    }

    static func zoomWidth(_ level: Level) -> CGFloat { level == .compact ? 64 : 120 }
    static func separatorPad(_ level: Level) -> CGFloat { level == .compact ? 1 : 4 }

    /// Kademe için gereken genişlik (araç şeridi bu hesapla seçilir; hiçbir yazı kesilmez)
    static func required(_ level: Level, theme t: FilesTheme, total: Double) -> CGFloat {
        let labels = Self.labels
        let compact = level == .compact
        let edit = (0..<3).reduce(CGFloat(0)) { $0 + buttonWidth(compact ? nil : labels[$1], t) }
        let add = (3..<5).reduce(CGFloat(0)) { $0 + buttonWidth(level == .full ? labels[$1] : nil, t) }
        let icon = buttonWidth(nil, t)
        let fixed = icon /* oynat */ + timeWidth(total: total, compact: compact) + 2 * icon /* geri al / yinele */ + icon /* ses */
            + zoomWidth(level) + saveWidth(t)
        // 16 öğe arası 4, 4 ayraç (1 + iki yanda pay), Spacer en az 4, kenar payı 2 × 16
        let gaps: CGFloat = 4 * 16 + 4 * (1 + 2 * separatorPad(level)) + 4 + 32
        return edit + add + fixed + gaps
    }

    static func level(for width: CGFloat, theme: FilesTheme, total: Double) -> Level {
        Level.allCases.first { required($0, theme: theme, total: total) <= width } ?? .compact
    }

    var body: some View {
        GeometryReader { g in
            row(Self.level(for: g.size.width, theme: p.theme, total: project.duration.seconds))
                .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func row(_ level: Level) -> some View {
        let labels = Self.labels
        let compact = level == .compact
        let separator = self.separator(level)
        return HStack(spacing: 4) {
            tool(state.isPlaying ? "pause.fill" : "play.fill", nil, L("Oynat / Duraklat") + "  Space", enabled: true) { editor.togglePlay() }
            FilesMediaTimeLabel(clock: state.clock, total: project.duration.seconds, showTotal: !compact)
                .frame(width: Self.timeWidth(total: project.duration.seconds, compact: compact), alignment: .leading)
                .help(FilesMediaEditor.clock(project.duration.seconds))
            separator
            tool("scissors", level == .compact ? nil : labels[0], L("Oynatma başından böl") + "  S", enabled: true) { editor.split() }
            tool("trash", level == .compact ? nil : labels[1],
                 state.hasSelection ? L("Seçili aralığı çıkar") + "  ⌫" : L("Seçili parçayı sil") + "  ⌫",
                 enabled: editor.canDelete) { editor.deleteSelection() }
            tool("crop", level == .compact ? nil : labels[2], L("Yalnız seçili aralık kalsın"), enabled: state.hasSelection) { editor.keepSelection() }
            separator
            tool("text.insert", level == .full ? labels[3] : nil, L("Başa ses ya da video ekle"), enabled: true) { editor.addClip(atStart: true) }
            tool("text.append", level == .full ? labels[4] : nil, L("Sona ses ya da video ekle"), enabled: true) { editor.addClip(atStart: false) }
            separator
            tool("arrow.uturn.backward", nil, L("Geri al") + "  ⌘Z", enabled: project.canUndo) { editor.undo() }
            tool("arrow.uturn.forward", nil, L("Yinele") + "  ⇧⌘Z", enabled: project.canRedo) { editor.redo() }
            Spacer(minLength: 4)
            tool(state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", nil, state.muted ? L("Sessizden çıkar") : L("Sessize al"), enabled: true) { editor.toggleMute() }
            zoomControl(level)
            separator
            saveButton
                .fixedSize()
                .help(L("Kaydet") + "  ⌘S")
        }
        .padding(.horizontal, 16)
    }

    /// finder: sistemin vurgulu düğmesi; diğerleri temanın birincil düğmesi
    @ViewBuilder private var saveButton: some View {
        if p.theme == .finder {
            Button { editor.showSave() } label: { Text(L("Kaydet")).padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        } else {
            Button { editor.showSave() } label: { Text(L("Kaydet")) }
                .filesButton(.primary, p)
        }
    }

    private func separator(_ level: Level) -> some View {
        Rectangle().fill(p.fg.opacity(p.dark ? 0.14 : 0.12)).frame(width: 1, height: 20)
            .padding(.horizontal, Self.separatorPad(level))
    }

    private func zoomControl(_ level: Level) -> some View {
        HStack(spacing: 4) {
            if level != .compact {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(p.secondary)
            }
            Slider(value: $state.zoom, in: 0...1)
                .controlSize(.small)
                .frame(width: level == .compact ? 64 : 84)
                .help(L("Yakınlaştır"))
            if level != .compact {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(p.secondary)
            }
        }
        .frame(width: Self.zoomWidth(level))
    }

    private func tool(_ symbol: String, _ label: String?, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).frame(width: 15)
                if let label { Text(label).font(.system(size: 12)).lineLimit(1).fixedSize() }
            }
        }
        .buttonStyle(FilesMediaToolButtonStyle(p: p, iconOnly: label == nil))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// Oynarken yalnız bu yazı yeniden çizilir
private struct FilesMediaTimeLabel: View {
    @ObservedObject var clock: FilesMediaEditorClock
    let total: Double
    var showTotal = true
    @Environment(\.filesPalette) private var p

    var body: some View {
        HStack(spacing: 0) {
            Text(FilesMediaEditor.clock(clock.time)).foregroundStyle(p.fg)
            if showTotal { Text(" / " + FilesMediaEditor.clock(total)).foregroundStyle(p.secondary) }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// Araç şeridi düğmesi: missing koyu cam kutu, glass hap, windows komut çubuğu (köşe 4, üstüne gelince dolgu),
/// finder sistemin araç çubuğu düğmesi gibi
struct FilesMediaToolButtonStyle: ButtonStyle {
    let p: FilesPalette
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        ToolBody(configuration: configuration, p: p, iconOnly: iconOnly)
    }

    private struct ToolBody: View {
        let configuration: Configuration
        let p: FilesPalette
        let iconOnly: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            let h: CGFloat = p.theme == .windows ? 32 : (p.theme == .finder ? 26 : 28)
            configuration.label
                .foregroundStyle(p.fg.opacity(p.theme == .finder ? 0.8 : 0.9))
                .padding(.horizontal, iconOnly ? 0 : 10)
                .frame(minWidth: iconOnly ? (p.theme == .windows ? 34 : 30) : nil)
                .frame(height: h)
                .background(shape.fill(fill(pressed)))
                .overlay(shape.stroke(stroke, lineWidth: 1))
                .contentShape(shape)
                .onHover { hover = $0 }
                .opacity(enabled ? 1 : 0.38)
        }

        private var shape: AnyShape {
            switch p.theme {
            case .glass: return AnyShape(Capsule(style: .continuous))
            case .windows: return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            case .finder: return AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .missing: return AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }

        private func fill(_ pressed: Bool) -> Color {
            if pressed { return p.pressFill }
            switch p.theme {
            case .missing: return .white.opacity(hover && enabled ? 0.12 : 0.06)
            case .glass: return p.glassFill(hover && enabled ? 0.18 : 0.09)
            case .windows: return hover && enabled ? p.fg.opacity(p.dark ? 0.08 : 0.05) : .clear
            case .finder: return hover && enabled ? p.fg.opacity(p.dark ? 0.12 : 0.08) : p.fg.opacity(p.dark ? 0.06 : 0.04)
            }
        }

        private var stroke: Color {
            switch p.theme {
            case .missing: return .white.opacity(0.08)
            case .glass: return p.glassStroke(0.22)
            case .windows: return .clear
            case .finder: return p.fg.opacity(p.dark ? 0.10 : 0.08)
            }
        }
    }
}

// MARK: - Kaydet penceresi (temalı, NSSavePanel değil)

struct FilesMediaSaveCard: View {
    @ObservedObject var model: FilesMediaSaveModel
    let editor: FilesMediaEditorController
    @Environment(\.filesPalette) private var p

    var body: some View {
        Group {
            if p.theme == .windows { windowsLayout } else { standardLayout }
        }
        .frame(width: 470)
        .foregroundStyle(p.fg)
        .modifier(FilesCardSurface())
    }

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Düzenlenen dosyayı kaydet")).font(.system(size: 14, weight: .bold))
            options
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Vazgeç")) { editor.cancelOverlay() }.filesButton(.cancel, p)
                // finder: sistemin varsayılan (mavi) düğmesi; Return yine pencerenin kısayolundan gelir
                Button(L("Kaydet")) { editor.confirmSave() }.filesButton(.primary, p).disabled(!model.canConfirm)
                    .modifier(FilesMediaDefaultButton(on: p.theme == .finder))
            }
        }
        .padding(20)
    }

    private var windowsLayout: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Düzenlenen dosyayı kaydet")).font(.system(size: 17, weight: .semibold))
                options
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.winSurface)
            Rectangle().fill(p.dialogBorder).frame(height: 1)
            HStack(spacing: 8) {
                Button(L("Kaydet")) { editor.confirmSave() }.filesButton(.primary, p, stretch: true).disabled(!model.canConfirm)
                Button(L("Vazgeç")) { editor.cancelOverlay() }.filesButton(.cancel, p, stretch: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(p.winBand)
        }
    }

    private var options: some View {
        VStack(spacing: 8) {
            option(.overwrite, "arrow.triangle.2.circlepath", L("Üstüne yaz"),
                   model.canOverwrite ? L("“%@” yeni hâliyle değişir; asıl dosya Çöp Sepeti'ne taşınır.", model.originalName)
                                      : L("Bu biçime ya da bu klasöre geri yazılamıyor."),
                   enabled: model.canOverwrite)
            option(.newFile, "doc.badge.plus", L("Yeni dosya olarak kaydet"), model.newFileName, enabled: true)
            option(.export, "square.and.arrow.up.on.square", L("Farklı biçimde dışa aktar"),
                   L("Başka bir uzantıyla, istediğiniz klasöre."), enabled: true)
            if model.choice == .export { exportFields }
        }
    }

    private func option(_ c: FilesMediaSaveModel.Choice, _ symbol: String, _ title: String, _ detail: String, enabled: Bool) -> some View {
        let on = model.choice == c
        let shape = RoundedRectangle(cornerRadius: p.theme == .windows ? 4 : (p.theme == .glass ? 12 : 8), style: .continuous)
        return Button { if enabled { model.choice = c } } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? p.accent : p.fg.opacity(0.35), lineWidth: on ? 5 : 1.2)
                        .frame(width: 16, height: 16)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(on ? p.accent : p.secondary)
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(p.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(on ? p.accent.opacity(p.dark ? 0.16 : 0.10) : p.fg.opacity(p.dark ? 0.05 : 0.035)))
            .overlay(shape.strokeBorder(on ? p.accent.opacity(0.8) : p.fg.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var exportFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Ad")).font(.system(size: 12)).foregroundStyle(p.secondary).frame(width: 54, alignment: .leading)
                FilesThemedField(text: $model.name, placeholder: L("Dosya adı"), autofocus: false) { editor.confirmSave() }
                Text("." + model.format.fileExtension).font(.system(size: 12).monospaced()).foregroundStyle(p.secondary).fixedSize()
            }
            HStack(alignment: .top, spacing: 8) {
                Text(L("Biçim")).font(.system(size: 12)).foregroundStyle(p.secondary).frame(width: 54, alignment: .leading)
                    .padding(.top, 5)
                FilesMediaFormatChips(model: model)
            }
            HStack(spacing: 8) {
                Text(L("Konum")).font(.system(size: 12)).foregroundStyle(p.secondary).frame(width: 54, alignment: .leading)
                Image(nsImage: FileIcons.shared.icon(model.folder)).resizable().frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: model.folder.path)).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.folder.path)
                Spacer(minLength: 4)
                Button(L("Konum…")) {
                    FilesMediaEditor.chooseFolder(editor.window, model.folder) { u in if let u { model.folder = u } }
                }
                .filesButton(.normal, p, small: true)
                .fixedSize()
            }
        }
        .padding(.leading, 8)
        .padding(.top, 2)
    }
}

/// finder temasında düğmeyi sistemin varsayılan düğmesi gibi çizer
private struct FilesMediaDefaultButton: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(.defaultAction) } else { content }
    }
}

/// Biçim seçimi: küçük haplar (sığmayan alt satıra geçer)
private struct FilesMediaFormatChips: View {
    @ObservedObject var model: FilesMediaSaveModel
    @Environment(\.filesPalette) private var p

    /// Hapların sığacağı genişlik (kart 470 − kenar payları − etiket sütunu)
    static let width: CGFloat = 470 - 40 - 8 - 54 - 8

    var body: some View {
        let rows = wrap(model.formats)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r]) { f in chip(f) }
                }
            }
        }
    }

    /// Sığmayan hap alt satıra geçer (yazı kalın hâliyle ölçülür)
    private func wrap(_ a: [MediaExportFormat]) -> [[MediaExportFormat]] {
        var rows: [[MediaExportFormat]] = [[]]
        var x: CGFloat = 0
        for f in a {
            let w = FilesMediaToolbar.textWidth(f.title, 11.5, .semibold) + 18
            if x > 0, x + w > Self.width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(f)
            x += w + 6
        }
        return rows
    }

    private func chip(_ f: MediaExportFormat) -> some View {
        let on = model.format == f
        let shape = RoundedRectangle(cornerRadius: p.theme == .windows ? 4 : (p.theme == .glass ? 10 : 6), style: .continuous)
        return Button { model.format = f } label: {
            Text(f.title)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
                .foregroundStyle(on ? p.onAccent : p.fg.opacity(0.85))
                .background(shape.fill(on ? p.accent : p.fg.opacity(p.dark ? 0.07 : 0.05)))
                .overlay(shape.strokeBorder(on ? Color.clear : p.fg.opacity(0.10), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - İlerleme

struct FilesMediaProgressCard: View {
    @ObservedObject var state: FilesMediaEditorState
    let editor: FilesMediaEditorController
    @Environment(\.filesPalette) private var p

    var body: some View {
        let pct = Int((max(0, min(1, state.progress)) * 100).rounded())
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.shared.icon(editor.url)).resizable().interpolation(.high).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.progressTitle).font(.system(size: 13.5, weight: .semibold))
                    Text(editor.window.title).font(.system(size: 11.5)).foregroundStyle(p.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("%\(pct)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p.theme == .missing ? Brand.red : p.accent)
            }
            bar
            HStack {
                Spacer(minLength: 0)
                Button(L("Vazgeç")) { editor.cancelExport() }.filesButton(.cancel, p)
            }
        }
        .padding(20)
        .frame(width: 380)
        .foregroundStyle(p.fg)
        .modifier(FilesCardSurface())
    }

    @ViewBuilder private var bar: some View {
        if p.theme == .finder {
            ProgressView(value: max(0, min(1, state.progress))).progressViewStyle(.linear)
        } else {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.fg.opacity(p.dark ? 0.12 : 0.10))
                    Capsule().fill(p.theme == .missing ? Brand.red : p.accent)
                        .frame(width: max(6, g.size.width * CGFloat(max(0, min(1, state.progress)))))
                }
            }
            .frame(height: p.theme == .windows ? 4 : 6)
        }
    }
}
