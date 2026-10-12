import AppKit
import ServiceManagement

// Design tokens: native macOS system colours.
enum UI {
    static let ink = NSColor.labelColor
    static let muted = NSColor.secondaryLabelColor
    static let line = NSColor.separatorColor
    static let lineStrong = NSColor.tertiaryLabelColor
    // macOS 27 media controls are monochrome: label-coloured text on soft neutral capsules.
    static let accent = NSColor.labelColor
    static let accentPressed = NSColor.secondaryLabelColor
    static let fill = NSColor.labelColor.withAlphaComponent(0.10)
    static let fillHover = NSColor.labelColor.withAlphaComponent(0.16)
    static let fillPressed = NSColor.labelColor.withAlphaComponent(0.22)
    static let accentTint = NSColor.labelColor.withAlphaComponent(0.08)
    static let onAccent = NSColor.labelColor
    static let s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let motionIn: TimeInterval = 0.18
    static let motionOut: TimeInterval = 0.16
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
}

func clock(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// Monochrome capsule controls: text action, filled primary, toggle, or round outlined CTA.
// Hover and press states fade on the layer instead of switching.
final class ActionButton: NSView {
    enum Style { case text, filled, toggle, outlined }
    var title: String { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selected = false { didSet { needsDisplay = true; refresh() } }
    var label: String?
    var widestTitle: String?  // reserve this width so title changes never shift the row
    let style: Style
    let size: CGFloat
    var onPress: () -> Void
    var hovered = false { didSet { refresh() } }
    private var pressed = false { didSet { refresh(fast: true) } }

    init(_ title: String, style: Style = .text, size: CGFloat = 14, label: String? = nil, onPress: @escaping () -> Void = {}) {
        self.title = title; self.style = style; self.size = size; self.label = label; self.onPress = onPress
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(style == .toggle ? .checkBox : .button)
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var attrs: [NSAttributedString.Key: Any] {
        let color: NSColor = pressed ? UI.accentPressed : style == .toggle && !selected ? UI.muted : UI.accent
        return [.font: UI.font(size, style == .outlined ? .medium : .semibold), .foregroundColor: color]
    }
    private var pad: CGFloat { style == .filled ? 14 : 10 }
    override var intrinsicContentSize: NSSize {
        let w = max((title as NSString).size(withAttributes: attrs).width,
                    ((widestTitle ?? "") as NSString).size(withAttributes: attrs).width)
        if style == .outlined { return NSSize(width: max(32, ceil(w) + 16), height: 32) }
        return NSSize(width: ceil(w) + pad * 2, height: 32)
    }
    override func accessibilityLabel() -> String? { label ?? title }
    override func accessibilityValue() -> Any? { style == .toggle ? (selected ? 1 : 0) : nil }
    override func accessibilityPerformPress() -> Bool { if enabled { onPress() }; return true }
    private var enabled = true
    func isEnabled(_ on: Bool) { enabled = on; setAccessibilityEnabled(on) }
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var background: NSColor {
        switch style {
        case .filled, .outlined: return pressed ? UI.fillPressed : hovered ? UI.fillHover : UI.fill
        case .toggle: return pressed ? UI.fillPressed : selected ? (hovered ? UI.fillHover : UI.fill) : hovered ? UI.accentTint : .clear
        case .text: return pressed ? UI.fill : hovered ? UI.accentTint : .clear
        }
    }

    private func refresh(animated: Bool = true, fast: Bool = false) {
        guard let layer else { return }
        var cg: CGColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = self.background.cgColor }
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        if animated && !UI.reduceMotion {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            anim.toValue = cg
            anim.duration = fast ? 0.08 : 0.16
            anim.timingFunction = UI.ease
            layer.add(anim, forKey: "bg")
        }
        layer.backgroundColor = cg
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { refresh(animated: false) }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }

    override func draw(_ dirty: NSRect) {
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with e: NSEvent) { pressed = true }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressed = false
        if inside { onPress() }
    }
}

// Track position: 2px hairline track, accent progress, knob on hover or drag.
final class Scrubber: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var position: Double = 0 { didSet { if !dragging { needsDisplay = true } } }
    var onScrub: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    private(set) var dragging = false
    private var dragValue: Double = 0
    var hovered = false { didSet { fadeKnob() } }
    private var knob: CGFloat = 0
    private var knobTimer: Timer?

    // Knob opacity eases toward its target at display rate.
    private func fadeKnob() {
        knobTimer?.invalidate()
        let target: CGFloat = hovered || dragging ? 1 : 0
        if UI.reduceMotion { knob = target; needsDisplay = true; return }
        let start = knob, began = Date()
        knobTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(Date().timeIntervalSince(began) / 0.16, 1)
            let e = 1 - pow(1 - p, 3)
            self.knob = start + (target - start) * CGFloat(e)
            self.needsDisplay = true
            if p >= 1 { t.invalidate() }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var shown: Double { dragging ? dragValue : position }
    private var fraction: CGFloat { duration > 0 ? CGFloat(min(max(shown / duration, 0), 1)) : 0 }

    override func draw(_ dirty: NSRect) {
        let r: CGFloat = 5
        let track = NSRect(x: r, y: bounds.midY - 1, width: bounds.width - r * 2, height: 2)
        UI.line.setFill(); NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        let done = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: 2)
        UI.muted.setFill(); NSBezierPath(roundedRect: done, xRadius: 1, yRadius: 1).fill()
        if knob > 0 {
            let x = track.minX + track.width * fraction
            let k = r * (0.6 + 0.4 * knob)
            UI.accent.withAlphaComponent(knob).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - k, y: bounds.midY - k, width: k * 2, height: k * 2)).fill()
        }
    }
    private func value(_ e: NSEvent) -> Double {
        let x = convert(e.locationInWindow, from: nil).x
        return Double(min(max((x - 5) / (bounds.width - 10), 0), 1)) * duration
    }
    override func mouseDown(with e: NSEvent) { guard duration > 0 else { return }; dragging = true; dragValue = value(e); onScrub?(dragValue); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { guard dragging else { return }; dragValue = value(e); onScrub?(dragValue); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard dragging else { return }
        dragValue = value(e); dragging = false; position = dragValue
        onSeek?(dragValue); fadeKnob()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Track position" }
    override func accessibilityValue() -> Any? { clock(shown) }
    override func accessibilityPerformIncrement() -> Bool { onSeek?(min(position + 10, duration)); return true }
    override func accessibilityPerformDecrement() -> Bool { onSeek?(max(position - 10, 0)); return true }
}

// Top-right library spot. Fixed size, both states overlaid: switching never moves anything.
final class LibrarySpot: NSView {
    let add: ActionButton
    let done = NSTextField(labelWithString: "In Library")
    private(set) var saved = false

    init(add: ActionButton) {
        self.add = add
        super.init(frame: .zero)
        wantsLayer = true
        done.font = UI.font(11, .medium); done.textColor = UI.muted
        done.wantsLayer = true
        done.alphaValue = 0
        add.wantsLayer = true
        for v in [add, done] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 72), heightAnchor.constraint(equalToConstant: 32),
            add.trailingAnchor.constraint(equalTo: trailingAnchor), add.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor), done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(saved: Bool, animated: Bool) {
        guard saved != self.saved || !animated else { return }
        self.saved = saved
        add.isEnabled(!saved)
        let reduce = UI.reduceMotion || !animated
        let (out, into): (NSView, NSView) = saved ? (add, done) : (done, add)
        if reduce { out.alphaValue = 0; into.alphaValue = 1; return }
        // One leaves, then the other arrives: never both on screen at once.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = UI.ease
            out.animator().alphaValue = 0
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = UI.ease
                into.animator().alphaValue = 1
            }
            guard let layer = into.layer else { return }
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -4; rise.toValue = 0
            rise.duration = 0.22; rise.timingFunction = UI.ease
            layer.add(rise, forKey: "rise")
        })
    }
}

