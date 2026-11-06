import AppKit
import SwiftUI

// MARK: - Missing marka renkleri ve ortak parçalar

enum Brand {
    /// #e90102
    static let nsRed = NSColor(srgbRed: 0xE9 / 255.0, green: 0x01 / 255.0, blue: 0x02 / 255.0, alpha: 1)
    static let red = Color(nsColor: nsRed)

    /// Uygulamanın yaprak logosu (renkli)
    static var leaf: NSImage { NSImage(named: "Leaf") ?? NSApp.applicationIconImage }
}

/// Aç/kapa düğmesi: kapalıyken gri, açıkken marka kırmızısı
struct BrandToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(BrandSwitchStyle())
            .labelsHidden()
    }
}

/// Pencere arkadayken de rengi kaybolmayan anahtar: kapalı gri, açık #e90102
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Brand.red : Color.white.opacity(0.16))
                .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.12 : 0.10), lineWidth: 0.5))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: 36, height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// Klavye tuşu görünümü (⌘, ⇧, Tab…)
struct KeyCap: View {
    let key: String
    var size: CGFloat = 12

    var body: some View {
        Text(key)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .padding(.horizontal, size * 0.55)
            .frame(minWidth: size * 2, minHeight: size * 1.9)
            .background(
                RoundedRectangle(cornerRadius: size * 0.45, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.45, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1.5)
    }
}

/// "⌘⇧3" gibi bir kısayolu tuş tuş çizer
struct KeyCombo: View {
    let keys: [String]
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in KeyCap(key: k, size: size) }
        }
    }
}

/// Ana eylem düğmesi: kırmızı kapsül
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(Capsule().fill(Brand.red.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

/// İkincil düğme: cam kapsül
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.20 : 0.12)))
            .contentShape(Capsule())
    }
}
