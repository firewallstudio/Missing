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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Renk")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(FinderTags.menuOrder, id: \.self) { i in
                    let on = has(i)
                    Circle()
                        .fill(Color(nsColor: FinderTags.nsColor(i)))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: on ? 2 : 0))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: 210, alignment: .leading)
    }

    private func has(_ i: Int) -> Bool {
        !urls.isEmpty && urls.allSatisfy { u in
            (((try? u.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil) ?? []).contains { FinderTags.colorIndex(for: $0) == i }
        }
    }

    /// Menüye eklenecek öğe
    @MainActor static func menuItem(for urls: [URL], changed: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(TagColorMenuRow(urls: urls) { [weak item] in
            item?.menu?.cancelTracking()
            changed()
        })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        item.view = host
        return item
    }
}

// MARK: Yeni klasör

@MainActor final class NewFolderSheet {
    /// Pencerenin üstünde ad + renk sorar; Oluştur'a basınca `create(ad, renk)` çağrılır
    static func show(on window: NSWindow, create: @escaping (String, Int?) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let p = FilesPalette.current(for: window.appearance ?? window.effectiveAppearance)
        panel.appearance = NSAppearance(named: p.dark ? .darkAqua : .aqua)
        let close: () -> Void = { [weak window, weak panel] in
            guard let panel else { return }
            window?.endSheet(panel)
        }
        let view = NewFolderView(palette: p, onCancel: close) { name, color in
            close()
            create(name, color)
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        window.beginSheet(panel)
    }
}

private struct NewFolderView: View {
    let palette: FilesPalette
    let onCancel: () -> Void
    let onCreate: (String, Int?) -> Void
    @State private var name = L("adsız klasör")
    @State private var color: Int?
    @FocusState private var focused: Bool

    private var p: FilesPalette { palette }
    private static let folder = NSWorkspace.shared.icon(for: .folder)

    var body: some View {
        VStack(spacing: 16) {
            preview
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Ad")).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.fg.opacity(0.55))
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(create)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.fg.opacity(p.dark ? 0.08 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focused ? p.accent.opacity(0.8) : p.fg.opacity(0.12), lineWidth: focused ? 1.5 : 1))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Renk")).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.fg.opacity(0.55))
                HStack(spacing: 9) {
                    swatch(nil)
                    ForEach(FinderTags.menuOrder, id: \.self) { swatch($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(L("Vazgeç")).frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.fg.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    Text(L("Oluştur")).fontWeight(.semibold).foregroundStyle(p.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.accent))
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 340)
        .foregroundStyle(p.fg)
        .background(background.ignoresSafeArea())
        .tint(p.accent)
        .onAppear {
            DispatchQueue.main.async {
                focused = true
                // Finder gibi: ad seçili gelsin, yazınca değişsin
                DispatchQueue.main.async { NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSTextView }?.selectAll(nil) }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 6) {
            Image(nsImage: color.map { FileIcons.tintedFolder(Self.folder, FinderTags.nsColor($0)) } ?? Self.folder)
                .resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .animation(.easeOut(duration: 0.15), value: color)
            Text(L("Yeni klasör")).font(.system(size: 15, weight: .bold))
        }
    }

    @ViewBuilder private var background: some View {
        switch p.theme {
        case .missing, .glass:
            ZStack { GlassBlur(material: .hudWindow, appearance: .darkAqua); Color.black.opacity(0.35) }
        case .finder:
            Color(nsColor: .windowBackgroundColor)
        case .windows:
            p.winChrome
        }
    }

    private func swatch(_ i: Int?) -> some View {
        let on = color == i
        return Button { color = i } label: {
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

    private func create() { onCreate(name, color) }
}
