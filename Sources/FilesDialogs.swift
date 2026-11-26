import AppKit
import Combine
import SwiftUI

// MARK: - Dosyalar'ın ikincil pencereleri: ortak tema parçaları ve uyarı penceresi
//
// Bilgi Al, yeni klasör, onay / hata uyarıları ve kopyalama kartı seçili temaya uyar.
// finder: gerçek macOS (uyarılar NSAlert), windows: Windows 11 iletişim kutusu,
// missing: koyu cam + marka kırmızısı, glass: ince bulanık cam + mor vurgu, hap düğmeler.

extension FilesPalette {
    /// Ana pencere dışındaki yüzeylerin paleti. Missing her zaman koyu cam; diğerleri sistemin açık/koyu ayarını izler.
    static func dialog(theme: FilesTheme, systemDark: Bool) -> FilesPalette {
        FilesPalette(theme: theme, dark: theme == .missing || systemDark)
    }

    @MainActor static func dialog(for appearance: NSAppearance?) -> FilesPalette {
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dialog(theme: FilesThemeStore.shared.theme, systemDark: dark)
    }

    /// İletişim kutusu / bilgi penceresi köşesi
    var dialogRadius: CGFloat {
        switch theme {
        case .missing: return 12
        case .finder: return 10
        case .windows: return 8
        case .glass: return 14
        }
    }

    /// İkincil metin
    var secondary: Color {
        switch theme {
        case .finder: return Color(nsColor: .secondaryLabelColor)
        case .missing: return .white.opacity(0.55)
        default: return fg.opacity(dark ? 0.6 : 0.56)
        }
    }

    /// Yüzeyin ince kenarı
    var dialogBorder: Color {
        switch theme {
        case .missing: return .white.opacity(0.10)
        case .windows: return dark ? .white.opacity(0.09) : .black.opacity(0.10)
        case .glass: return dark ? .white.opacity(0.22) : .white.opacity(0.75)
        case .finder: return fg.opacity(0.10)
        }
    }

    /// Windows 11: iletişim kutusunun içerik yüzeyi (#2B2B2B / beyaz)
    var winSurface: Color { dark ? Color(red: 0.169, green: 0.169, blue: 0.169) : .white }
    /// Windows 11: alttaki düğme şeridi ve pencere zemini (#202020 / #F3F3F3)
    var winBand: Color { dark ? Color(red: 0.125, green: 0.125, blue: 0.125) : Color(red: 0.953, green: 0.953, blue: 0.953) }

    /// Bilgi kartları (Missing / cam) dolgusu
    var cardFill: Color {
        theme == .glass ? glassFill(0.07) : .white.opacity(0.05)
    }
    var cardStroke: Color {
        theme == .glass ? glassStroke(0.16) : .white.opacity(0.08)
    }

    /// Yıkıcı işlem rengi
    var destructive: Color {
        theme == .windows ? (dark ? Color(red: 1, green: 0.6, blue: 0.64) : Color(red: 0.77, green: 0.17, blue: 0.11))
                          : Color(red: 1, green: 0.27, blue: 0.23)
    }
}

/// Ana pencere dışındaki temalı görünümlerin kökü: tema değişince ve sistem açık/koyu değişince yeniden çizilir
struct FilesThemedRoot<Content: View>: View {
    @ObservedObject private var store = FilesThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    /// true: görünümü olduğu gibi bırak (ör. sistem menüsünün içi); Missing de koyuya zorlanmaz
    var followsHost = false
    let content: (FilesPalette) -> Content

    init(followsHost: Bool = false, @ViewBuilder content: @escaping (FilesPalette) -> Content) {
        self.followsHost = followsHost
        self.content = content
    }

    var body: some View {
        let p = followsHost ? FilesPalette(theme: store.theme, dark: scheme == .dark)
                            : FilesPalette.dialog(theme: store.theme, systemDark: scheme == .dark)
        content(p)
            .environment(\.filesPalette, p)
            .environment(\.colorScheme, p.dark ? .dark : .light)
            .tint(p.accent)
    }
}

// MARK: Yüzey

