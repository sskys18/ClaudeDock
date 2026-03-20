import Cocoa

class UsageItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let progressBar = NSView()
    private let progressTrack = NSView()

    private var utilization: Double = 0

    static let viewWidth: CGFloat = 220
    static let viewHeight: CGFloat = 56

    init(title: String, utilization: Double, resetText: String) {
        self.utilization = min(100, max(0, utilization))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        setupViews(title: title, resetText: resetText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews(title: String, resetText: String) {
        let padding: CGFloat = 16
        let barHeight: CGFloat = 6
        let barY: CGFloat = 18
        let barWidth = Self.viewWidth - padding * 2

        // Title
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: padding, y: Self.viewHeight - 20, width: barWidth - 40, height: 14)
        addSubview(titleLabel)

        // Percentage
        percentLabel.stringValue = String(format: "%.0f%%", utilization)
        percentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = colorForPercent(utilization)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: Self.viewWidth - padding - 40, y: Self.viewHeight - 20, width: 40, height: 14)
        addSubview(percentLabel)

        // Track (background)
        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        progressTrack.layer?.cornerRadius = barHeight / 2
        progressTrack.frame = NSRect(x: padding, y: barY, width: barWidth, height: barHeight)
        addSubview(progressTrack)

        // Fill
        let fillWidth = barWidth * CGFloat(utilization / 100)
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = colorForPercent(utilization).cgColor
        progressBar.layer?.cornerRadius = barHeight / 2
        progressBar.frame = NSRect(x: padding, y: barY, width: fillWidth, height: barHeight)
        addSubview(progressBar)

        // Reset text
        resetLabel.stringValue = resetText
        resetLabel.font = .systemFont(ofSize: 10)
        resetLabel.textColor = .tertiaryLabelColor
        resetLabel.frame = NSRect(x: padding, y: 2, width: barWidth, height: 13)
        addSubview(resetLabel)
    }

    private func colorForPercent(_ pct: Double) -> NSColor {
        if pct > 80 { return .systemRed }
        if pct > 50 { return .systemYellow }
        return .systemGreen
    }
}
