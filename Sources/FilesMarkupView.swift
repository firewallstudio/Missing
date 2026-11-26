import AppKit
import Combine
import SwiftUI

// MARK: - Önizlemede fotoğraf işaretleme: tuval, temalı araç çubuğu ve önizleme penceresiyle bağlantı
//
// İşaretle düğmesi önizlemeyi yerinde işaretleme kipine alır: fotoğraf yerinde ve aynı boyda kalır, üstüne saydam bir
// tuval (FilesMarkupCanvas) biner; başlığın yerini (windows'ta komut satırının yerini) araç çubuğu alır.
// Önizleme paneli normalde hiç anahtar olmaz; işaretlerken anahtar olur ki yazı, ⌘Z, Sil, Esc ve Return çalışsın.
// Ok tuşları ve boşluk işaretlerken başka dosyaya geçirmez. Kip bitince Dosyalar penceresi yeniden anahtar olur.

// MARK: Oturum

@MainActor final class FilesMarkupSession: ObservableObject {
    let url: URL
    /// Dik (EXIF yönü uygulanmış) piksel boyu
    let pixelSize: CGSize
    let doc = FilesMarkupDocument()

    @Published var tool: FilesMarkupTool = .pen {
        didSet { if tool != oldValue { toolChanged() } }
    }
    @Published private(set) var color = 0
    @Published private(set) var step = 1
    @Published private(set) var selection: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var editingText = false
    @Published var saving = false
    /// Vazgeç / kaydet sorusu açık
    var asking = false

    weak var canvas: FilesMarkupCanvas?
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Araç çubuğundan sonra odak tuvale dönsün (panel anahtar, tuval ilk yanıtlayıcı)
    var refocus: () -> Void = {}
    /// Araç çubuğundaki düğmenin (pencere içi, üstten) çerçevesi → menünün ekrandaki sol üst köşesi
    var menuPoint: (NSRect) -> NSPoint? = { _ in nil }
    private var menuActions: [FilesMarkupMenuAction] = []

