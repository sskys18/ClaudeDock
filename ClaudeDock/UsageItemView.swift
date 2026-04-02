import Cocoa

class UsageSummaryView: NSView {
    struct MetricCell {
        let value: String
        let subtitle: String
        let color: NSColor
    }

    struct Row {
        let label: String
        let claude: MetricCell
        let codex: MetricCell
    }

    static let viewWidth: CGFloat = 252
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 40
    static let footerHeight: CGFloat = 22
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 10

    private let rows: [Row]
    private let footerText: String

    init(rows: [Row], footerText: String) {
        self.rows = rows
        self.footerText = footerText
        let height = Self.topPadding + Self.headerHeight + CGFloat(rows.count) * Self.rowHeight + Self.footerHeight + Self.bottomPadding
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: height))
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8

        let labelX: CGFloat = 16
        let labelWidth: CGFloat = 68
        let columnWidth: CGFloat = 72
        let claudeX = labelX + labelWidth
        let codexX = claudeX + columnWidth
        let headerY = bounds.height - Self.topPadding - 16

        addText("", x: labelX, y: headerY, width: labelWidth, bold: true, color: .secondaryLabelColor)
        addText("Claude", x: claudeX, y: headerY, width: columnWidth, bold: true, color: .secondaryLabelColor, align: .right)
        addText("Codex", x: codexX, y: headerY, width: columnWidth, bold: true, color: .secondaryLabelColor, align: .right)

        addDivider(y: bounds.height - Self.topPadding - Self.headerHeight)

        for (index, row) in rows.enumerated() {
            let rowTop = bounds.height - Self.topPadding - Self.headerHeight - CGFloat(index) * Self.rowHeight
            let valueY = rowTop - 20
            let subtitleY = rowTop - 35

            addText(row.label, x: labelX, y: valueY, width: labelWidth, bold: true)
            addText(row.claude.value, x: claudeX, y: valueY, width: columnWidth, bold: true, color: row.claude.color, align: .right)
            addText(row.codex.value, x: codexX, y: valueY, width: columnWidth, bold: true, color: row.codex.color, align: .right)

            addText(row.claude.subtitle, x: claudeX, y: subtitleY, width: columnWidth, size: 9, color: .tertiaryLabelColor, align: .right)
            addText(row.codex.subtitle, x: codexX, y: subtitleY, width: columnWidth, size: 9, color: .tertiaryLabelColor, align: .right)

            if index < rows.count - 1 {
                addDivider(y: rowTop - Self.rowHeight + 3)
            }
        }

        addDivider(y: Self.footerHeight + Self.bottomPadding)
        addText(footerText, x: 16, y: 8, width: bounds.width - 32, size: 11, color: .tertiaryLabelColor)
    }

    private func addDivider(y: CGFloat) {
        let divider = NSView(frame: NSRect(x: 12, y: y, width: bounds.width - 24, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        addSubview(divider)
    }

    private func addText(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        bold: Bool = false,
        size: CGFloat = 12,
        color: NSColor = .labelColor,
        align: NSTextAlignment = .left
    ) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        label.textColor = color
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: x, y: y, width: width, height: max(14, size + 3))
        addSubview(label)
    }
}
