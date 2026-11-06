import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Uygulama

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = DeviceStore.shared
    private let switcher = Switcher()
    private let audioKeys = AudioKeys()
    private let hud = HUDController()
    private var panel: DevicePanelController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private let extraKeys = ExtraKeys()
    private var capture: CaptureController!
    private let tiling = TilingController()
    private let zonePicker = ZonePickerController()
    private let dockDrag = DockDragAccelerator()
    private let snapBar = SnapBar()
    private let updatePopup = UpdatePopupController()
    private let onboarding = OnboardingController()
    private let menuPanel = MenuBarPanelController()
    private let finderTabs = FinderTabsController()
    private let finderSearch = FinderSearchHook()
    private var model: SettingsModel!
    private var fileSearch: FileSearchController!
    private var permTimer: Timer?
    private var guardTimer: Timer?
    private var secureActive = false
    private var lastSecureNotice = Date.distantPast
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        gSwitcher = switcher
        gAudioKeys = audioKeys
        gExtraKeys = extraKeys
        // Önceki çalışma kısayolları kapalı bırakmış olabilir (çökme, zorla kapatma): önce hepsini aç,
        // Missing kısayolları dinlemeye başlayınca yalnızca gerekenler yeniden kapanır
        setNativeHotkeys(allManagedNativeHotkeys, enabled: true)
        // Kapattığımız macOS kısayollarını (⌘Tab, ⌘⇧3/4/5…) her durumda geri aç
        signal(SIGTERM) { _ in restoreNativeHotkeys(); exit(0) }
        signal(SIGINT) { _ in restoreNativeHotkeys(); exit(0) }

        // Menü çubuğu: Missing yaprağı; tıklayınca cam panel (kapalıyken beyaz, açıkken renkli)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMenuPanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuPanel.onVisibilityChanged = { [weak self] open in
            self?.menuOpen = open
            self?.updateIcon()
        }
        store.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)
        updateIcon()

        // Ses paneli önceden kurulur → kısayolda anında açılır
        panel = DevicePanelController(store: store)

        let model = SettingsModel(store: store)
        self.model = model
        model.onOpenSetup = { [weak self] in self?.showSetup() }
        model.onPowerChanged = {
            if PowerProfiles.active { PowerProfiles.shared.start() } else { PowerProfiles.shared.stop() }
        }
        model.onFinderTabsChanged = { [weak self] in
            guard let self else { return }
            if FinderTabsSettings.enabled, self.switcher.isRunning { self.finderTabs.start() } else { self.finderTabs.stop() }
        }
        model.onNativeTabChanged = { [weak self] in self?.switcher.applyNative() }
        model.onDeepScanChanged = { [weak self] in self?.switcher.deepScopeChanged() }
        model.onDockDragChanged = { [weak self] in self?.dockDrag.start() }
        model.onHotkeyChanged = { [weak self] in self?.applyAudioKeySettings() }
        model.onPreviewsChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            if Onboarding.done, model.anyPreviews, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if !model.anyPreviews { self.switcher.clearThumbs() }
        }
        model.onShortcutsChanged = { [weak self] in self?.applyExtraNative() }
        model.onInstallUpdate = { [weak self] release in self?.installUpdate(release) }
        settings = SettingsWindowController(model: model)
        wireMenuPanel()

        // Ekran çekimi ve ekran bölme
        capture = CaptureController(hud: hud)
        capture.onRecordingChanged = { [weak self] _ in self?.updateIcon() }
        extraKeys.onScreenshot = { [weak self] in self?.capture.screenshotCurrentScreen() }
        extraKeys.onArea = { [weak self] in self?.capture.screenshotArea() }
        extraKeys.onCaptureMenu = { [weak self] in self?.capture.paletteOrStop() }
        extraKeys.onScrolling = { [weak self] in self?.capture.scrollingScreenshot() }
        extraKeys.onTile = { [weak self] in self?.tiling.trigger() }
        extraKeys.onBlackout = { [weak self] in
            guard let self else { return }
            // Tüm ekranlar (Mac'in kendi ekranı dahil); karanlıkken bildirim görünmez, açılınca kısa haber
            if !Monitors.shared.toggleBlackout() {
                self.hud.show(name: L("Ekranlar geri açıldı"), symbol: "sun.max.fill")
            }
        }
        // Harici monitör listesi (parlaklık / ses için)
        Monitors.shared.refresh(rescan: true)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Monitors.shared.refresh(rescan: true) }
        }
        // ⌘Space dosya arama (indeks arka planda hazırlanır)
        fileSearch = FileSearchController()
        extraKeys.onFileSearch = { [weak self] in self?.fileSearch.toggle() }
        gFinderSearch = finderSearch
        model.onFileSearchChanged = { [weak self] in
            if FileSearchSettings.enabled {
                if self?.switcher.isRunning == true { self?.finderSearch.start() }
            } else { self?.finderSearch.stop() }
            if FileSearchSettings.enabled { FileIndex.shared.start() } else {
                self?.fileSearch.close(restore: true)
                FileIndex.shared.stop()
            }
            self?.applyExtraNative()
        }
        extraKeys.isBlocked = { [weak self] in self?.switcher.isActive ?? false }
        tiling.itemsProvider = { [weak self] in self?.switcher.snapshotItems() ?? [] }
        switcher.onTileItem = { [weak self] item in self?.zonePicker.show(item) }

        // GitHub'dan güncelleme
        Updater.shared.onAvailable = { [weak self] info in
            self?.hud.show(name: L("Missing %@ hazır · menüden yükle", info.version), symbol: "arrow.down.circle.fill")
            UpdateNotifier.post(version: info.version)   // Bildirim Merkezi'ne de düşsün
        }
        updatePopup.onInstall = { [weak self] in self?.installUpdate() }
        UNUserNotificationCenter.current().delegate = self
        Updater.shared.start()

        // Ses kısayolu (pencere değiştiricinin tap'ini paylaşır)
        applyAudioKeySettings()
        audioKeys.onTrigger = { [weak self] in self?.audioHotkey() }
        audioKeys.onCommandReleased = { [weak self] in
            guard let self, self.store.mode == .panel, self.store.selectOnRelease else { return }
            self.panel.commitHighlighted()
        }
        audioKeys.isBlocked = { [weak self] in self?.switcher.isActive ?? false }

        // ⌘Tab kartlarında uygulamanın ses cihazı rozeti + panelde S ile atama
        switcher.audioFor = { [weak self] app in
            guard let dev = self?.store.device(forApp: app.bundleIdentifier) else { return nil }
            return (dev.symbol, dev.name)
        }
        switcher.onCycleAudio = { [weak self] app in
            guard let bid = app.bundleIdentifier else { NSSound.beep(); return }
            self?.store.cycleAppDevice(bundleID: bid)
        }

        // Uygulama öne gelince atanmış ses cihazına geç
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.switcher.isRunning, !self.secureActive { self.extraKeys.applySpotlight() }
                guard let dev = self.store.applyAppDevice(bundleID: bid) else { return }
                if self.store.showHUD { self.hud.show(name: dev.name, symbol: dev.symbol) }
            }
        }

        startGuard()
        // İlk açılış: önce neleri kullanacağını sor, izinleri ancak ondan sonra iste
        if Onboarding.done { startFeatures() } else { showSetup() }
    }

    /// Kurulum ekranı (ilk açılışta ve Ayarlar › Genel'den)
    private func showSetup() {
        settings.close()
        onboarding.show { [weak self] in self?.finishSetup() }
    }

    private func finishSetup() {
        let first = !Onboarding.done
        Onboarding.done = true
        applyFeatureSettings()
        model.refresh()
        if first || !switcher.isRunning { startFeatures() }
    }

    /// Kurulumda değişen açık/kapalı ayarlarını çalışan parçalara uygula
    private func applyFeatureSettings() {
        applyAudioKeySettings()
        if switcher.isRunning { switcher.applyNative() }
        applyExtraNative()
        dockDrag.start()
        model.onFinderTabsChanged()
        if !model.anyPreviews { switcher.clearThumbs() }
        if FileSearchSettings.enabled { FileIndex.shared.start() } else {
            fileSearch.close(restore: true)
            FileIndex.shared.stop()
        }
    }

    /// İzinleri yalnızca açık özellikler gerektiriyorsa iste, sonra dinleyicileri başlat
    private func startFeatures() {
        if FileSearchSettings.enabled { FileIndex.shared.start() }
        PowerProfiles.shared.start()   // sadece MacBook Pro 14" M4 Pro'da bir şey yapar
        if model.anyPreviews, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        let trusted: Bool
        if Onboarding.needsAccessibility {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
        } else {
            trusted = AXIsProcessTrusted()
        }
        if trusted {
            startInput()
        } else if permTimer == nil {
            // Sadece izin verilene kadar çalışır, sonra kendini kapatır.
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.permTimer?.invalidate(); self.permTimer = nil
                    self.startInput()
                }
            }
        }
    }

    private func startInput() {
        if FinderTabsSettings.enabled { finderTabs.start() }
        if FileSearchSettings.enabled { finderSearch.start() }
        switcher.start()
        applyExtraNative()
        dockDrag.start()
        snapBar.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Kayıt sürüyorsa önce dosyayı düzgünce kapat
        guard capture?.isRecording == true else { return .terminateNow }
        capture.stopRecording { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.stop()
        restoreNativeHotkeys()
        FileIndex.shared.stop()
    }

    /// macOS'un ⌘⇧3/4/5/6 ve ⌘< kısayollarını ayarlara göre kapat/aç (sadece kısayol dinleyicisi çalışıyorsa)
    private func applyExtraNative() {
        guard switcher.isRunning, !secureActive else { return }
        extraKeys.applyNative()
    }

    /// Hafif bekçi (1,5 sn): güvenli giriş kilidi, kapanmış olay dinleyicisi, sonradan verilen izin
    private func startGuard() {
        guardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardTick() }
        }
        guardTimer?.tolerance = 0.5
    }

    private func guardTick() {
        // İzin var ama dinleyici kurulamamışsa yeniden dene
        if Onboarding.done, !switcher.isRunning, permTimer == nil, AXIsProcessTrusted() {
            switcher.start()
            applyExtraNative()
        }
        guard switcher.isRunning else { return }
        let on = SecureInput.isOn
        guard on != secureActive else { return }
        secureActive = on
        if on {
            // Tuşlar bize ulaşamıyor: macOS'un kendi ⌘Tab'ı ve ekran görüntüsü kısayolları geçici olarak geri
            setNativeHotkeys(allManagedNativeHotkeys, enabled: true)
            Switcher.nativeCmdTabOn = true
            extraKeys.forgetNativeState()
            guard Date().timeIntervalSince(lastSecureNotice) > 600 else { return }   // en fazla 10 dakikada bir haber ver
            lastSecureNotice = Date()
            let who = SecureInput.ownerName()
            hud.show(name: who.map { L("%@ klavyeyi kilitledi · ⌘Tab şimdilik macOS'unki", $0) }
                          ?? L("Güvenli giriş açık · ⌘Tab şimdilik macOS'unki"), symbol: "lock.fill")
        } else {
            Switcher.nativeCmdTabOn = false
            switcher.applyNative()
            applyExtraNative()
        }
    }

    // MARK: Ses

    private func applyAudioKeySettings() {
        audioKeys.choice = store.hotkeyChoice
        audioKeys.enabled = store.hotkeyEnabled
        audioKeys.restoreCapsLock = store.keepCapsLock
    }

    private func audioHotkey() {
        switch store.mode {
        case .cycle:
            guard let next = store.nextDevice() else {
                // Seçilenlerden tek cihaz takılı: geçiş yok, sadece hangisinde olduğunu göster
                if store.showHUD { showDeviceHUD() }
                return
            }
            store.switchTo(uid: next.uid)
            if store.showHUD { showDeviceHUD() }
        case .panel:
            panel.showOrAdvance()
        }
    }

    /// Alttaki bildirim: geçilen cihaz büyük, altında döngüdeki tüm cihazlar ve sıradaki
    private func showDeviceHUD() {
        let s = store.cycleState()
        guard let cur = s.current else { return }
        let list = s.devices.map { HUDDevice(name: $0.name, symbol: $0.symbol) }
        hud.show(name: s.devices[cur].name, symbol: s.devices[cur].symbol,
                 devices: list.count > 1 ? list : [], current: cur, next: s.next)
    }

    private func updateIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = store.current?.symbol ?? "speaker.wave.2"
        if capture?.isRecording == true {
            let rec = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L("Kaydediliyor"))?
                .withSymbolConfiguration(config)
            rec?.isTemplate = true
            statusItem.button?.image = rec
            statusItem.button?.contentTintColor = .systemRed
            statusItem.button?.toolTip = L("Missing · Kaydediliyor")
            return
        }
        statusItem.button?.contentTintColor = nil
        // Missing ikonu: normalde menü çubuğu renginde (beyaz/siyah), menü açıkken renkli
        let image: NSImage?
        if menuOpen, let color = NSImage(named: "MenuIconColor") {
            color.size = NSSize(width: 18, height: 18)
            color.isTemplate = false
            image = color
        } else if let tpl = NSImage(named: "MenuIconTemplate") {
            tpl.size = NSSize(width: 18, height: 18)
            tpl.isTemplate = true
            image = tpl
        } else {
            image = (NSImage(systemSymbolName: symbol, accessibilityDescription: "Missing")
                     ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Missing"))?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
        }
        statusItem.button?.image = image
        statusItem.button?.toolTip = store.current.map { "Missing · \($0.name)" } ?? "Missing"
    }

    private var menuOpen = false

    @objc private func toggleMenuPanel() {
        menuPanel.toggle(below: statusItem.button)
    }

    /// Panelin eylemleri
    private func wireMenuPanel() {
        let a = menuPanel.actions
        a.tile = { [weak self] in self?.tiling.trigger() }
        a.capture = { [weak self] act in self?.capture.perform(act) }
        a.stopRecording = { [weak self] in self?.capture.stopRecording() }
        a.blackout = { [weak self] in self?.extraKeys.onBlackout?() }
        a.openSettings = { [weak self] page in self?.settings.show(page: page) }
        a.checkUpdates = { [weak self] in self?.showUpdatePopup(check: true) }
        a.installUpdate = { [weak self] in self?.installUpdate() }
        a.quit = { NSApp.terminate(nil) }
        a.isRecording = { [weak self] in self?.capture.isRecording ?? false }
    }

    private func showUpdatePopup(check: Bool) {
        updatePopup.show(below: statusItem.button?.window?.frame, check: check)
    }

    // Bildirime tıklanınca güncelleme penceresi açılsın; uygulama öndeyken de bildirim görünsün
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showUpdatePopup(check: false) } }
        completionHandler()
    }

    /// Kayıt sürüyorsa önce dosyayı bitir, sonra güncelle ve yeniden aç
    private func installUpdate(_ release: ReleaseInfo? = nil) {
        Updater.shared.install(release: release) { [weak self] relaunch in
            MainActor.assumeIsolated {
                guard let self, self.capture.isRecording else { relaunch(); return }
                self.capture.stopRecording { relaunch() }
            }
        }
    }

}

@main enum MissingMain {
    @MainActor static func main() {
        Onboarding.prepare()   // eski kurulumlarda ilk kurulum ekranı çıkmasın
        Migration.run()   // eski GlassTab/AudioHop ayarlarını taşı (DeviceStore'dan önce)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
