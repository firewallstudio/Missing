import AppKit
import SwiftUI

// MARK: - Renk etiketleri: sağ tık satırı ve yeni klasör penceresi
//
// Finder'daki gibi renk = Finder etiketi. Etiket Finder'da da görünür; renkli klasör
// Dosyalar'da (ve macOS Tahoe Finder'ında) o renge boyanır.

/// Sağ tık menüsündeki renk noktaları; tıklanan renk seçili öğelerde aç / kapa olur
struct TagColorMenuRow: View {
    let urls: [URL]
    let done: () -> Void
    @State private var hover: Int?
    @Environment(\.filesPalette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Renk")).font(.system(size: p.theme == .windows ? 12 : 11)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(FinderTags.menuOrder, id: \.self) { i in
                    let on = has(i)
                    Circle()
                        .fill(Color(nsColor: FinderTags.nsColor(i)))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: on ? 2 : 0))
                        // Seçili renk: dışta temanın vurgusuyla ince halka (açık menüde de görünsün)
                        .padding(2)
                        .overlay(Circle().strokeBorder(on ? ringColor : .clear, lineWidth: 1.5))
                        .overlay {
                            if on { Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white) }
                        }
                        .scaleEffect(hover == i ? 1.2 : 1)
                        .animation(.easeOut(duration: 0.1), value: hover)
                        .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                        .onTapGesture {
                            FinderTags.toggle(color: i, on: urls)
                            done()
                        }
                        .help(FinderTags.name(forColor: i))
                }
            }
        }
        // Menünün yazı sütunuyla hizalı (temaya göre: Windows'ta simge sütunu daha geniş)
        .padding(.leading, FilesContextMenu.textInset(for: p))
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(minWidth: 210, alignment: .leading)
    }

    private var ringColor: Color {
        switch p.theme {
        case .missing, .finder: return p.fg.opacity(0.55)
        case .windows, .glass: return p.accent
        }
    }

    private func has(_ i: Int) -> Bool {
        !urls.isEmpty && urls.allSatisfy { u in
            (((try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil) ?? []).contains { FinderTags.colorIndex(for: $0) == i }
        }
    }

    /// Menüye eklenecek öğe
    @MainActor static func menuItem(for urls: [URL], changed: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let host = FilesMenuHostingView(rootView: AnyView(EmptyView()))   // ilk tıklama da renge ulaşsın
        host.rootView = AnyView(FilesThemedRoot(followsHost: true) { _ in
            TagColorMenuRow(urls: urls) { [weak item] in
                item?.menu?.cancelTracking()
                changed()
            }
        })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        item.view = host
        return item
    }
}

// MARK: Yeni klasör

@MainActor final class NewFolderSheet {
    /// Pencerenin üstünde ad + renk sorar; Oluştur'a basınca `create(ad, renk)` çağrılır.
    /// Görünüm seçili temaya uyar; Return oluşturur, Esc vazgeçer.
    static func show(on window: NSWindow, create: @escaping (String, Int?) -> Void) {
        let panel = FilesKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        if FilesThemeStore.shared.theme == .missing { panel.appearance = NSAppearance(named: .darkAqua) }
        let model = NewFolderModel()
        var finished = false
        let close: () -> Void = { [weak window, weak panel] in
            guard let panel, !finished else { return }
            finished = true
            window?.endSheet(panel)
        }
        let done: () -> Void = {
            guard !finished else { return }
            close()
            create(model.name, model.color)
        }
        panel.onReturn = done
        panel.onEscape = close
        let host = NSHostingView(rootView: content(model: model, onCancel: close, onCreate: done))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        window.beginSheet(panel)
    }

    /// Sayfanın içeriği (deneme düzeneği de bunu çizer)
    static func content(model: NewFolderModel, onCancel: @escaping () -> Void, onCreate: @escaping () -> Void) -> some View {
        FilesThemedRoot { _ in NewFolderView(model: model, onCancel: onCancel, onCreate: onCreate) }
    }
}

