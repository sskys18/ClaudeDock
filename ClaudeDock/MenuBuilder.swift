import Cocoa

@objc protocol MenuBuilderDelegate: AnyObject {
    func refreshNow()
    func changeInterval(_ sender: NSMenuItem)
}

class MenuBuilder {
    weak var delegate: MenuBuilderDelegate?
    private var currentInterval: Int

    init(currentInterval: Int) {
        self.currentInterval = currentInterval
    }

    func updateInterval(_ seconds: Int) { currentInterval = seconds }

    func buildMenu(from result: FetchResult) -> NSMenu {
        let menu = NSMenu()

        if result.accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts saved. Log in to Claude Code, then use Save below.",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for usage in result.accounts {
                let isActive = (result.activeAccountId == usage.account.id)
                menu.addItem(buildAccountRow(usage: usage, active: isActive))
            }
        }
        if let codex = result.codexMetrics {
            menu.addItem(buildCodexRow(codex: codex))
        }
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "↻ Refresh",
            action: #selector(MenuBuilderDelegate.refreshNow),
            keyEquivalent: "r")
        refresh.target = delegate
        menu.addItem(refresh)

        let autoRefresh = NSMenuItem(title: "Auto-refresh: \(formatInterval(currentInterval))",
                                     action: nil, keyEquivalent: "")
        let autoSub = NSMenu()
        for seconds in [15, 30, 60, 120, 300] {
            let subItem = NSMenuItem(title: formatInterval(seconds),
                action: #selector(MenuBuilderDelegate.changeInterval(_:)),
                keyEquivalent: "")
            subItem.target = delegate
            subItem.tag = seconds
            if seconds == currentInterval { subItem.state = .on }
            autoSub.addItem(subItem)
        }
        autoRefresh.submenu = autoSub
        menu.addItem(autoRefresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeDock",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let footer = NSMenuItem(title: footerText(result), action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)

        return menu
    }

    private func buildAccountRow(usage: AccountUsage, active: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false

        let s = NSMutableAttributedString()
        s.append(dotAttr(active: active))
        s.append(NSAttributedString(
            string: " \(usage.account.label)",
            attributes: [
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .font: active ? boldFont() : rowFont()
            ]
        ))
        s.append(plain("\t"))

        if let err = usage.error, usage.limits == nil {
            let reason: String
            switch err {
            case .noKey: reason = "no credentials"
            case .needsReLogin: reason = "re-login required"
            case .rateLimited: reason = "rate limited"
            case .apiError: reason = "api error"
            }
            s.append(NSAttributedString(
                string: reason,
                attributes: [.foregroundColor: NSColor.systemOrange, .font: rowFont()]
            ))
            item.attributedTitle = applyColumns(s)
            return item
        }

        appendBucket(into: s, label: "5H",
                     percent: usage.limits?.five_hour?.utilization,
                     resetISO: usage.limits?.five_hour?.resets_at)
        s.append(plain("\t"))
        appendBucket(into: s, label: "7D",
                     percent: usage.limits?.seven_day?.utilization,
                     resetISO: usage.limits?.seven_day?.resets_at)
        item.attributedTitle = applyColumns(s)
        return item
    }

    private func buildCodexRow(codex: CodexMetrics) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(
            string: "◆ ",
            attributes: [.foregroundColor: NSColor.systemPurple.withAlphaComponent(0.85),
                         .font: rowFont()]
        ))
        s.append(NSAttributedString(
            string: "Codex",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: rowFont()]
        ))
        s.append(plain("\t"))
        appendBucket(into: s, label: "5H",
                     percent: codex.five_hour_limit_pct,
                     resetDate: codex.five_hour_resets_at.map { Date(timeIntervalSince1970: $0) })
        s.append(plain("\t"))
        appendBucket(into: s, label: "7D",
                     percent: codex.weekly_limit_pct,
                     resetDate: codex.weekly_resets_at.map { Date(timeIntervalSince1970: $0) })
        item.attributedTitle = applyColumns(s)
        return item
    }

    private func applyColumns(_ s: NSMutableAttributedString) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [
            NSTextTab(textAlignment: .left, location: 90, options: [:]),
            NSTextTab(textAlignment: .left, location: 180, options: [:])
        ]
        para.defaultTabInterval = 90
        s.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: s.length))
        return s
    }

    private func appendBucket(into s: NSMutableAttributedString, label: String,
                              percent: Double?, resetISO: String? = nil,
                              resetDate: Date? = nil) {
        let color = colorForPercent(percent)
        s.append(NSAttributedString(
            string: sparkChar(percent) + " ",
            attributes: [.foregroundColor: color, .font: rowFont()]
        ))
        s.append(percentAttr(percent))
        let date = resetDate ?? (resetISO.flatMap { parseISO8601($0) })
        if let date {
            s.append(NSAttributedString(
                string: " " + formatCountdown(date),
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                             .font: smallFont()]
            ))
        }
    }

    private func sparkChar(_ v: Double?) -> String {
        (v == nil) ? "·" : "●"
    }

    private func colorForPercent(_ v: Double?) -> NSColor {
        guard let v else { return .tertiaryLabelColor }
        if v > 80 { return .systemRed }
        if v > 50 { return .systemYellow }
        return .systemGreen
    }

    private func formatCountdown(_ date: Date) -> String {
        let now = Date()
        if date <= now { return "reset" }
        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    private func parseISO8601(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private func dotAttr(active: Bool) -> NSAttributedString {
        NSAttributedString(
            string: active ? "●" : "○",
            attributes: [
                .foregroundColor: active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
                .font: rowFont()
            ]
        )
    }

    private func percentAttr(_ value: Double?) -> NSAttributedString {
        guard let v = value else {
            return NSAttributedString(
                string: "--",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: rowFont()]
            )
        }
        let clamped = min(100, max(0, v))
        let color: NSColor
        if clamped > 80 { color = .systemRed }
        else if clamped > 50 { color = .systemYellow }
        else { color = .systemGreen }
        return NSAttributedString(
            string: String(format: "%.0f%%", clamped),
            attributes: [.foregroundColor: color, .font: rowFont()]
        )
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.labelColor, .font: rowFont()]
        )
    }

    private func rowFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func boldFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }

    private func smallFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }

    private func footerText(_ result: FetchResult) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "Last refreshed: \(f.string(from: result.refreshedAt))"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f%%", min(100, max(0, v)))
    }

    private func formatInterval(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}
