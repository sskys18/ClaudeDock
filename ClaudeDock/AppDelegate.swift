import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, MenuBuilderDelegate {
    private var statusItem: NSStatusItem!
    private var usageService: UsageService!
    private var menuBuilder: MenuBuilder!
    private var refreshTimer: Timer?
    private var config: AppConfig!
    private var lastResult: FetchResult?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        usageService = UsageService()
        config = usageService.loadConfig()
        usageService.saveConfig(config)
        menuBuilder = MenuBuilder(currentInterval: config.refreshInterval)
        menuBuilder.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let logo = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "ClaudeDock") {
            logo.isTemplate = true
            statusItem.button?.image = logo
            statusItem.button?.imagePosition = .imageLeft
            statusItem.button?.imageHugsTitle = true
        }
        statusItem.button?.title = " --"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Task { await refresh() }
        startTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func refresh() async {
        let result = await usageService.fetchUsage(config: config)
        await MainActor.run {
            lastResult = result
            updateMenuBarTitle(result)
        }
    }

    private func updateMenuBarTitle(_ result: FetchResult) {
        let activeUsage = result.accounts.first(where: { $0.account.id == result.activeAccountId })
        let fiveH: Double? = activeUsage?.limits?.five_hour.map { clamp($0.utilization) }
        let sevenD: Double? = activeUsage?.limits?.seven_day.map { clamp($0.utilization) }

        if fiveH != nil || sevenD != nil {
            setBarDual(fiveH: fiveH, sevenD: sevenD)
        } else if !result.accounts.isEmpty {
            setBar("!", color: .systemRed)
        } else {
            setBar("--", color: NSColor.secondaryLabelColor)
        }
    }

    private func setBarDual(fiveH: Double?, sevenD: Double?) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let dim = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let s = NSMutableAttributedString(string: " ")
        let hStr = fiveH.map { String(format: "%.0f", $0) } ?? "--"
        let dStr = sevenD.map { String(format: "%.0f", $0) } ?? "--"
        s.append(NSAttributedString(string: hStr, attributes: [
            .foregroundColor: Palette.color(for: fiveH),
            .font: font
        ]))
        s.append(NSAttributedString(string: " · ", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: dim
        ]))
        s.append(NSAttributedString(string: dStr, attributes: [
            .foregroundColor: Palette.color(for: sevenD),
            .font: font
        ]))
        statusItem.button?.attributedTitle = s
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let result = lastResult else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let built = menuBuilder.buildMenu(from: result)
        while built.items.count > 0 {
            let item = built.items[0]
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    private func setBar(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(
            string: " \(text)",
            attributes: attrs
        )
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(config.refreshInterval), repeats: true
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @objc private func didWake() { Task { await refresh() } }

    // MARK: - MenuBuilderDelegate

    @objc func refreshNow() {
        usageService.clearBackoffs()
        Task { await refresh() }
    }

    @objc func changeInterval(_ sender: NSMenuItem) {
        config.refreshInterval = sender.tag
        usageService.saveConfig(config)
        menuBuilder.updateInterval(sender.tag)
        startTimer()
    }

}
