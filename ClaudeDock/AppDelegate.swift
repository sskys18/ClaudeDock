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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "--"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Task { await refresh() }
        startTimer()

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
        let claudeUsed = result.claudeLimits?.five_hour.map { clamp($0.utilization) }
        let codexUsed = result.codexMetrics?.five_hour_limit_pct.map(clamp)

        if claudeUsed != nil || codexUsed != nil {
            let claudeText = claudeUsed.map { String(format: "%.0f%%", $0) } ?? "--"
            let codexText = codexUsed.map { String(format: "%.0f%%", $0) } ?? "--"
            let usage = max(claudeUsed ?? 0, codexUsed ?? 0)
            setMenuBarText("\(claudeText) | \(codexText)", color: colorForUsage(usage))
        } else if result.error != nil {
            setMenuBarText("!", color: .systemRed)
        } else {
            setMenuBarText("--", color: .white)
        }

        guard let fiveHour = result.claudeLimits?.five_hour else {
            return
        }

        if let resetsAt = fiveHour.resets_at, !hasTriggeredResetRefresh {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: resetsAt), date <= Date() {
                hasTriggeredResetRefresh = true
                Task { await refresh() }
            }
        } else if let resetsAt = fiveHour.resets_at {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: resetsAt), date > Date() {
                hasTriggeredResetRefresh = false
            }
        }
    }

    // MARK: - NSMenuDelegate

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

    private func setMenuBarText(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func colorForUsage(_ pct: Double) -> NSColor {
        if pct > 80 { return .systemRed }
        if pct > 50 { return .systemYellow }
        return .systemGreen
    }

    private func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
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

    @objc func changeInterval(_ sender: NSMenuItem) {
        config.refreshInterval = sender.tag
        usageService.saveConfig(config)
        menuBuilder.updateInterval(sender.tag)
        startTimer()
    }
}