    init(url: URL, pixelSize: CGSize) {
        self.url = url
        self.pixelSize = pixelSize
        doc.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.docChanged() }
        }
    }

    private func docChanged() {
        canUndo = doc.canUndo
        canRedo = doc.canRedo
        if let s = selection, doc.item(s) == nil { selection = nil }
        canvas?.needsDisplay = true
    }

    private func toolChanged() {
        canvas?.commitText()
        if tool != .select { selection = nil }
        canvas?.toolChanged()
    }

    func select(_ id: UUID?) {
        selection = id
        if let it = doc.item(id) {
            color = it.color
            step = it.step
        }
        canvas?.needsDisplay = true
    }

    func setColor(_ i: Int) {
        color = i
        if canvas?.isEditingText == true {
            canvas?.restyleText()
        } else if let id = selection {
            doc.update(id) { $0.color = i }
        }
        refocus()
    }

    func setStep(_ s: Int) {
        step = s
        if canvas?.isEditingText == true {
            canvas?.restyleText(stepChanged: true)
        } else if let id = selection, let canvas {
            let k = canvas.pxPerPoint
            doc.update(id) { $0.step = s; $0.width = FilesMarkupWidth.points(s, for: $0.kind) * k }
        }
        refocus()
    }

    func setTool(_ t: FilesMarkupTool) {
        tool = t
        refocus()
    }

    func deleteSelection() {
        guard let id = selection else { return }
        doc.remove(id)
        selection = nil
    }

    func undo() {
        canvas?.commitText()
        doc.undo()
        refocus()
    }

    func redo() {
        canvas?.commitText()
        doc.redo()
        refocus()
    }

    // MARK: Dar araç çubuğunun menüleri (Dosyalar'ın temalı menüsü)

    enum MenuKind { case tool, color, width }

    func menu(_ kind: MenuKind) -> NSMenu {
        menuActions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ image: NSImage?, on: Bool, _ run: @escaping () -> Void) {
            let a = FilesMarkupMenuAction(run)
            menuActions.append(a)
            let item = NSMenuItem(title: title, action: #selector(FilesMarkupMenuAction.fire(_:)), keyEquivalent: "")
            item.target = a
            item.image = image
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        switch kind {
        case .tool:
            for t in FilesMarkupTool.allCases {
                let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
                img?.isTemplate = true
                add(t.title, img, on: tool == t) { [weak self] in self?.setTool(t) }
            }
        case .color:
            for (i, c) in FilesMarkupColor.palette.enumerated() {
                add(L(c.name), Self.swatchImage(c.ns), on: color == i) { [weak self] in self?.setColor(i) }
            }
        case .width:
            for i in 0..<3 {
                add(L(FilesMarkupWidth.titles[i]), Self.widthImage(i), on: step == i) { [weak self] in self?.setStep(i) }
            }
        }
        return menu
    }

    func showMenu(_ kind: MenuKind, from frame: NSRect) {
        guard let pt = menuPoint(frame) else { return }
        FilesContextMenu.shared.show(menu(kind), at: pt)
    }

    static func swatchImage(_ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0.5, alpha: 0.6).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.25, dy: 1.25))
            ring.lineWidth = 0.5
            ring.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }

    static func widthImage(_ i: Int) -> NSImage {
        let h: CGFloat = [1.5, 3, 5][min(max(i, 0), 2)]
        let img = NSImage(size: NSSize(width: 16, height: 14), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: r.midY - h / 2, width: 14, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

final class FilesMarkupMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

// MARK: Tuval

/// Fotoğrafın üstündeki çizim yüzeyi. Önizlemedeki resim görünümüyle aynı çerçevede durur; resmi de kendisi çizer
/// ki fosforlu kalem gerçekten çarpma karışımıyla görünsün (kaydedilen dosyadaki gibi).
final class FilesMarkupCanvas: NSView, NSTextViewDelegate {
    let session: FilesMarkupSession
    private weak var imageView: NSImageView?

    private enum Drag {
        case none
        case stroke([CGPoint])
        case shape(CGPoint)
        case move(UUID, CGPoint, FilesMarkupItem)
    }
    private var drag = Drag.none
    /// Çizilmekte olan öğe
    private(set) var draft: FilesMarkupItem?
    private(set) var textView: NSTextView?
    private var editing: (id: UUID?, origin: CGPoint, px: CGFloat)?
    private var cache: (key: String, image: CGImage)?

    init(session: FilesMarkupSession, imageView: NSImageView?) {
        self.session = session
        self.imageView = imageView
        super.init(frame: imageView?.frame ?? .zero)
        session.canvas = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { true }

    var isEditingText: Bool { textView != nil }

    // MARK: Koordinat

    var sx: CGFloat { session.pixelSize.width / max(bounds.width, 1) }
    var sy: CGFloat { session.pixelSize.height / max(bounds.height, 1) }
    /// Bir ekran noktası kaç resim pikseli
    var pxPerPoint: CGFloat { (sx + sy) / 2 }

    func toImage(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
    func toView(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x / sx, y: p.y / sy) }
    func toView(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX / sx, y: r.minY / sy, width: r.width / sx, height: r.height / sy)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), session.pixelSize.width), y: min(max(p.y, 0), session.pixelSize.height))
    }

    private func imagePoint(_ e: NSEvent) -> CGPoint { clamp(toImage(convert(e.locationInWindow, from: nil))) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeTextView()
        needsDisplay = true
    }

    // MARK: İmleç

    func toolChanged() {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private var cursor: NSCursor {
        switch session.tool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // MARK: Çizim

    /// Resmin tuval boyunda (Retina pikseli) önbelleklenmiş kopyası
    private func displayImage() -> CGImage? {
        guard let ns = imageView?.image else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let w = max(1, Int((bounds.width * scale).rounded())), h = max(1, Int((bounds.height * scale).rounded()))
        let key = "\(ObjectIdentifier(ns).hashValue)-\(w)x\(h)"
        if let cache, cache.key == key { return cache.image }
        var r = NSRect(x: 0, y: 0, width: w, height: h)
        guard let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return cg }
        cache = (key, out)
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let img = displayImage() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / sx, y: 1 / sy)
        FilesMarkupRenderer.draw(session.doc.items, in: ctx, skip: editing?.id)
        if let draft { FilesMarkupRenderer.draw(draft, in: ctx) }
        ctx.restoreGState()

        // Seçim ve yazı kutusu: her fotoğrafta görünsün diye koyu hale + beyaz kesikli çizgi
        var outlines: [NSRect] = []
        if let it = session.doc.item(session.selection), it.id != editing?.id {
            outlines.append(toView(it.bounds).insetBy(dx: -4, dy: -4))
        }
        if let tv = textView { outlines.append(tv.frame.insetBy(dx: -4, dy: -3)) }
        for r in outlines {
            let path = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(3)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: Fare

    private func newItem(_ shape: FilesMarkupItem.Shape) -> FilesMarkupItem {
        var it = FilesMarkupItem(shape: shape, color: session.color, step: session.step, width: 1)
        it.width = FilesMarkupWidth.points(session.step, for: it.kind) * pxPerPoint
        return it
    }

    override func mouseDown(with e: NSEvent) {
        guard !session.saving else { return }
        if textView != nil {
            // Başka yere tık: yazıyı bitir (yeni yazı açmaz)
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(e)
        let tol = 4 * pxPerPoint
        let doc = session.doc
        switch session.tool {
        case .select:
            if let id = doc.hitTest(p, tolerance: tol), let it = doc.item(id) {
                session.select(id)
                if e.clickCount >= 2, it.kind == .text { beginText(editing: it); return }
                doc.beginLive()
                drag = .move(id, p, it)
            } else {
                session.select(nil)
            }
        case .text:
            if let id = doc.hitTest(p, tolerance: tol), let it = doc.item(id), it.kind == .text {
                session.select(id)
                beginText(editing: it)
            } else {
                session.select(nil)
                beginText(at: p)
            }
        case .pen, .highlighter:
            session.select(nil)
            drag = .stroke([p])
            draft = newItem(session.tool == .pen ? .pen([p]) : .highlighter([p]))
        case .arrow, .rect, .ellipse:
            session.select(nil)
            drag = .shape(p)
            draft = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard !session.saving else { return }
        let p = imagePoint(e)
        let shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .stroke(var pts):
            if let last = pts.last, hypot(p.x - last.x, p.y - last.y) < 1.5 * pxPerPoint { return }
            pts.append(p)
            drag = .stroke(pts)
            if var d = draft {
                d.shape = d.kind == .pen ? .pen(pts) : .highlighter(pts)
                draft = d
            }
        case .shape(let start):
            let kind: FilesMarkupItem.Kind = session.tool == .arrow ? .arrow : (session.tool == .rect ? .rect : .ellipse)
            let end = shift ? clamp(FilesMarkupGeometry.constrain(kind, from: start, to: p)) : p
            var d = draft ?? newItem(.arrow(start, end))
            switch kind {
            case .arrow: d.shape = .arrow(start, end)
            case .rect: d.shape = .rect(FilesMarkupGeometry.rect(start, end))
            default: d.shape = .ellipse(FilesMarkupGeometry.rect(start, end))
            }
            draft = d
        case .move(let id, let start, let original):
            let d = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            session.doc.live { list in
                if let i = list.firstIndex(where: { $0.id == id }) { list[i] = original.moved(by: d) }
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; draft = nil; needsDisplay = true }
        switch drag {
        case .none:
            return
        case .stroke:
            if let d = draft { session.doc.add(d) }
        case .shape:
            // Kıl kadar sürükleme (tık) şekil bırakmaz
            if let d = draft {
                let min = 3 * pxPerPoint
                let big: Bool
                switch d.shape {
                case .arrow(let a, let b): big = hypot(b.x - a.x, b.y - a.y) >= min
                case .rect(let r), .ellipse(let r): big = r.width >= min || r.height >= min
                default: big = true
                }
                if big { session.doc.add(d) }
            }
        case .move:
            session.doc.endLive()
        }
    }

    // MARK: Klavye

    override func keyDown(with e: NSEvent) {
        guard !session.saving else { return }
        switch e.keyCode {
        case 51, 117: session.deleteSelection()           // Sil
        case 53: session.onCancel()                        // Esc
        case 36, 76: session.onSave()                      // Return
        default: break                                     // ok tuşları, boşluk: başka dosyaya geçilmez
        }
    }

    /// ⌘ kısayolları: işaretlerken uygulama menüsüne gitmesin (yoksa Dosyalar penceresindeki seçime işlerdi, ör. ⌘⌫)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.isKeyWindow == true || window?.firstResponder === self || textView != nil else {
            return super.performKeyEquivalent(with: e)
        }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) else { return super.performKeyEquivalent(with: e) }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command, ["q", "h"].contains(ch) { return false }
        if mods == [.command, .option], ch == "h" { return false }
        if let tv = textView {
            switch (ch, mods) {
            case ("z", .command): tv.undoManager?.undo()
            case ("z", [.command, .shift]): tv.undoManager?.redo()
            case ("c", .command): tv.copy(nil)
            case ("x", .command): tv.cut(nil)
            case ("v", .command): tv.pasteAsPlainText(nil)
            case ("a", .command): tv.selectAll(nil)
            default: break
            }
            return true
        }
        guard !session.saving else { return true }
        switch (ch, mods) {
        case ("z", .command): session.undo()
        case ("z", [.command, .shift]): session.redo()
        case ("w", .command): session.onCancel()
        case ("s", .command): session.onSave()
        default: break
        }
        return true
    }

    // MARK: Yazı

    private func fontPoints(_ px: CGFloat) -> CGFloat { max(4, px / pxPerPoint) }

    func beginText(at p: CGPoint) {
        let px = FilesMarkupWidth.font[min(max(session.step, 0), 2)] * pxPerPoint
        let lh = FilesMarkupRenderer.lines("", fontSize: px).lineHeight
        let origin = clamp(CGPoint(x: p.x, y: p.y - lh / 2))
        startEditor(id: nil, origin: origin, text: "", px: px)
    }

    func beginText(editing it: FilesMarkupItem) {
        guard case .text(let s, let o) = it.shape else { return }
        session.select(it.id)
        startEditor(id: it.id, origin: o, text: s, px: it.width)
    }

    private func startEditor(id: UUID?, origin: CGPoint, text: String, px: CGFloat) {
        textView?.removeFromSuperview()
        let tv = FilesMarkupTextView(frame: NSRect(origin: toView(origin), size: NSSize(width: 8, height: 20)))
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        let big = CGFloat.greatestFiniteMagnitude
        tv.textContainer?.containerSize = NSSize(width: big, height: big)
        tv.maxSize = NSSize(width: big, height: big)
        tv.focusRingType = .none
        tv.delegate = self
        tv.string = text
        editing = (id, origin, px)
        textView = tv
        addSubview(tv)
        restyleText()
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        window?.makeFirstResponder(tv)
        session.editingText = true
        needsDisplay = true
    }

    /// Yazının rengi / boyu oturumdakine uyar (yazarken renk ya da kalınlık değişirse)
    func restyleText(stepChanged: Bool = false) {
        guard let tv = textView, var ed = editing else { return }
        if stepChanged {
            ed.px = FilesMarkupWidth.font[min(max(session.step, 0), 2)] * pxPerPoint
            editing = ed
        }
        let f = NSFont.systemFont(ofSize: fontPoints(ed.px), weight: .semibold)
        let c = FilesMarkupColor.at(session.color).ns
        tv.font = f
        tv.textColor = c
        tv.insertionPointColor = c
        tv.typingAttributes = [.font: f, .foregroundColor: c]
        if let storage = tv.textStorage {
            storage.setAttributes([.font: f, .foregroundColor: c], range: NSRange(location: 0, length: storage.length))
        }
        placeTextView()
    }

    /// Yazı kutusunun yeri ve boyu (resmin konumundan; önizleme boyutlanınca da)
    private func placeTextView() {
        guard let tv = textView, let ed = editing else { return }
        let f = tv.font ?? NSFont.systemFont(ofSize: 13)
        let wanted = fontPoints(ed.px)
        if abs(f.pointSize - wanted) > 0.01 { restyleText(); return }
        let lh = FilesMarkupRenderer.lines("", fontSize: f.pointSize).lineHeight
        var used = NSSize(width: 0, height: lh)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            used = lm.usedRect(for: tc).size
        }
        tv.frame = NSRect(origin: toView(ed.origin), size: NSSize(width: max(ceil(used.width) + 2, 6), height: max(ceil(used.height), lh)))
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { placeTextView() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.insertTab(_:)) {
            commitText()
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    /// Yazıyı işaret olarak bırak; boşsa (yeniden düzenlenen yazı boşaltıldıysa o da) silinir
    func commitText() {
        guard let tv = textView, let ed = editing else { return }
        let s = tv.string
        let empty = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        endEditor()
        let px = ed.px
        if let id = ed.id {
            if empty {
                session.doc.remove(id)
            } else {
                let color = session.color, step = session.step
                session.doc.update(id) { it in
                    it.shape = .text(s, ed.origin)
                    if it.color != color { it.color = color }
                    if it.step != step || it.width != px { it.step = step; it.width = px }
                }
            }
        } else if !empty {
            session.doc.add(FilesMarkupItem(shape: .text(s, ed.origin), color: session.color, step: session.step, width: px))
        }
    }

    /// Esc: bu yazıdan vazgeç (yeniden düzenlenen yazı eski hâliyle kalır)
    func cancelText() { endEditor() }

    private func endEditor() {
        guard let tv = textView else { return }
        textView = nil
        editing = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        session.editingText = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Kip biterken: yazı varsa sessizce bırakılır, görünüm kaldırılır
    func teardown() {
        if let tv = textView {
            textView = nil
            editing = nil
            tv.delegate = nil
            tv.removeFromSuperview()
        }
        drag = .none
        draft = nil
        session.canvas = nil
        removeFromSuperview()
    }
}

/// Yazı kutusu: anahtar olmayan panelde de ilk tık yazıya gitsin
final class FilesMarkupTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

// MARK: - Araç çubuğu (SwiftUI)

/// Önizleme başlığının yerine geçen işaretleme çubuğu. Ölçü, köşe ve renkler başlıktaki simge düğmeleriyle aynı
/// (FilesPreviewIconButtonStyle); seçili araç / renk / kalınlık her temada belirgin. Dar pencerede renk ve kalınlık,
/// daha darda araçlar da Dosyalar'ın temalı menüsüne iner; en darda Vazgeç / Kaydet simgeye döner.
struct FilesMarkupToolbar: View {
    @ObservedObject var session: FilesMarkupSession
    @Environment(\.filesPalette) private var p

    enum Level: Int, Comparable {
        case full, compact, minimal, tiny
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        GeometryReader { g in
            row(Self.level(for: g.size.width, p: p))
                .frame(width: g.size.width, height: g.size.height)
        }
        .disabled(session.saving)
    }

    // MARK: Ölçüler

    static let button: CGFloat = 28
    static let swatch: CGFloat = 20
    static let spacing: CGFloat = 6

    private static func textWidth(_ s: String, _ size: CGFloat, _ w: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w)]).width.rounded(.up)
    }

    /// Yazılı düğmenin genişliği (FilesButtonStyle / sistem düğmesinin payları)
    static func textButtonWidth(_ s: String, primary: Bool, p: FilesPalette) -> CGFloat {
        switch p.theme {
        case .windows: return max(96, textWidth(s, 13, primary ? .semibold : .regular) + 32)
        case .finder: return textWidth(s, 11, .regular) + 26
        case .missing, .glass: return textWidth(s, 11.5, primary ? .semibold : .regular) + 20
        }
    }

    static func level(for width: CGFloat, p: FilesPalette) -> Level {
        let b = button, gap = spacing
        let tools = 7 * b + 6
        let swatches = 7 * swatch
        let widths = 3 * b + 2
        let undo = 2 * b + 1
        let texts = textButtonWidth(L("Vazgeç"), primary: false, p: p) + textButtonWidth(L("Kaydet"), primary: true, p: p)
        let icons = b + 34
        let full = tools + 1 + swatches + 1 + widths + 1 + undo + 4 + texts + 9 * gap
        let compact = tools + 2 * b + 1 + undo + 4 + texts + 7 * gap
        let minimal = 3 * b + 1 + undo + 4 + icons + 7 * gap
        if width >= full { return .full }
        if width >= compact { return .compact }
        if width >= minimal { return .minimal }
        return .tiny
    }

    // MARK: Satır

    @ViewBuilder private func row(_ level: Level) -> some View {
        HStack(spacing: Self.spacing) {
            if level <= .compact { tools } else { menuButton(.tool) { toolIcon(session.tool) } .help(L("Araç")) }
            if level == .full {
                separator
                swatches
                separator
                widths
            } else {
                menuButton(.color) { swatchDot(session.color, size: 13) }.help(L("Renk"))
                menuButton(.width) { widthGlyph(session.step) }.help(L("Kalınlık"))
            }
            if level != .tiny {
                separator
                undoRedo
            }
            Spacer(minLength: 4)
            if session.saving { ProgressView().controlSize(.small).scaleEffect(0.8) }
            if level <= .compact { textButtons } else { iconButtons }
        }
    }

    private var separator: some View {
        Rectangle().fill(p.fg.opacity(p.theme == .glass ? 0.14 : 0.12)).frame(width: 1, height: 18)
    }

    private func toolIcon(_ t: FilesMarkupTool) -> some View {
        Image(systemName: t.symbol)
    }

    private var tools: some View {
        HStack(spacing: 1) {
            ForEach(FilesMarkupTool.allCases) { t in
                Button { session.setTool(t) } label: { toolIcon(t) }
                    .buttonStyle(FilesMarkupToggleStyle(p: p, selected: session.tool == t))
                    .help(t.title)
                    .accessibilityLabel(t.title)
            }
        }
        .fixedSize()
    }

    private func swatchDot(_ i: Int, size: CGFloat) -> some View {
        Circle()
            .fill(Color(nsColor: FilesMarkupColor.at(i).ns))
            .overlay(Circle().strokeBorder(p.fg.opacity(p.dark ? 0.45 : 0.35), lineWidth: 0.75))
            .frame(width: size, height: size)
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(0..<FilesMarkupColor.palette.count, id: \.self) { i in
                let on = session.color == i
                Button { session.setColor(i) } label: {
                    ZStack {
                        swatchDot(i, size: 14)
                        if on {
                            Circle().strokeBorder(p.fg.opacity(0.9), lineWidth: 1.75).frame(width: 20, height: 20)
                        }
                    }
                    .frame(width: Self.swatch, height: Self.button)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(FilesMarkupColor.palette[i].name))
                .accessibilityLabel(L(FilesMarkupColor.palette[i].name))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    /// Kalınlık çizgisi; metin aracında (ya da seçili yazıda) yazı boyunu gösteren "A"
    @ViewBuilder private func widthGlyph(_ i: Int) -> some View {
        let textMode = session.tool == .text || session.doc.item(session.selection)?.kind == .text
        if textMode {
            Text("A").font(.system(size: [9.5, 12.5, 16][min(max(i, 0), 2)], weight: .semibold))
        } else {
            Capsule().frame(width: 14, height: [1.5, 3, 5][min(max(i, 0), 2)])
        }
    }

    private var widths: some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                Button { session.setStep(i) } label: { widthGlyph(i) }
                    .buttonStyle(FilesMarkupToggleStyle(p: p, selected: session.step == i))
                    .help(L(FilesMarkupWidth.titles[i]))
                    .accessibilityLabel(L(FilesMarkupWidth.titles[i]))
            }
        }
        .fixedSize()
    }

    private var undoRedo: some View {
        HStack(spacing: 1) {
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .disabled(!session.canUndo)
                .help(L("Geri al") + "  ⌘Z")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .disabled(!session.canRedo)
                .help(L("Yinele") + "  ⇧⌘Z")
        }
        .fixedSize()
    }

    private func menuButton<L: View>(_ kind: FilesMarkupSession.MenuKind, @ViewBuilder label: () -> L) -> some View {
        FilesMarkupMenuButton(session: session, kind: kind, p: p, label: label())
    }

    private var textButtons: some View {
        HStack(spacing: Self.spacing) {
            Button(L("Vazgeç")) { session.onCancel() }
                .filesButton(.normal, p, small: p.theme != .windows)
                .fixedSize()
                .help(L("Vazgeç") + "  Esc")
            Button(L("Kaydet")) { session.onSave() }
                .filesButton(.primary, p, small: p.theme != .windows)
                .fixedSize()
                .help(L("Kaydet") + "  ↩")
        }
    }

    private var iconButtons: some View {
        HStack(spacing: Self.spacing) {
            Button { session.onCancel() } label: { Image(systemName: "xmark") }
                .buttonStyle(FilesPreviewIconButtonStyle(p: p))
                .help(L("Vazgeç") + "  Esc")
            Button { session.onSave() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: p.theme == .windows ? 18 : nil)
            }
            .filesButton(.primary, p, small: true)
            .fixedSize()
            .help(L("Kaydet") + "  ↩")
        }
    }
}