/// Temanın iletişim kutusu zemini: missing koyu cam, glass ince cam, windows düz yüzey, finder pencere zemini
struct FilesDialogSurface: ViewModifier {
    @Environment(\.filesPalette) private var p
    /// false: köşe yuvarlatma ve kenar yok (pencerenin kendi çerçevesi çizer)
    var shaped = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: shaped ? p.dialogRadius : 0, style: .continuous)
        return content
            .background(background)
            .clipShape(shape)
            .overlay(shaped ? AnyView(shape.strokeBorder(p.dialogBorder, lineWidth: 1)) : AnyView(EmptyView()))
    }

    @ViewBuilder private var background: some View {
        switch p.theme {
        case .missing:
            ZStack {
                GlassBlur(material: .hudWindow, appearance: .darkAqua)
                Color.black.opacity(0.42)
                LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.0)], startPoint: .top, endPoint: .center)
            }
        case .glass:
            ZStack {
                GlassBlur(material: .hudWindow, appearance: p.dark ? .darkAqua : .aqua)
                LinearGradient(colors: [Color(red: 0.55, green: 0.40, blue: 1.0).opacity(p.dark ? 0.16 : 0.10),
                                        Color(red: 0.20, green: 0.55, blue: 0.95).opacity(p.dark ? 0.08 : 0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                p.dark ? Color.white.opacity(0.06) : Color.white.opacity(0.40)
            }
        case .windows:
            p.winSurface
        case .finder:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

// MARK: Barındırma ve sürükleme

/// İkincil pencerelerin SwiftUI kökü: pencere anahtar değilken de ilk tık denetime ulaşır;
/// zemin pencereyi taşımaz (taşıma yalnız `FilesWindowDragArea` ve başlık çubuğundan)
final class FilesDialogHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Başlık çubuğu saydam, içerik tam boy pencerelerde güvenli alan payı olmasın: yoksa SwiftUI içeriği
    /// başlık çubuğu kadar aşağı itiyor (ya da `ignoresSafeArea` ile yukarı alınca altta boşluk kalıyor)
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Bu alana basıp sürükleyince pencere taşınır (başlıksız temaların başlık şeridi)
struct FilesWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // Çift tık: başlık çubuğu gibi (sistem ayarına göre küçült / büyüt) yok; yalnız taşı
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: Düğmeler

/// Düğme rolü. `.primary` ve `.destructiveDefault` Return'e bağlanır; `.cancel` Esc'ye
enum FilesDialogRole {
    case normal, primary, cancel, destructive, destructiveDefault
    var isDefault: Bool { self == .primary || self == .destructiveDefault }
}

/// Temalı düğme. finder'da sistemin kendi düğmesi kullanılır (bkz. `filesButton`)
struct FilesButtonStyle: ButtonStyle {
    let role: FilesDialogRole
    let p: FilesPalette
    var small = false
    /// Windows'ta düğmeler şeridi eşit paylaşır
    var stretch = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let h: CGFloat = small ? 22 : (p.theme == .windows ? 32 : 28)
        let bold = role.isDefault || (role == .destructive && p.theme != .windows)
        let minW: CGFloat = small ? 0 : (p.theme == .windows ? 96 : 76)
        let label = configuration.label
            .font(.system(size: small ? 11.5 : 13, weight: bold ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 10 : 16)
            .frame(minWidth: minW, maxWidth: stretch ? .infinity : nil)
            .frame(height: h)
        let s = shape
        return label
            .background(s.fill(fill))
            .overlay(s.stroke(stroke, lineWidth: 1))
            .overlay(s.fill(Color.black.opacity(pressed ? 0.12 : 0)))
            .contentShape(s)
            .opacity(enabled ? (pressed ? 0.85 : 1) : 0.45)
    }

    private var shape: AnyShape {
        switch p.theme {
        case .glass: return AnyShape(Capsule(style: .continuous))
        case .windows: return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        default: return AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var isFilled: Bool { role.isDefault }

    private var fill: Color {
        switch p.theme {
        case .missing:
            return isFilled ? Brand.red : p.fg.opacity(p.dark ? 0.09 : 0.06)
        case .glass:
            if role == .destructiveDefault { return Color(red: 0.92, green: 0.26, blue: 0.30).opacity(0.9) }
            // Açık zeminde beyaz yazı okunsun diye mor koyulaşır
            return isFilled ? (p.dark ? p.accent.opacity(0.85) : Color(red: 0.50, green: 0.38, blue: 0.94)) : p.glassFill(0.12)
        case .windows:
            // Windows'ta kırmızı düğme yok: yıkıcı varsayılan da vurgu renginde
            if isFilled { return p.accent }
            return p.dark ? Color(white: 0.215) : Color(white: 0.992)
        case .finder:
            return isFilled ? p.accent : p.controlFill
        }
    }

    private var stroke: Color {
        switch p.theme {
        case .missing: return isFilled ? .white.opacity(0.14) : p.fg.opacity(0.10)
        case .glass: return isFilled ? .white.opacity(0.30) : p.glassStroke(0.28)
        case .windows: return isFilled ? .black.opacity(0.08) : (p.dark ? .white.opacity(0.07) : .black.opacity(0.11))
        case .finder: return .clear
        }
    }

    private var foreground: Color {
        if isFilled { return p.theme == .missing || (role == .destructiveDefault && p.theme != .windows) ? .white : p.onAccent }
        if role == .destructive { return p.destructive }
        return p.fg
    }
}

extension View {
    /// Temaya göre düğme: finder sistem düğmesi, diğerleri `FilesButtonStyle`
    @ViewBuilder func filesButton(_ role: FilesDialogRole, _ p: FilesPalette, small: Bool = false, stretch: Bool = false) -> some View {
        if p.theme == .finder {
            self.buttonStyle(.automatic).controlSize(small ? .small : .regular)
        } else {
            self.buttonStyle(FilesButtonStyle(role: role, p: p, small: small, stretch: stretch))
        }
    }
}

// MARK: Metin alanı

/// Ad alanında açılışta seçilecek kısım. `.stem`: son noktadan önceki kısım (Finder gibi; `.gitignore`, `README` tümü)
enum FilesNameSelection {
    case all, stem

    /// Seçilecek aralık (NSString / UTF-16 uzunluklarıyla: emoji ve Türkçe harfler doğru sayılır)
    func range(for name: String) -> NSRange {
        let ns = name as NSString
        guard self == .stem else { return NSRange(location: 0, length: ns.length) }
        let ext = ns.pathExtension as NSString
        let len = ext.length == 0 ? ns.length : ns.length - ext.length - 1
        return NSRange(location: 0, length: max(0, len))
    }

    /// Düzenleyiciye uygular. `force` değilse yalnız seçim hâlâ "tümü" iken (odakta yeniden seçilmişse) düzeltir.
    /// Uygulandıysa (ya da zaten yerindeyse) true
    @discardableResult
    func apply(to editor: NSText, force: Bool) -> Bool {
        let length = (editor.string as NSString).length
        let want = range(for: editor.string)
        let current = editor.selectedRange
        if current == want { return true }
        guard force || current == NSRange(location: 0, length: length) else { return false }
        editor.selectedRange = want
        return true
    }
}

/// SwiftUI görünümünün penceresini tutar (alan düzenleyicisini NSApp.keyWindow yerine kendi penceresinde bulmak için)
final class FilesWindowBox {
    weak var window: NSWindow?
    var applied = false
}

struct FilesWindowReader: NSViewRepresentable {
    let box: FilesWindowBox

    final class Probe: NSView {
        var box: FilesWindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { box?.window = window }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.box = box
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {
        v.box = box
        if let w = v.window { box.window = w }
    }
}

/// Yerel uyarıdaki (finder teması) ad alanı: ilk yanıtlayıcı olunca istenen kısmı seçer
final class FilesSelectingTextField: NSTextField {
    var selection: FilesNameSelection = .all
    private var applied = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // super, alan düzenleyicisini kurup hepsini seçti; şimdi istenen kısmı seç, bir tur sonra yine kontrol et
        if ok, let editor = currentEditor() {
            selection.apply(to: editor, force: !applied)
            applied = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let editor = self.currentEditor() else { return }
                self.selection.apply(to: editor, force: false)
            }
        }
        return ok
    }
}

/// Temalı tek satır metin alanı. Açılınca odaklanır ve metni seçer (Finder gibi).
struct FilesThemedField: View {
    @Binding var text: String
    var placeholder: String = ""
    var autofocus = true
    /// Açılışta seçilecek kısım: tümü ya da (yeniden adlandırmada) uzantıdan önceki kısım
    var selection: FilesNameSelection = .all
    var onSubmit: () -> Void = {}
    @Environment(\.filesPalette) private var p
    @FocusState private var focused: Bool
    @State private var host = FilesWindowBox()

    var body: some View {
        Group {
            if p.theme == .finder {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: p.theme == .windows ? 32 : 30)
                    .background(shape.fill(fill))
                    .overlay(shape.strokeBorder(border, lineWidth: focused && p.theme != .windows ? 1.5 : 1))
                    .overlay(alignment: .bottom) {
                        // Windows 11: odakta altta vurgu çizgisi
                        if p.theme == .windows {
                            Rectangle().fill(focused ? p.accent : p.fg.opacity(p.dark ? 0.45 : 0.45))
                                .frame(height: focused ? 2 : 1)
                                .clipShape(shape)
                        }
                    }
            }
        }
        .focused($focused)
        .onSubmit(onSubmit)
        .onAppear {
            guard autofocus else { return }
            DispatchQueue.main.async {
                // Kapanmış (ekranda olmayan) bir pencerede yeniden çizilen alan odağı almasın
                guard host.window?.isVisible != false else { return }
                focused = true
                applySelection(step: 0)
            }
        }
        .background(FilesWindowReader(box: host))
    }

    /// Seçimi alanın kendi penceresindeki alan düzenleyicisine uygular. Sayfa açılırken AppKit odakta yeniden
    /// hepsini seçebilir: birkaç kez daha bakılır, seçim hâlâ "tümü" ise düzeltilir (kullanıcının imlecine dokunulmaz)
    private func applySelection(step: Int) {
        let delays: [Double] = [0, 0.05, 0.15, 0.3, 0.6]
        let box = host, selection = selection, text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[step]) {
            guard box.window?.isVisible != false else { return }
            if let tv = (box.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView, tv.string == text {
                if selection.apply(to: tv, force: !box.applied) { box.applied = true }
            } else if !box.applied {
                // Odak gelmediyse (ilk çizimde bekleyen bir güncelleme odağı düşürdüyse) yeniden iste. FocusState
                // hâlâ true sanıyorsa true yazmak bir şey değiştirmez: önce bırak. Seçim sonraki adımda uygulanır
                if focused {
                    focused = false
                    DispatchQueue.main.async { focused = true }
                } else {
                    focused = true
                }
            }
            if step + 1 < delays.count { applySelection(step: step + 1) }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: p.theme == .windows ? 4 : (p.theme == .glass ? 10 : 7), style: .continuous)
    }

    private var fill: Color {
        switch p.theme {
        case .missing: return p.fg.opacity(p.dark ? 0.08 : 0.05)
        case .glass: return p.glassFill(0.10)
        case .windows: return p.dark ? (focused ? Color(white: 0.12) : Color(white: 0.2)) : .white
        case .finder: return .clear
        }
    }

    private var border: Color {
        switch p.theme {
        case .missing: return focused ? Brand.red.opacity(0.85) : p.fg.opacity(0.12)
        case .glass: return focused ? p.accent.opacity(0.9) : p.glassStroke(0.28)
        case .windows: return p.dark ? .white.opacity(0.08) : .black.opacity(0.10)
        case .finder: return .clear
        }
    }
}

// MARK: Return / Esc

/// Return varsayılan düğmeye, Esc vazgeç düğmesine gider (metin alanı odaktayken de)
final class FilesKeyPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        // Yazım (IME) sürerken Return / Esc ona ait
        if let tv = firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        switch event.keyCode {
        case 36, 76:   // Return, Enter
            guard let onReturn else { return false }
            onReturn()
            return true
        case 53:       // Esc
            guard let onEscape else { return false }
            onEscape()
            return true
        default:
            return false
        }
    }
}

// MARK: - Uyarı / onay penceresi

@MainActor enum FilesDialog {
    struct Action {
        let title: String
        let role: FilesDialogRole
        init(_ title: String, _ role: FilesDialogRole = .normal) { self.title = title; self.role = role }
    }

    enum Icon {
        case app, warning, image(NSImage), none

        var image: NSImage? {
            switch self {
            case .app, .warning: return Brand.appIcon
            case .image(let i): return i
            case .none: return nil
            }
        }
    }

    struct Field {
        var text: String
        var placeholder: String = ""
        /// Açılışta seçilecek kısım (yeniden adlandırmada `.stem`: uzantı seçilmez)
        var selection: FilesNameSelection = .all
    }

    /// Temalı uyarı. Düğmeler soldan sağa sırayla dizilir (varsayılan en sağda olsun); `done(seçilen sıra, alan metni)`.
    /// Return = .primary / .destructiveDefault düğme (yoksa ilk .normal), Esc = .cancel düğme. Pencere varsa onun üstünde sayfa olarak açılır.
    static func show(on window: NSWindow?, title: String, message: String? = nil, icon: Icon = .app,
                     field: Field? = nil, actions: [Action], done: @escaping (Int, String) -> Void = { _, _ in }) {
        let actions = actions.isEmpty ? [Action(L("Tamam"), .primary)] : actions
        if FilesThemeStore.shared.theme == .finder {
            showNative(on: window, title: title, message: message, icon: icon, field: field, actions: actions, done: done)
            return
        }

        let panel = FilesKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        if FilesThemeStore.shared.theme == .missing { panel.appearance = NSAppearance(named: .darkAqua) }

        let model = FilesDialogModel(text: field?.text ?? "")
        let asSheet = window?.isVisible == true
        var finished = false
        let finish: (Int) -> Void = { [weak panel] i in
            guard !finished, let panel else { return }
            finished = true
            if asSheet {
                panel.sheetParent?.endSheet(panel)
            } else {
                NSApp.stopModal()
                panel.orderOut(nil)
            }
            done(i, model.text)
        }
        let primary = actions.firstIndex { $0.role.isDefault } ?? actions.firstIndex { $0.role == .normal }
        let cancel = actions.firstIndex { $0.role == .cancel }
        panel.onReturn = primary.map { i in { finish(i) } }
        panel.onEscape = cancel.map { i in { finish(i) } }

        let view = FilesThemedRoot { _ in
            FilesDialogView(title: title, message: message, icon: icon.image, model: model,
                            hasField: field != nil, placeholder: field?.placeholder ?? "",
                            selection: field?.selection ?? .all,
                            actions: actions, primary: primary, choose: finish)
        }
        let host = makeHost(view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        if asSheet, let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.level = .modalPanel
            NSApp.activate(ignoringOtherApps: true)
            NSApp.runModal(for: panel)
        }
    }

    /// Uyarının kökü. Başlık çubuğu saydam ve içerik tam boy: güvenli alan payı içeriği aşağı itmesin;
    /// pencere anahtar değilken de ilk tık düğmeye ulaşsın
    static func makeHost<V: View>(_ view: V) -> NSView {
        FilesDialogHostingView(rootView: view.ignoresSafeArea())
    }

    /// Hata: NSAlert(error:) gibi başlık + açıklama
    static func error(_ error: Error, in window: NSWindow?) {
        let e = error as NSError
        let detail = [e.localizedFailureReason, e.localizedRecoverySuggestion]
            .compactMap { $0 }.filter { !$0.isEmpty && $0 != e.localizedDescription }.joined(separator: "\n")
        show(on: window, title: e.localizedDescription, message: detail.isEmpty ? nil : detail, icon: .warning,
             actions: [Action(L("Tamam"), .primary)])
    }

    /// finder teması: gerçek NSAlert (varsayılan düğme sağda ilk sırada, Esc vazgeç düğmesinde)
    private static func showNative(on window: NSWindow?, title: String, message: String?, icon: Icon,
                                   field: Field?, actions: [Action], done: @escaping (Int, String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        if let message { a.informativeText = message }
        if case .warning = icon { a.alertStyle = .warning }
        if case .image(let img) = icon { a.icon = img }
        // NSAlert sağdan sola dizer: önce varsayılan, sonra diğerleri, en son vazgeç
        let primary = actions.firstIndex { $0.role.isDefault } ?? actions.firstIndex { $0.role != .cancel } ?? 0
        let order = [primary] + actions.indices.filter { $0 != primary }.sorted { a, b in
            (actions[a].role == .cancel ? 1 : 0) < (actions[b].role == .cancel ? 1 : 0)
        }
        for i in order {
            let b = a.addButton(withTitle: actions[i].title)
            if actions[i].role == .cancel { b.keyEquivalent = "\u{1b}" }
            if actions[i].role == .destructive || actions[i].role == .destructiveDefault, #available(macOS 11.0, *) {
                b.hasDestructiveAction = true
            }
        }
        var tf: NSTextField?
        if let field {
            let t = FilesSelectingTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            t.selection = field.selection
            t.stringValue = field.text
            t.placeholderString = field.placeholder
            a.accessoryView = t
            a.window.initialFirstResponder = t
            tf = t
        }
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            let k = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard order.indices.contains(k) else { return }
            done(order[k], tf?.stringValue ?? "")
        }
        if let window, window.isVisible { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
    }
}

final class FilesDialogModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

/// Temalı uyarının içeriği (finder dışındaki temalar)
struct FilesDialogView: View {
    let title: String
    let message: String?
    let icon: NSImage?
    @ObservedObject var model: FilesDialogModel
    let hasField: Bool
    let placeholder: String
    var selection: FilesNameSelection = .all
    let actions: [FilesDialog.Action]
    let primary: Int?
    let choose: (Int) -> Void
    @Environment(\.filesPalette) private var p

    var body: some View {
        Group {
            if p.theme == .windows { windows } else { glassy }
        }
        .frame(width: p.theme == .windows ? 400 : 372)
        .foregroundStyle(p.fg)
        .modifier(FilesDialogSurface())
    }

    // Missing ve cam: simge solda, başlık + açıklama, sağda düğmeler
    private var glassy: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 46, height: 46)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13.5, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message, !message.isEmpty {
                        Text(message).font(.system(size: 12)).foregroundStyle(p.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, icon == nil ? 0 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasField {
                FilesThemedField(text: $model.text, placeholder: placeholder, selection: selection) { if let primary { choose(primary) } }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons(stretch: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    // Windows 11 ContentDialog: üstte başlık + metin, altta ayrı şeritte eşit düğmeler
    private var windows: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message, !message.isEmpty {
                        Text(message).font(.system(size: 13)).foregroundStyle(p.fg.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasField {
                        FilesThemedField(text: $model.text, placeholder: placeholder, selection: selection) { if let primary { choose(primary) } }
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .background(p.winSurface)
            Rectangle().fill(p.dialogBorder).frame(height: 1)
            HStack(spacing: 8) { buttons(stretch: true) }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(p.winBand)
        }
    }

    private func rank(_ i: Int) -> Int {
        i == primary ? 0 : (actions[i].role == .cancel ? 2 : 1)
    }

    private func buttons(stretch: Bool) -> some View {
        // Windows 11: birincil düğme solda, vazgeç en sağda; macOS'ta varsayılan en sağda
        let order = p.theme == .windows
            ? actions.indices.sorted { rank($0) < rank($1) }
            : Array(actions.indices)
        return ForEach(order, id: \.self) { i in
            let a = actions[i]
            Button { choose(i) } label: { Text(a.title) }
                .filesButton(i == primary && !a.role.isDefault ? .primary : a.role, p, stretch: stretch)
        }
    }
}

// MARK: - Kopyalama kartı yüzeyi

/// Kopyalama / işlem kartının zemini: temanın iletişim kutusu yüzeyi + gölge
struct FilesCardSurface: ViewModifier {
    @Environment(\.filesPalette) private var p

    func body(content: Content) -> some View {
        let r: CGFloat = p.theme == .windows ? 8 : (p.theme == .glass ? 14 : 12)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return content
            .background(background.clipShape(shape))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(p.theme == .windows ? 0.18 : 0.25), radius: p.theme == .windows ? 16 : 12, y: 4)
    }

    @ViewBuilder private var background: some View {
        switch p.theme {
        case .missing:
            ZStack {
                Rectangle().fill(.regularMaterial)
                p.dark ? Color.black.opacity(0.35) : Color.white.opacity(0.3)
            }
        case .glass:
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [.white.opacity(p.dark ? 0.12 : 0.55), .white.opacity(p.dark ? 0.05 : 0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
        case .windows:
            p.dark ? Color(red: 0.17, green: 0.17, blue: 0.17) : Color(red: 0.98, green: 0.98, blue: 0.98)
        case .finder:
            Rectangle().fill(.regularMaterial)
        }
    }

    private var border: Color {
        switch p.theme {
        case .glass: return p.dark ? .white.opacity(0.25) : .white.opacity(0.8)
        case .windows: return p.dark ? .white.opacity(0.08) : .black.opacity(0.10)
        case .finder: return p.fg.opacity(0.12)
        case .missing: return p.fg.opacity(0.10)
        }
    }
}
