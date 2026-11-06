import Foundation

// MARK: - Sürüm geçmişi (Ayarlar › Sürümler)
//
// Uygulamanın içinde gelir, internet olmadan da görünür. Her yeni sürümde en üste bir kayıt ekle.
// Her madde iki dilde yazılır: (Türkçe, English).

struct ChangelogEntry {
    let version: String
    /// GitHub'a gelmeden önceki sürümler (indirilemez, sadece geçmiş)
    var preGitHub = false
    let items: [(tr: String, en: String)]

    var lines: [String] { items.map { AppLanguage.active == .tr ? $0.tr : $0.en } }
}

enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "3.0.1", items: [
            ("Özellikler paneli: ana kısayollar (⌘Tab, ses, ekran görüntüsü, ekranı böl) canlı önizlemeyle tek yerde; kapattığın özellik Ayarlar'da, menü panelinde ve kısayol listesinde hiç görünmez",
             "Features panel: the main shortcuts (⌘Tab, sound, screenshots, split screen) with live previews in one place; anything you turn off disappears from Settings, the menu bar panel and the shortcut list"),
            ("Özellik iste: Mac'te eksik bulduğun bir özelliği GitHub'da önerebilirsin (Ayarlar › Özellik iste)",
             "Suggest a Feature: tell us what your Mac is missing on GitHub (Settings › Suggest a Feature)"),
            ("⌘Tab: pencere listesi hazırlanırken tuşlar artık beklemiyor; ekrana sığmayan pencereler kaydırılarak gösteriliyor",
             "⌘Tab: keys no longer wait while the window list is prepared; windows that don't fit scroll into view"),
            ("Çentik adası: en çok kullandığın iki düzen çentiğin hemen altında", "Notch island: your two most-used layouts sit right under the notch"),
            ("Tam Disk Erişimi doğru algılanıyor; ⌘Space sadece Finder etkinken dosya aramasını açıyor",
             "Full Disk Access is detected correctly; ⌘Space opens file search only while Finder is active"),
        ]),
        ChangelogEntry(version: "3.0.0", items: [
            ("AudioTab artık Missing: Mac'te eksik kalan özellikler tek uygulamada", "AudioTab is now Missing: the features the Mac left out, in one app"),
            ("Yeni ayarlar: kenar çubuğu, açılır kapanır kartlar, her özelliğin kendi aç/kapa düğmesi", "New settings: sidebar, collapsible cards, an on/off switch for every feature"),
            ("Hızlı Özellikler: gruplu görünüm, Finder fare tuşları, Dock'a sürükle-bırak, pencereleri her zaman bul, dosya arama ve monitör karartma tek yerde", "Quick Features: grouped view, Finder mouse buttons, Dock drag and drop, always find windows, file search and monitor blackout in one place"),
            ("Kısayollar sayfası: her kısayolun ne yaptığı animasyonla gösterilir", "Shortcuts page: every shortcut shows what it does with an animation"),
            ("Dosya arama Spotlight görünümünde ve sadece Finder öndeyken ⌘Space ile açılır", "File search looks like Spotlight and opens with ⌘Space only while Finder is in front"),
            ("Menü çubuğunda yeni cam panel: ses çıkışı, hızlı eylemler, monitörler", "New glass panel in the menu bar: sound output, quick actions, displays"),
            ("Çentikteki ekran bölme adası artık çentiğin altında canlı önizleme gösteriyor", "The notch tiling island now shows a live preview under the notch"),
            ("Dosyayı ⌘Tab panelinde bir uygulamanın üstüne bırak: o uygulamayla açılır (Finder penceresine bırakırsan o klasöre gider)", "Drop a file on an app in the ⌘Tab panel to open it there (drop on a Finder window to move it into that folder)"),
            ("Kapattığın özellikler için hiçbir izin istenmez; ilk kurulumda neleri kullanacağın sorulur", "Features you turn off never ask for permissions; first launch asks what you'll use"),
        ]),
    ]
}