/// Dar çubukta menü açan düğme (seçili araç / renk / kalınlık ve küçük ok)
private struct FilesMarkupMenuButton<Label: View>: View {
    let session: FilesMarkupSession
    let kind: FilesMarkupSession.MenuKind
    let p: FilesPalette
    let label: Label
    @State private var frame: NSRect = .zero

    var body: some View {
        Button { session.showMenu(kind, from: frame) } label: {
            HStack(spacing: 1) {
                label
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold)).opacity(0.7)
            }
        }
        .buttonStyle(FilesPreviewIconButtonStyle(p: p))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { frame = $0 }
        })
    }
}

/// Seçilebilen simge düğmesi: seçili değilken başlıktaki simge düğmesinin aynısı; seçiliyken temanın vurgusu
struct FilesMarkupToggleStyle: ButtonStyle {
    let p: FilesPalette
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        if selected {
            SelectedBody(configuration: configuration, p: p)
        } else {
            FilesPreviewIconButtonStyle(p: p).makeBody(configuration: configuration)
        }
    }

    private struct SelectedBody: View {
        let configuration: Configuration
        let p: FilesPalette

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: p.theme == .finder ? 24 : 28)
                .background(shape.fill(fill))
                .overlay(shape.stroke(stroke, lineWidth: 1))
                .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                .contentShape(Rectangle())
                .accessibilityAddTraits(.isSelected)
        }

        private var shape: AnyShape {
            switch p.theme {
            case .glass: return AnyShape(Circle())
            case .windows: return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            case .finder: return AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            case .missing: return AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }

        /// Kaydet düğmesiyle aynı dolgu (missing kırmızı, glass mor, finder sistem vurgusu); windows'ta hafif vurgu zemini
        private var fill: Color {
            switch p.theme {
            case .missing: return Brand.red
            case .glass: return p.dark ? p.accent.opacity(0.85) : Color(red: 0.50, green: 0.38, blue: 0.94)
            case .finder: return p.accent
            case .windows: return p.accent.opacity(p.dark ? 0.26 : 0.15)
            }
        }

        private var stroke: Color {
            switch p.theme {
            case .missing: return .white.opacity(0.14)
            case .glass: return .white.opacity(0.30)
            case .finder: return .clear
            case .windows: return p.accent.opacity(p.dark ? 0.75 : 0.65)
            }
        }

        private var foreground: Color {
            p.theme == .windows ? p.accent : .white
        }
    }
}