final class NewFolderModel: ObservableObject {
    @Published var name = L("adsız klasör")
    @Published var color: Int?
}

private struct NewFolderView: View {
    @ObservedObject var model: NewFolderModel
    let onCancel: () -> Void
    let onCreate: () -> Void
    @Environment(\.filesPalette) private var p

    private static let folder = NSWorkspace.shared.icon(for: .folder)

    var body: some View {
        Group {
            if p.theme == .windows { windows } else { standard }
        }
        .foregroundStyle(p.fg)
        .modifier(FilesDialogSurface())
    }

    // missing / glass / finder: ortada önizleme, altında ad, renk, düğmeler
    private var standard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                folderIcon(72)
                Text(L("Yeni klasör")).font(.system(size: p.theme == .finder ? 13 : 15, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 6) {
                label(L("Ad"))
                FilesThemedField(text: $model.name, onSubmit: onCreate)
            }
            VStack(alignment: .leading, spacing: 8) {
                label(L("Renk"))
                swatches
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if p.theme == .finder { Spacer(minLength: 0) }
                Button(action: onCancel) { Text(L("Vazgeç")).frame(maxWidth: p.theme == .finder ? nil : .infinity) }
                    .filesButton(.cancel, p, stretch: true)
                    .keyboardShortcut(.cancelAction)
                Button(action: onCreate) { Text(L("Oluştur")).frame(maxWidth: p.theme == .finder ? nil : .infinity) }
                    .filesButton(.primary, p, stretch: true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 340)
    }

    // Windows 11 ContentDialog: başlık solda, altta ayrı şeritte eşit düğmeler
    private var windows: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    folderIcon(40)
                    Text(L("Yeni klasör")).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label(L("Ad"))
                    FilesThemedField(text: $model.name, onSubmit: onCreate)
                }
                VStack(alignment: .leading, spacing: 8) {
                    label(L("Renk"))
                    swatches
                }
            }
            .padding(24)
            .background(p.winSurface)
            Rectangle().fill(p.dialogBorder).frame(height: 1)
            HStack(spacing: 8) {
                Button(L("Oluştur"), action: onCreate).filesButton(.primary, p, stretch: true)
                    .keyboardShortcut(.defaultAction)
                Button(L("Vazgeç"), action: onCancel).filesButton(.cancel, p, stretch: true)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(p.winBand)
        }
        .frame(width: 380)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: p.theme == .windows ? 12 : 11, weight: p.theme == .windows ? .regular : .semibold))
            .foregroundStyle(p.theme == .windows ? p.fg.opacity(0.85) : p.secondary)
    }

    private func folderIcon(_ s: CGFloat) -> some View {
        Image(nsImage: model.color.map { FileIcons.tintedFolder(Self.folder, FinderTags.nsColor($0)) } ?? Self.folder)
            .resizable().interpolation(.high)
            .frame(width: s, height: s)
            .shadow(color: .black.opacity(0.2), radius: s > 50 ? 6 : 3, y: s > 50 ? 3 : 1)
            .animation(.easeOut(duration: 0.15), value: model.color)
    }

    private var swatches: some View {
        HStack(spacing: 9) {
            swatch(nil)
            ForEach(FinderTags.menuOrder, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ i: Int?) -> some View {
        let on = model.color == i
        return Button { model.color = i } label: {
            ZStack {
                if let i {
                    Circle().fill(Color(nsColor: FinderTags.nsColor(i)))
                } else {
                    Circle().strokeBorder(p.fg.opacity(0.35), lineWidth: 1.5)
                    Rectangle().fill(p.fg.opacity(0.45)).frame(width: 1.5, height: 16).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay(Circle().strokeBorder(on ? p.accent : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(i.map { FinderTags.name(forColor: $0) } ?? L("Renksiz"))
    }
}
