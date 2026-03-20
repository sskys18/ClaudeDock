import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, MenuBuilderDelegate {
    private var statusItem: NSStatusItem!
    private var usageService: UsageService!
    private var menuBuilder: MenuBuilder!
    private var refreshTimer: Timer?
    private var config: AppConfig!
    private var lastResult: FetchResult?
    private var hasTriggeredResetRefresh = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        usageService = UsageService()
        config = usageService.loadConfig()
        menuBuilder = MenuBuilder(currentInterval: config.refreshInterval)
        menuBuilder.delegate = self

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "--"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        // Set up a persistent menu with delegate for dynamic rebuilds on open
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Initial fetch
        Task { await refresh() }

        // Timer
        startTimer()

        // Sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Refresh

    private func refresh() async {
        let result = await usageService.fetchUsage()
        await MainActor.run {
            lastResult = result
            updateMenuBarTitle(result)
        }
    }

    private func updateMenuBarTitle(_ result: FetchResult) {
        guard let limits = result.limits, let fiveHour = limits.five_hour else {
            if result.error != nil {
                setMenuBarText("!", color: .systemRed)
            } else {
                setMenuBarText("--", color: .white)
            }
            return
        }

        let clamped = min(100, max(0, fiveHour.utilization))
        setMenuBarText(String(format: "%.1f%%", clamped), color: colorForPercent(clamped))

        // If resets_at is in the past, trigger one refresh (guarded to prevent loop)
        if let resetsAt = fiveHour.resets_at, !hasTriggeredResetRefresh {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: resetsAt), date <= Date() {
                hasTriggeredResetRefresh = true
                Task { await refresh() }
            }
        } else if let resetsAt = fiveHour.resets_at {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: resetsAt), date > Date() {
                hasTriggeredResetRefresh = false // Reset guard when resets_at is in the future
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild menu items just before the dropdown opens for fresh countdowns
        menu.removeAllItems()
        guard let result = lastResult else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let built = menuBuilder.buildMenu(from: result)
        // Move items from built menu to the actual menu
        while built.items.count > 0 {
            let item = built.items[0]
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    private func setMenuBarText(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func colorForPercent(_ pct: Double) -> NSColor {
        if pct > 80 { return .systemRed }
        if pct > 50 { return .systemYellow }
        return .systemGreen
    }

    // MARK: - Timer

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(config.refreshInterval),
            repeats: true
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @objc private func didWake() {
        Task { await refresh() }
    }

    // MARK: - MenuBuilderDelegate

    @objc func refreshNow() {
        Task { await refresh() }
    }

    @MainActor @objc func changeInterval(_ sender: NSMenuItem) {
        config.refreshInterval = sender.tag
        usageService.saveConfig(config)
        menuBuilder.updateInterval(sender.tag)
        startTimer()
    }
}
