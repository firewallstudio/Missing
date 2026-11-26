import AppKit
import SwiftUI

// MARK: - İlk tıklama (click-through)
//
// Başka uygulama öndeyken ya da Quick Look paneli anahtar pencereyken Dosyalar penceresine yapılan ilk tık
// yalnızca pencereyi öne getiriyordu; seçmek için ikinci tık gerekiyordu. AppKit ilk tıklamayı, tıklanan
// en derindeki görünüme `acceptsFirstMouse` ile sorar: bu yüzden ızgara / liste / sütunlardaki bütün parçalar
// (tablo, satır, hücre, simge, ad, ızgara kutusu) evet der. Yeniden adlandırma alanı düzenlenirken kendi davranışını korur.

/// Hücre ve kutulardaki ad / başlık yazısı: düzenlenmiyorken ilk tıklama da geçer
final class FilesLabel: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isEditable ? super.acceptsFirstMouse(for: event) : true
    }
}

/// Izgara kutusunun kökü ve zemini
final class FilesClickThroughView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Dosyalar penceresinin SwiftUI kökü: kenar çubuğu, sekmeler, araç çubuğu da arkadaki pencereye ilk tıkta yanıt verir
final class FilesClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