// MARK: - Önizleme penceresiyle bağlantı

extension FilesPreviewPanel {
    var markupSession: FilesMarkupSession? { model.markup }

    /// İşaretle düğmesi: fotoğraf yerinde kalır, tuval üstüne biner, panel anahtar olur
    func beginMarkup() {
        guard model.markup == nil, let info = model.info, info.media == .image, let px = info.mediaPixels,
              px.width > 0, px.height > 0, let panel, let root, panel.isVisible else { return }
        let s = FilesMarkupSession(url: info.url, pixelSize: px)
        let canvas = FilesMarkupCanvas(session: s, imageView: root.imageView)
        root.mediaClip.addSubview(canvas, positioned: .above, relativeTo: nil)
        root.markupCanvas = canvas
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        s.onCancel = { [weak self] in self?.cancelMarkup() }
        s.onSave = { [weak self] in self?.saveMarkup() }
        s.refocus = { [weak panel, weak canvas] in
            guard let panel, let canvas, panel.markupActive else { return }
            if !panel.isKeyWindow { panel.makeKey() }
            if canvas.textView == nil { panel.makeFirstResponder(canvas) }
        }
        s.menuPoint = { [weak panel] r in
            guard let f = panel?.frame else { return nil }
            return NSPoint(x: f.minX + r.minX, y: f.maxY - r.maxY - 4)
        }
        model.markup = s
        panel.markupActive = true
        panel.makeKey()
        panel.makeFirstResponder(canvas)
    }