final class Hairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirty: NSRect) { UI.line.setFill(); bounds.fill() }
}

final class PanelView: NSView {
    var onHover: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        UI.line.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

// Hover target on the status item button.
final class HoverTracker: NSResponder {
    var onHover: ((Bool) -> Void)?
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
}

struct Track {
    var source: String?
    var artist = "", title = ""
    var playing = false
    var position = 0.0, duration = 0.0
    var at = Date()
    var shuffle = 0, repeatMode = 0
    var now: Double { min(position + (playing ? Date().timeIntervalSince(at) : 0), duration > 0 ? duration : .infinity) }
    var isMusic: Bool { source != "com.apple.podcasts" }
}

final class NowPlayingPanel {
    let panel: NSPanel
    let root = PanelView()
    let artView = NSImageView()
    let artistLabel = NSTextField(wrappingLabelWithString: "")
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let sourceLabel = NSTextField(labelWithString: "")
    let elapsedLabel = NSTextField(labelWithString: "0:00")
    let durationLabel = NSTextField(labelWithString: "0:00")
    let scrubber = Scrubber()
    let addButton = ActionButton("+", style: .outlined, size: 20, label: "Add to Library")
    var library: LibrarySpot!
    let shuffleButton = ActionButton("Shuffle", style: .toggle)
    let repeatButton = ActionButton("Repeat", style: .toggle)
    let playButton = ActionButton("Pause", style: .filled)
    let previousButton = ActionButton("Previous")
    let nextButton = ActionButton("Next")
    let optionsButton = ActionButton("Options")
    var shown = false
    var restingFrame = NSRect.zero
    var ticker: Timer?
    var track = Track()
    weak var anchor: NSStatusBarButton?
    var extraDrop: CGFloat = 0  // demo recordings sit lower for an even margin

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The frosted popover material macOS uses, clipped to a 10pt radius.
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill(); return true
        }
        blur.maskImage?.capInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        blur.maskImage?.resizingMode = .stretch
        panel.contentView = blur
        root.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: blur.leadingAnchor), root.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            root.topAnchor.constraint(equalTo: blur.topAnchor), root.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        artView.wantsLayer = true
        artView.layer?.cornerRadius = 4
        artView.layer?.masksToBounds = true
        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([artView.widthAnchor.constraint(equalToConstant: 64), artView.heightAnchor.constraint(equalToConstant: 64)])

        artistLabel.font = UI.font(14, .semibold); artistLabel.textColor = UI.ink
        titleLabel.font = UI.font(13); titleLabel.textColor = UI.ink
        sourceLabel.font = UI.font(11); sourceLabel.textColor = UI.muted
        for l in [elapsedLabel, durationLabel] { l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); l.textColor = UI.muted }
        for l in [artistLabel, titleLabel] { l.preferredMaxLayoutWidth = 320; l.isSelectable = false }

        let text = NSStackView(views: [artistLabel, titleLabel, sourceLabel])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setCustomSpacing(UI.s2, after: titleLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        library = LibrarySpot(add: addButton)
        let top = NSStackView(views: [artView, text, spacer, library])
        top.orientation = .horizontal; top.alignment = .top; top.spacing = UI.s3

        let timeSpacer = NSView()
        timeSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let times = NSStackView(views: [elapsedLabel, timeSpacer, durationLabel])
        times.orientation = .horizontal
        let timeline = NSStackView(views: [scrubber, times])
        timeline.orientation = .vertical; timeline.spacing = 2

        let controls = NSStackView(views: [shuffleButton, previousButton, playButton, nextButton, repeatButton, optionsButton])
        controls.orientation = .horizontal; controls.spacing = 2; controls.alignment = .centerY
        controls.setCustomSpacing(UI.s2, after: repeatButton)

        let rule = Hairline()
        let row = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: -10),
            controls.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 10),
            controls.topAnchor.constraint(equalTo: row.topAnchor), controls.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        let stack = NSStackView(views: [top, timeline, rule, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = UI.s3
        stack.setCustomSpacing(UI.s4, after: top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: UI.s4),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -UI.s4),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: UI.s4),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -UI.s2),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            times.widthAnchor.constraint(equalTo: timeline.widthAnchor),
            scrubber.widthAnchor.constraint(equalTo: timeline.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scrubber.onScrub = { [weak self] t in self?.elapsedLabel.stringValue = clock(t) }
        playButton.widestTitle = "Pause"
        repeatButton.widestTitle = "Repeat One"
        addButton.toolTip = "Add to Library"
    }

    func update(_ t: Track, art: NSImage?, saved: Bool?) {
        let newSong = t.title != track.title || t.artist != track.artist
        if newSong && shown && !UI.reduceMotion {
            for v in [artView, artistLabel, titleLabel, sourceLabel] as [NSView] {
                v.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade; fade.duration = 0.22; fade.timingFunction = UI.ease
                v.layer?.add(fade, forKey: "song")
            }
        }
        track = t
        artistLabel.stringValue = t.artist.isEmpty ? t.title : t.artist
        titleLabel.stringValue = t.title
        titleLabel.isHidden = t.artist.isEmpty
        sourceLabel.stringValue = t.isMusic ? "Music" : "Podcasts"
        artView.image = art
        artView.isHidden = art == nil
        playButton.title = t.playing ? "Pause" : "Play"
        shuffleButton.selected = t.shuffle > 1
        shuffleButton.isHidden = !t.isMusic
        repeatButton.selected = t.repeatMode > 1
        repeatButton.title = t.repeatMode == 2 ? "Repeat One" : "Repeat"
        repeatButton.isHidden = !t.isMusic
        setSaved(saved)
        scrubber.duration = t.duration
        durationLabel.stringValue = clock(t.duration)
        tick()
        if shown { reposition() }
    }

    func setSaved(_ saved: Bool?, animated: Bool = false) {
        library.isHidden = !track.isMusic
        library.set(saved: saved == true, animated: animated && shown)
    }

    func tick() {
        guard !scrubber.dragging else { return }
        scrubber.position = track.now
        elapsedLabel.stringValue = clock(track.now)
    }

    // Under the hovered menu-bar item, flush left with it, on the display the pointer is on.
    private func frame(for button: NSStatusBarButton) -> NSRect? {
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        guard let bw = button.window else { return nil }
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let home = bw.screen ?? NSScreen.main!
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? home
        let fromRight = home.frame.maxX - b.minX  // menu-bar items sit a fixed distance from the right edge
        var x = screen.frame.maxX - fromRight
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let top = screen.visibleFrame.maxY
        return NSRect(x: x, y: top - 6 - extraDrop - size.height, width: size.width, height: size.height)
    }

    private func reposition() {
        guard let b = anchor, let f = frame(for: b) else { return }
        let next = NSRect(x: restingFrame.minX, y: f.minY, width: f.width, height: f.height)
        guard next != restingFrame else { return }
        restingFrame = next
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = UI.reduceMotion ? 0 : 0.22
            ctx.timingFunction = UI.ease
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(next, display: true)
        }
    }

    func show(under button: NSStatusBarButton) {
        anchor = button
        guard let f = frame(for: button) else { return }
        restingFrame = f
        tick()
        let reduce = UI.reduceMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(f.offsetBy(dx: 0, dy: reduce ? 0 : -6), display: true)
            panel.orderFrontRegardless()
        }
        shown = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : UI.motionIn
            ctx.timingFunction = UI.ease
            panel.animator().alphaValue = 1
            panel.animator().setFrame(f, display: true)
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        let reduce = UI.reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : UI.motionOut
            ctx.timingFunction = UI.ease
            panel.animator().alphaValue = 0
            panel.animator().setFrame(restingFrame.offsetBy(dx: 0, dy: reduce ? 0 : -4), display: true)
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
            self.ticker?.invalidate()
        })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var helper: Process?
    var helperIn: FileHandle?
    var buffer = Data()
    var quitting = false
    var track = Track()
    var hasTrack = false
    var art: NSImage?
    var fullArt: NSImage?
    var saved: Bool?
    let panel = NowPlayingPanel()
    let tracker = HoverTracker()
    var overButton = false, overPanel = false, menuOpen = false
    var hoverTimer: Timer?
    let scripts = DispatchQueue(label: "nowmusicbar.music")

    func applicationDidFinishLaunching(_ note: Notification) {
        if UserDefaults.standard.object(forKey: "openAtLogin") == nil {
            UserDefaults.standard.set(true, forKey: "openAtLogin")
            try? SMAppService.mainApp.register()
        }
        item.button?.imagePosition = .imageLeading
        // Click = play/pause. Right-click (or Control-click) = the menu.
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: tracker))
        tracker.onHover = { [weak self] in self?.overButton = $0; self?.hoverChanged() }
        panel.root.onHover = { [weak self] in self?.overPanel = $0; self?.hoverChanged() }
        wirePanel()
        showIdle()
        buildMenu()
        startHelper()
        // NOWMUSICBAR_DEMO=1 opens the panel without a hover, for screenshots.
        // NOWMUSICBAR_DEMO=video plays a scripted walkthrough on a plain backdrop. Nothing is sent to Music.
        if let demo = ProcessInfo.processInfo.environment["NOWMUSICBAR_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let b = self.item.button else { return }
                demo == "video" ? self.playDemo(b) : self.panel.show(under: b)
            }
        }
    }

    var backdrop: NSWindow?

    func playDemo(_ b: NSStatusBarButton) {
        let p = panel
        p.extraDrop = 44
        p.show(under: b)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            let f = p.panel.frame
            p.panel.alphaValue = 0; p.panel.orderOut(nil); p.shown = false
            let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main!
            let rec = f.insetBy(dx: -44, dy: -44)
            let back = NSWindow(contentRect: rec.intersection(screen.visibleFrame), styleMask: .borderless, backing: .buffered, defer: false)
            back.backgroundColor = NSColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1)
            back.level = .floating
            back.orderFrontRegardless()
            backdrop = back
            let h0 = NSScreen.screens[0].frame.maxY
            let r = rec.intersection(screen.visibleFrame)
            FileHandle.standardError.write("REC \(Int(r.minX)),\(Int(h0 - r.maxY)),\(Int(r.width)),\(Int(r.height))\n".data(using: .utf8)!)
            demoSteps(b)
        }
    }

    func demoSteps(_ b: NSStatusBarButton) {
        let p = panel
        var t = 1.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0) { p.show(under: b); p.ticker?.invalidate() }
        at(1.4) { p.playButton.hovered = true }
        at(0.9) { p.playButton.hovered = false; p.scrubber.hovered = true }
        at(0.5) {
            let from = p.scrubber.position, to = min(from + p.track.duration * 0.25, p.track.duration - 5), began = Date()
            Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { tm in
                let k = min(Date().timeIntervalSince(began) / 1.2, 1), e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
                p.scrubber.position = from + (to - from) * e
                p.elapsedLabel.stringValue = clock(p.scrubber.position)
                if k >= 1 { tm.invalidate() }
            }
        }
        at(1.6) { p.scrubber.hovered = false; p.nextButton.hovered = true }
        at(0.7) { p.nextButton.hovered = false; p.addButton.hovered = true }
        at(0.8) { p.addButton.hovered = false; p.library.set(saved: true, animated: true) }
        at(1.8) { p.hide() }
        at(1.2) { FileHandle.standardError.write("DONE\n".data(using: .utf8)!) }
    }

    func wirePanel() {
        panel.playButton.onPress = { [weak self] in self?.togglePlay() }
        panel.previousButton.onPress = { [weak self] in self?.send("previous") }
        panel.nextButton.onPress = { [weak self] in self?.send("next") }
        panel.shuffleButton.onPress = { [weak self] in
            guard let self else { return }
            self.track.shuffle = self.track.shuffle > 1 ? 1 : 3
            self.send("shuffle \(self.track.shuffle)")
            self.panel.update(self.track, art: self.fullArt, saved: self.saved)
        }
        panel.repeatButton.onPress = { [weak self] in
            guard let self else { return }
            // Music's order: off, all, one.
            self.track.repeatMode = [1: 3, 3: 2, 2: 1][self.track.repeatMode] ?? 3
            self.send("repeat \(self.track.repeatMode)")
            self.panel.update(self.track, art: self.fullArt, saved: self.saved)
        }
        panel.scrubber.onSeek = { [weak self] t in
            guard let self else { return }
            self.track.position = t; self.track.at = Date()
            self.panel.track = self.track
            self.send(String(format: "seek %.2f", t))
        }
        panel.addButton.onPress = { [weak self] in self?.addToLibrary() }
        panel.optionsButton.onPress = { [weak self] in
            guard let self else { return }
            let b = self.panel.optionsButton
            let menu = self.makeMenu()
            self.hoverTimer?.invalidate()
            self.overPanel = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
            // popUp returns once the menu closes; re-check where the pointer is now.
            let p = self.panel.root.convert(self.panel.panel.mouseLocationOutsideOfEventStream, from: nil)
            self.overPanel = self.panel.root.bounds.contains(p)
            self.hoverChanged()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        quitting = true
        helper?.terminate()
    }

    // Re-opening the app from Finder while it runs: open its menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let b = item.button { panel.show(under: b) }
        return false
    }

    // Show after a short dwell; hide shortly after the pointer leaves both the item and the panel.
    func hoverChanged() {
        hoverTimer?.invalidate()
        let want = (overButton || overPanel) && hasTrack && !menuOpen
        if want == panel.shown { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: want ? 0.12 : 0.3, repeats: false) { [weak self] _ in
            guard let self, let b = self.item.button else { return }
            let still = (self.overButton || self.overPanel) && self.hasTrack && !self.menuOpen
            still ? self.panel.show(under: b) : self.panel.hide()
        }
    }

    func send(_ cmd: String) {
        helperIn?.write((cmd + "\n").data(using: .utf8)!)
    }

    func startHelper() {
        guard let res = Bundle.main.resourcePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res + "/helper.pl", res + "/libhelper.dylib"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.receive(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.quitting else { return }
                self.startHelper()
            }
        }
        try? p.run()
        helper = p
        helperIn = inp.fileHandleForWriting
    }

    func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { update(obj) }
        }
    }

    func update(_ o: [String: Any]) {
        guard let title = o["title"] as? String, !title.isEmpty else {
            hasTrack = false; track = Track(); showIdle(); panel.hide(); buildMenu(); return
        }
        var t = Track()
        t.source = o["source"] as? String
        t.title = title
        t.artist = (o["artist"] as? String) ?? ""
        t.playing = (o["playing"] as? Bool) ?? false
        t.position = (o["position"] as? Double) ?? 0
        t.duration = (o["duration"] as? Double) ?? 0
        t.shuffle = (o["shuffle"] as? Int) ?? 0
        t.repeatMode = (o["repeat"] as? Int) ?? 0
        let changed = t.title != track.title || t.artist != track.artist || t.source != track.source
        if let b64 = o["art"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
            fullArt = img; art = thumbnail(img)
        } else if o["keepArt"] == nil {
            fullArt = nil; art = nil
        }
        track = t
        hasTrack = true
        if changed { saved = nil; checkLibrary() }

        let text = t.artist.isEmpty ? title : "\(t.artist) – \(title)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: t.playing ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        item.button?.image = art
        item.button?.attributedTitle = NSAttributedString(string: art == nil ? text : " " + text, attributes: attrs)
        item.button?.setAccessibilityLabel(text)
        item.button?.toolTip = nil
        item.length = NSStatusItem.variableLength
        panel.update(t, art: fullArt, saved: saved)
        buildMenu()
    }

    // Music's own scripting: whether the song is in the library, and adding it.
    func music(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: "tell application \"Music\"\n\(source)\nend tell")?.executeAndReturnError(&err)
    }

    func checkLibrary() {
        guard track.isMusic else { return }
        let key = track.title + "|" + track.artist
        scripts.async { [weak self] in
            let r = self?.music("""
            set t to current track
            return (count of (tracks of library playlist 1 whose name is (name of t) and artist is (artist of t))) > 0
            """)
            DispatchQueue.main.async {
                guard let self, let r, self.track.title + "|" + self.track.artist == key else { return }
                self.saved = r.booleanValue
                self.panel.setSaved(self.saved)
                self.buildMenu()
            }
        }
    }

    func addToLibrary() {
        saved = true
        panel.setSaved(true, animated: true)
        scripts.async { [weak self] in
            _ = self?.music("duplicate current track to library playlist 1")
            DispatchQueue.main.async { self?.checkLibrary() }
        }
    }

    func showIdle() {
        art = nil; fullArt = nil
        item.length = NSStatusItem.variableLength
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.setAccessibilityLabel("Nothing playing in Music or Podcasts")
        let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now playing")
        img?.isTemplate = true
        item.button?.image = img
    }

    func thumbnail(_ img: NSImage) -> NSImage {
        let side: CGFloat = 18
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 3, yRadius: 3).addClip()
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        out.unlockFocus()
        return out
    }

    func buildMenu() {}

    @objc func statusClicked() {
        let e = NSApp.currentEvent
        let wantsMenu = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true || !hasTrack
        if !wantsMenu { togglePlay(); return }
        let m = makeMenu()
        m.delegate = self
        item.menu = m
        item.button?.performClick(nil)  // opens the attached menu
        item.menu = nil
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        if hasTrack {
            m.addItem(withTitle: track.playing ? "Pause" : "Play", action: #selector(togglePlay), keyEquivalent: " ").keyEquivalentModifierMask = []
            m.addItem(withTitle: "Next", action: #selector(nextTrack), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)).keyEquivalentModifierMask = []
            m.addItem(withTitle: "Previous", action: #selector(previousTrack), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)).keyEquivalentModifierMask = []
            if track.isMusic && saved == false {
                m.addItem(withTitle: "Add to Library", action: #selector(addFromMenu), keyEquivalent: "+").keyEquivalentModifierMask = []
            }
            m.addItem(.separator())
        }
        let open = track.isMusic ? "Open Music" : "Open Podcasts"
        m.addItem(withTitle: open, action: #selector(openSource), keyEquivalent: "")
        m.addItem(.separator())
        let login = m.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Quit NowMusicBar", action: #selector(quit), keyEquivalent: "q")
        m.items.forEach { $0.target = self }
        return m
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; hoverTimer?.invalidate(); panel.hide() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc func togglePlay() {
        send("toggle")
        track.playing.toggle(); track.at = Date()
        panel.update(track, art: fullArt, saved: saved)
    }
    @objc func nextTrack() { send("next") }
    @objc func previousTrack() { send("previous") }
    @objc func addFromMenu() { addToLibrary() }

    @objc func openSource() {
        let id = track.isMusic ? "com.apple.Music" : "com.apple.podcasts"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc func toggleLogin() {
        let on = SMAppService.mainApp.status == .enabled
        do { on ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() } catch {}
        UserDefaults.standard.set(!on, forKey: "openAtLogin")
        buildMenu()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
