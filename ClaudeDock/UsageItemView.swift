import Cocoa

class UsageItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressBar = NSView()
    private let progressTrack = NSView()

    private let percentage: Double
    private let semantic: PercentageSemantic

    static let viewWidth: CGFloat = 196
    static let viewHeight: CGFloat = 56

    init(title: String, percentage: Double, subtitle: String, semantic: PercentageSemantic) {
        self.percentage = min(100, max(0, percentage))
        self.semantic = semantic
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        setupViews(title: title, subtitle: subtitle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews(title: String, subtitle: String) {
        let padding: CGFloat = 16
        let barHeight: CGFloat = 6
        let barY: CGFloat = 18
        let barWidth = Self.viewWidth - padding * 2

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: padding, y: Self.viewHeight - 20, width: barWidth - 40, height: 14)
        addSubview(titleLabel)

        percentLabel.stringValue = String(format: "%.0f%%", percentage)
        percentLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = colorForPercent(percentage)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: Self.viewWidth - padding - 40, y: Self.viewHeight - 20, width: 40, height: 14)
        addSubview(percentLabel)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        progressTrack.layer?.cornerRadius = barHeight / 2
        progressTrack.frame = NSRect(x: padding, y: barY, width: barWidth, height: barHeight)
        addSubview(progressTrack)

        let fillWidth = barWidth * CGFloat(percentage / 100)
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = colorForPercent(percentage).cgColor
        progressBar.layer?.cornerRadius = barHeight / 2
        progressBar.frame = NSRect(x: padding, y: barY, width: fillWidth, height: barHeight)
        addSubview(progressBar)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.frame = NSRect(x: padding, y: 2, width: barWidth, height: 13)
        addSubview(subtitleLabel)
    }

    private func colorForPercent(_ pct: Double) -> NSColor {
        switch semantic {
        case .utilization:
            if pct > 80 { return .systemRed }
            if pct > 50 { return .systemYellow }
            return .systemGreen
        case .remaining:
            if pct < 20 { return .systemRed }
            if pct < 50 { return .systemYellow }
            return .systemGreen
        }
    }
}