    /// Kipten çık (işaretler sessizce bırakılır); panel yeniden anahtar olmayan pencere, Dosyalar anahtar olur
    func endMarkup() {
        guard let s = model.markup else { return }
        if FilesContextMenu.shared.isOpen { FilesContextMenu.shared.close() }
        if let c = s.canvas { c.teardown() }
        markupIgnored = nil
        root?.markupCanvas = nil
        model.markup = nil
        guard let panel else { return }
        let wasKey = panel.isKeyWindow
        panel.markupActive = false
        panel.makeFirstResponder(nil)
        if wasKey {
            if let host, host.isVisible { host.makeKey() } else { panel.resignKey() }
        }
    }

    /// İşaretlenmiş (ya da boş olmayan yazı yazılan) fotoğraf: kaybolmasın diye sorulmadan bırakılmaz
    var markupHasContent: Bool {
        guard let s = model.markup else { return false }
        if !s.doc.isEmpty { return true }
        if let tv = s.canvas?.textView, !tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    /// Dosyalar'dan gelen seçim önizlemeyi değiştirmesin mi: işaret varken ve fotoğraf hâlâ oradayken evet.
    /// Dosya silindiyse ya da klasör / sekme değiştiyse sorulacak yer yok: işaretler sessizce bırakılır (hayır).
    func markupKeepsPreview(for urls: [URL]) -> Bool {
        guard let s = model.markup else { return false }
        if s.saving { return true }
        guard markupHasContent else { return false }
        let dir = s.url.deletingLastPathComponent().fileKey
        let exists = FileManager.default.fileExists(atPath: s.url.path)
        let here = urls.contains { $0.deletingLastPathComponent().fileKey == dir } || controller?.tab.url.fileKey == dir
        return exists && here
    }

    /// Kapatma isteği (Space / ⌘Y, kapat düğmesi, Esc): işaret varsa önce sorulur; kaydedilirken yok sayılır
    func requestClose() {
        guard model.markup != nil, markupHasContent || model.markup?.saving == true else { close(); return }
        confirmDiscard { [weak self] in self?.close() }
    }

    /// Vazgeç / Esc: işaret varsa bir kez sorulur; Sil'den sonra önizleme Dosyalar'daki seçime döner
    func cancelMarkup() {
        confirmDiscard { [weak self] in
            guard let self else { return }
            let ignored = self.markupIgnored
            self.endMarkup()
            if let ignored { self.update(urls: ignored.urls, index: ignored.index) }
        }
    }

    /// "İşaretlemeler silinsin mi?" (Vazgeç / Sil); işaret yoksa doğrudan `discard`. Soru açıkken ya da kaydedilirken tekrar sorulmaz.
    private func confirmDiscard(_ discard: @escaping () -> Void) {
        guard let s = model.markup, !s.saving, !s.asking else { return }
        s.canvas?.commitText()
        if s.doc.isEmpty { discard(); return }
        s.asking = true
        FilesDialog.show(on: panel, title: L("İşaretlemeler silinsin mi?"), icon: .warning,
                         actions: [.init(L("Vazgeç"), .cancel), .init(L("Sil"), .destructiveDefault)]) { [weak self, weak s] i, _ in
            guard let self, let s, self.model.markup === s else { return }
            s.asking = false
            if i == 1 { discard() } else { s.refocus() }
        }
    }

    /// Kaydet / Return: işaret yoksa yalnız kipten çıkar; varsa nereye yazılacağı sorulur
    func saveMarkup() {
        guard let s = model.markup, !s.saving, !s.asking else { return }
        s.canvas?.commitText()
        if s.doc.isEmpty { endMarkup(); return }
        let plan = FilesMarkupSaver.plan(for: s.url)
        let actions: [FilesDialog.Action] = plan.canOverwrite
            ? [.init(L("Vazgeç"), .cancel), .init(L("Yeni dosya")), .init(L("Üstüne yaz"), .primary)]
            : [.init(L("Vazgeç"), .cancel), .init(L("Yeni dosya"), .primary)]
        s.asking = true
        FilesDialog.show(on: panel, title: L("İşaretli fotoğraf nasıl kaydedilsin?"), actions: actions) { [weak self, weak s] i, _ in
            guard let self, let s, self.model.markup === s else { return }
            s.asking = false
            switch i {
            case 1: self.performMarkupSave(.newFile)
            case 2: self.performMarkupSave(.overwrite)
            default: s.refocus()
            }
        }
    }

    /// Arkada çizip yazar; bitince Dosyalar'da seçili gelir ve önizleme kaydedilen dosyayı gösterir
    func performMarkupSave(_ mode: FilesMarkupSaver.Mode, done: ((Result<URL, Error>) -> Void)? = nil) {
        guard let s = model.markup, !s.saving else { return }
        s.canvas?.commitText()
        s.saving = true
        let url = s.url
        let items = s.doc.items
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do { result = .success(try FilesMarkupSaver.save(url, items: items, mode: mode).url) } catch { result = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let written):
                    self.markupSaved(written, session: s)
                case .failure(let e):
                    s.saving = false
                    if self.model.markup === s { FilesDialog.error(e, in: self.panel) }
                }
                done?(result)
            }
        }
    }

    private func markupSaved(_ written: URL, session s: FilesMarkupSession) {
        let stillShowing = model.markup === s
        if stillShowing { endMarkup() }
        FileIcons.shared.forget(written)
        let dir = written.deletingLastPathComponent()
        if let c = controller, c.window?.isVisible == true, c.tab.url.fileKey == dir.fileKey {
            c.tab.pendingSelect = [written]
            c.tab.reload()
        } else if FilesManager.shared.hasWindows {
            FilesManager.shared.reveal(written)
        }
        if stillShowing { showSaved(written) }
    }
}
