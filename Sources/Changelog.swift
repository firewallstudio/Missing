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
        ChangelogEntry(version: "3.0.5", items: [
            ("Finder'ın arama kutusuna yazdıkça altında Missing'in anında sonuçları çıkar (↓↑ ↩ ⌘↩ Esc)",
             "Typing in Finder's search box shows Missing's instant results right below it (↓↑ ↩ ⌘↩ Esc)"),
            ("Finder sekmeleri hep yerinde: sağ tıkta ve uygulama geçişinde kaybolmaz, yeniden inmez; renk Finder'dan doğru ölçülür",
             "Finder tabs stay put: they no longer vanish on right-click or reappear when switching apps; the colour is sampled correctly from Finder"),
            ("Pencere görüntüleri ve pencere kayıtları için ayrı klasör seçimi (Ayarlar › Ekran)",
             "Choose folders for window screenshots and window recordings (Settings › Screen)"),
        ]),
        ChangelogEntry(version: "3.0.4", items: [
            ("Finder'ın sağ üstteki arama kutusu ve ⌘F de Missing aramasını açar",
             "Finder's search box and ⌘F open Missing's search too"),
            ("Aramanın önizlemesinde video kendiliğinden oynamaz; Space ile Hızlı Bakış kapanınca arama açık kalır",
             "Videos no longer autoplay in the search preview; search stays open after closing Quick Look with Space"),
            ("Sadece pencereyi çek: ekran görüntüsü ve kayıtta tek bir pencere seç (⌘⇧5 paleti)",
             "Capture just a window: pick a single window for screenshots or recordings (⌘⇧5 palette)"),
            ("Ekranı böl: düzen seçince bölmeler o ekrandaki son kullanılan pencerelerle dolsun ya da sen seç (Ayarlar › Ekran)",
             "Split screen: fill zones with that screen's most recent windows automatically, or choose them yourself (Settings › Screen)"),
            ("Finder sekmeleri: × her zaman kapatır, şerit yukarıdan kayarak gelir ve Finder'ın rengini alır",
             "Finder tabs: × always closes, the strip slides in from the top and matches Finder's colour"),
        ]),
        ChangelogEntry(version: "3.0.3", items: [
            ("Dosya arama: seçili sonuç sağda önizleniyor; fareyle üstüne gelince önizlenir, Space Finder'daki gibi Hızlı Bakış açar",
             "File search: the selected result is previewed on the right; hover to preview, Space opens Quick Look like in Finder"),
            ("Aramadan anında sil: ⌘⌫ ya da çöp düğmesi dosyayı Çöp Sepeti'ne atar, satır hemen listeden kalkar",
             "Delete right from search: ⌘⌫ or the trash button moves the file to the Trash and the row disappears at once"),
            ("Klasör jetonu büyütecin yanında, gerçek klasör ikonuyla; altta kısayol çubuğu",
             "The folder token sits next to the magnifier with the real folder icon; a shortcut bar runs along the bottom"),
            ("Finder sekmeleri Windows gibi: belli genişlikte, çoğaldıkça daralır, sığmayınca kayar (Hızlı Özellikler)",
             "Windows-style Finder tabs: a set width that shrinks as you add more and scrolls when they don't fit (Quick Features)"),
        ]),
        ChangelogEntry(version: "3.0.2", items: [
            ("Özellikler paneli artık sekmeleri açıp kapatıyor: Pencere Değiştirici, Ses, Ekran, Hızlı Özellikler. Kapalı sekme kenar çubuğundan ve menü panelinden kalkar, içindeki hiçbir şey çalışmaz",
             "The Features panel now turns whole tabs on or off: Window Switcher, Sound, Screen, Quick Features. A tab you turn off leaves the sidebar and the menu bar panel, and nothing in it runs"),
            ("Sekmeyi tekrar açınca içindeki ayarlar kaldığı gibi geri gelir; sekmenin içindeki her seçeneğin kendi düğmesi var",
             "Turn a tab back on and its settings return as they were; every option inside a tab has its own switch"),
        ]),
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
