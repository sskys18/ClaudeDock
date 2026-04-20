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
        statusItem.button?.title = "--"
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
        let claude: Double? = activeUsage?.limits?.five_hour.map { clamp($0.utilization) }
        let codex: Double? = result.codexMetrics?.five_hour_limit_pct.map { clamp($0) }

        if claude != nil || codex != nil {
            let c = claude.map { String(format: "%.0f%%", $0) } ?? "--"
            let x = codex.map { String(format: "%.0f%%", $0) } ?? "--"
            let usage = max(claude ?? 0, codex ?? 0)
            setBar("\(c) | \(x)", color: colorFor(usage))
        } else if !result.accounts.isEmpty {
            setBar("!", color: .systemRed)
        } else {
            setBar("--", color: .white)
        }
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
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func colorFor(_ pct: Double) -> NSColor {
        if pct > 80 { return .systemRed }
        if pct > 50 { return .systemYellow }
        return .systemGreen
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

    @objc func refreshNow() { Task { await refresh() } }

    @objc func changeInterval(_ sender: NSMenuItem) {
        config.refreshInterval = sender.tag
        usageService.saveConfig(config)
        menuBuilder.updateInterval(sender.tag)
        startTimer()
    }

    @objc func saveCurrentAs() {
        let alert = NSAlert()
        alert.messageText = "Save current Claude login as…"
        alert.informativeText = "Enter a label (e.g. Work, Personal)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = "Label"
        alert.accessoryView = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        do {
            try AccountSwitcher.saveCurrentAs(label: label, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Could not save login.")
        }
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try AccountSwitcher.switchTo(accountId: id, config: &config)
            usageService.saveConfig(config)
            notifyRestartNeeded()
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Switch failed.")
        }
    }

    @objc func renameAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ref = config.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(ref.label)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = ref.label
        alert.accessoryView = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newLabel = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AccountSwitcher.rename(accountId: id, to: newLabel, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Rename failed.")
        }
    }

    @objc func deleteAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ref = config.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete saved login \(ref.label)?"
        alert.informativeText = "This removes ClaudeDock's stored credentials for this account. Claude Code's current login is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AccountSwitcher.delete(accountId: id, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Delete failed.")
        }
    }

    private func notifyRestartNeeded() {
        let alert = NSAlert()
        alert.messageText = "Active login switched"
        alert.informativeText = "Restart any running `claude` CLI to pick up the new identity."
        alert.runModal()
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = detail
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
