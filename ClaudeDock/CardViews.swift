import Cocoa

enum Typography {
    static func title() -> NSFont {
        if let desc = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            .fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: desc, size: 13.5)
                ?? NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        }
        return NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    }
    static func bucketLabel() -> NSFont {
        NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    }
    static func percent() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }
    static func countdown() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }
    static func headerTime() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }
    static func headerInterval() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    }
}

final class ProgressBarView: NSView {
    private let percent: Double?
    init(percent: Double?, width: CGFloat = 72, height: CGFloat = 7) {
        self.percent = percent
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let bg = NSBezierPath(roundedRect: bounds, xRadius: h/2, yRadius: h/2)
        Palette.mutedBar.setFill()
        bg.fill()
        guard let v = percent else { return }
        let clamped = min(100, max(0, v)) / 100
        let fillW = max(h, bounds.width * clamped)
        let fg = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: fillW, height: h),
            xRadius: h/2, yRadius: h/2
        )
        Palette.color(for: v).setFill()
        fg.fill()
    }
}

final class BucketView: NSStackView {
    init(label: String, percent: Double?, resetDate: Date?) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithAttributedString: NSAttributedString(
            string: label.uppercased(),
            attributes: [
                .font: Typography.bucketLabel(),
                .foregroundColor: Palette.bucketLabel,
                .kern: 0.6
            ]
        ))
        lbl.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(lbl)

        addArrangedSubview(ProgressBarView(percent: percent))

        let pct = NSTextField(labelWithString:
            percent.map { String(format: "%.0f%%", min(100, max(0, $0))) } ?? "—"
        )
        pct.font = Typography.percent()
        pct.textColor = Palette.color(for: percent)
        pct.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(pct)

        if let d = resetDate {
            let cd = NSTextField(labelWithString: "· " + Self.countdown(d))
            cd.font = Typography.countdown()
            cd.textColor = .tertiaryLabelColor
            addArrangedSubview(cd)
        }
    }
    required init(coder: NSCoder) { fatalError() }

    static func countdown(_ date: Date) -> String {
        let now = Date()
        if date <= now { return "reset" }
        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        let d = diff.day ?? 0, h = diff.hour ?? 0, m = diff.minute ?? 0
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

final class HeaderView: NSView {
    private weak var delegate: MenuBuilderDelegate?
    init(refreshedAt: Date, currentInterval: Int, delegate: MenuBuilderDelegate?) {
        self.delegate = delegate
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 8)

        if let logo = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [NSColor.controlAccentColor]))
            let iv = NSImageView()
            iv.image = logo.withSymbolConfiguration(cfg) ?? logo
            iv.imageScaling = .scaleNone
            stack.addArrangedSubview(iv)
        }

        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let ts = NSTextField(labelWithString: f.string(from: refreshedAt))
        ts.font = Typography.headerTime()
        ts.textColor = .secondaryLabelColor
        stack.addArrangedSubview(ts)

        let rbImg = NSImage(systemSymbolName: "arrow.clockwise",
                            accessibilityDescription: "Refresh")!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!
        let rb = NSButton(image: rbImg, target: self,
                          action: #selector(refreshClicked))
        rb.isBordered = false
        rb.bezelStyle = .inline
        rb.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(rb)

        let intervalLbl = NSTextField(labelWithString: Self.formatInterval(currentInterval))
        intervalLbl.font = Typography.headerInterval()
        intervalLbl.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(intervalLbl)

        addSubview(stack)
        let sz = stack.fittingSize
        stack.frame = NSRect(origin: .zero, size: sz)
        frame.size = sz
    }
    required init?(coder: NSCoder) { nil }

    @objc private func refreshClicked() {
        delegate?.refreshNow()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    private static func formatInterval(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}

final class AccountCardView: NSView {
    init(
        title: String,
        active: Bool,
        providerSymbol: String?,
        providerTint: NSColor?,
        errorMsg: String?,
        fiveH: (Double?, Date?)?,
        sevenD: (Double?, Date?)?
    ) {
        super.init(frame: .zero)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 9
        titleRow.alignment = .centerY

        if let sym = providerSymbol,
           let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [providerTint ?? .labelColor]))
            let iv = NSImageView()
            iv.image = img.withSymbolConfiguration(cfg) ?? img
            iv.imageScaling = .scaleNone
            titleRow.addArrangedSubview(iv)
        } else {
            let dotSym = NSImage(
                systemSymbolName: active ? "circle.fill" : "circle",
                accessibilityDescription: nil
            )!
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(paletteColors: [
                    active ? Palette.activeDot : NSColor.quaternaryLabelColor
                ]))
            let iv = NSImageView()
            iv.image = dotSym.withSymbolConfiguration(cfg) ?? dotSym
            iv.imageScaling = .scaleNone
            titleRow.addArrangedSubview(iv)
        }

        let t = NSTextField(labelWithString: title)
        t.font = Typography.title()
        t.textColor = active ? .labelColor : .secondaryLabelColor
        titleRow.addArrangedSubview(t)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        root.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 9, right: 14)

        root.addArrangedSubview(titleRow)

        if let err = errorMsg {
            let e = NSTextField(labelWithString: err)
            e.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            e.textColor = Palette.color(for: 90)
            root.addArrangedSubview(e)
        } else {
            let buckets = NSStackView()
            buckets.orientation = .vertical
            buckets.alignment = .leading
            buckets.spacing = 4
            if let (p, d) = fiveH {
                buckets.addArrangedSubview(BucketView(label: "5H", percent: p, resetDate: d))
            }
            if let (p, d) = sevenD {
                buckets.addArrangedSubview(BucketView(label: "7D", percent: p, resetDate: d))
            }
            root.addArrangedSubview(buckets)
        }

        addSubview(root)
        let sz = root.fittingSize
        root.frame = NSRect(origin: .zero, size: sz)
        frame.size = sz
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
