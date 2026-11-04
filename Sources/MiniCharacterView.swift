import SwiftUI
import AppKit

// A mounted NSView performs drag/resize in AppKit without publishing a SwiftUI
// state change on every mouse event. Only mouseUp commits geometry to SwiftUI.
// This prevents the GeometryReader/NSImageView relayout loop seen on Monterey.
enum MiniInteractionMath {
    static func bounded(_ current: CGFloat, delta: CGFloat,
                        minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard current.isFinite && delta.isFinite else { return current }
        return min(maximum, max(minimum, current + delta))
    }
    static func isDrag(_ delta: CGSize) -> Bool {
        abs(delta.width) + abs(delta.height) >= 6
    }
}

enum MiniFramePlayback {
    static func advance(index: Int, direction: Int, count: Int) -> (index: Int, direction: Int) {
        guard count > 1 else { return (0, 1) }
        let proposed = index + direction
        if proposed >= count { return (count - 2, -1) }
        if proposed < 0 { return (1, 1) }
        return (proposed, direction)
    }
}

private final class MiniTransparentImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    // Retina downscaling/upscaling should use high-quality interpolation.
    // Layer-backed image views otherwise inherit renderer-dependent sampling.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        super.draw(dirtyRect)
    }
    // Let the containing native view capture the pointer, not this child image.
    override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }
}

private final class MiniNativeFrameHost: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var didTap: (() -> Void)?
    var didMove: ((CGSize) -> Void)?
    var didResize: ((CGFloat) -> Void)?

    private let portrait = MiniTransparentImageView()
    private let resizeHint = MiniTransparentImageView()
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var direction = 1
    private var ticker: Timer?
    private var currentMood = ""
    private var startPoint: NSPoint?
    private var isResizing = false
    private var lastDrag = CGSize.zero
    private var hoverArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        portrait.wantsLayer = true
        portrait.layer?.backgroundColor = NSColor.clear.cgColor
        portrait.layer?.magnificationFilter = .linear
        portrait.layer?.minificationFilter = .trilinear
        portrait.imageScaling = .scaleProportionallyUpOrDown
        portrait.translatesAutoresizingMaskIntoConstraints = false
        addSubview(portrait)
        NSLayoutConstraint.activate([
            portrait.leadingAnchor.constraint(equalTo: leadingAnchor),
            portrait.trailingAnchor.constraint(equalTo: trailingAnchor),
            portrait.topAnchor.constraint(equalTo: topAnchor),
            portrait.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        resizeHint.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                    accessibilityDescription: "调整 Mini 酱大小")
        resizeHint.imageScaling = .scaleProportionallyDown
        resizeHint.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        resizeHint.translatesAutoresizingMaskIntoConstraints = false
        resizeHint.wantsLayer = true
        // A discreet translucent corner grip, not a permanently bright
        // purple sticker over the character artwork.
        resizeHint.layer?.backgroundColor =
            NSColor(calibratedRed: 0.32, green: 0.23, blue: 0.47, alpha: 0.46).cgColor
        resizeHint.layer?.cornerRadius = 11
        resizeHint.layer?.borderWidth = 0.7
        resizeHint.layer?.borderColor = NSColor.white.withAlphaComponent(0.23).cgColor
        resizeHint.alphaValue = 0.58
        addSubview(resizeHint)
        NSLayoutConstraint.activate([
            resizeHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            resizeHint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 4),
            resizeHint.widthAnchor.constraint(equalToConstant: 22),
            resizeHint.heightAnchor.constraint(equalToConstant: 22)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { ticker?.invalidate() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let previous = hoverArea { removeTrackingArea(previous) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nearGrip = point.x >= bounds.width - 46 && point.y <= 46
        resizeHint.alphaValue = nearGrip ? 0.96 : 0.58
    }

    override func mouseExited(with event: NSEvent) {
        resizeHint.alphaValue = 0.58
    }

    private func startAnimation() {
        ticker?.invalidate()
        guard frames.count > 1 else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            guard let self = self, self.startPoint == nil else { return }
            let next = MiniFramePlayback.advance(index: self.frameIndex,
                                                 direction: self.direction,
                                                 count: self.frames.count)
            self.frameIndex = next.index
            self.direction = next.direction
            self.portrait.image = self.frames[self.frameIndex]
        }
    }

    func setMood(_ mood: String) {
        let candidate = ["talk", "think", "happy"].contains(mood) ? mood : "idle"
        guard candidate != currentMood else { return }
        currentMood = candidate
        ticker?.invalidate()
        ticker = nil
        frameIndex = 0
        direction = 1
        frames.removeAll(keepingCapacity: true)
        if let root = Bundle.main.resourceURL?.appendingPathComponent("Live2DFrames") {
            for i in 0..<12 {
                let url = root.appendingPathComponent(candidate)
                    .appendingPathComponent(String(format: "%03d.png", i))
                if let image = NSImage(contentsOf: url) { frames.append(image) }
            }
        }
        if let first = frames.first {
            portrait.image = first
            startAnimation()
        } else if let url = Bundle.main.resourceURL?.appendingPathComponent("MiniAgentIcon.png") {
            portrait.image = NSImage(contentsOf: url)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        lastDrag = .zero
        let local = convert(event.locationInWindow, from: nil)
        isResizing = local.x >= bounds.width - 38 && local.y <= 38
        ticker?.invalidate()  // Avoid decoding/refreshing PNG during tracking.
        ticker = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = startPoint else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard dx.isFinite && dy.isFinite else { return }
        if isResizing {
            let delta = dx - dy
            lastDrag = CGSize(width: delta, height: delta)
            let scale = max(0.70, min(1.35, 1 + delta / max(bounds.width, 96)))
            layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        } else {
            lastDrag = CGSize(width: dx, height: -dy)
            // Moving only the CALayer avoids a SwiftUI layout pass each frame.
            layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        let moved = lastDrag
        let resize = isResizing
        startPoint = nil
        isResizing = false
        lastDrag = .zero
        // A state update inside an AppKit mouse event may re-enter the view tree
        // during event dispatch. Commit on the next main-loop iteration instead.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if resize {
                if MiniInteractionMath.isDrag(moved) { self.didResize?(moved.width) }
            } else if MiniInteractionMath.isDrag(moved) {
                self.didMove?(moved)
            } else {
                self.didTap?()
            }
            self.layer?.setAffineTransform(.identity)
            self.startAnimation()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil && startPoint == nil {
            startAnimation()
        }
    }
}

struct MiniCharacterView: NSViewRepresentable {
    let mood: String
    var onTap: () -> Void
    var onMove: (CGSize) -> Void
    var onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let host = MiniNativeFrameHost(frame: .zero)
        host.didTap = onTap
        host.didMove = onMove
        host.didResize = onResize
        host.setMood(mood)
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? MiniNativeFrameHost else { return }
        host.didTap = onTap
        host.didMove = onMove
        host.didResize = onResize
        host.setMood(mood)
    }
}

// Chat resize also uses native mouse tracking rather than an @GestureState
// changing a large SwiftUI ScrollView on every pointer event.
private final class MiniResizeOnlyView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var didFinish: ((CGSize) -> Void)?
    private var origin: NSPoint?
    private var delta: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.23, blue: 0.47, alpha: 0.46).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.23).cgColor
        layer?.borderWidth = 0.7
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.withAlphaComponent(0.86).setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 1.35
        // A small, readable diagonal resize glyph with ample padding.
        path.move(to: NSPoint(x: 9, y: 17))
        path.line(to: NSPoint(x: 18, y: 8))
        path.move(to: NSPoint(x: 12, y: 8))
        path.line(to: NSPoint(x: 18, y: 8))
        path.line(to: NSPoint(x: 18, y: 14))
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
        delta = .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = origin else { return }
        delta = CGSize(width: event.locationInWindow.x - origin.x,
                       height: origin.y - event.locationInWindow.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        origin = nil
        let final = delta
        delta = .zero
        guard MiniInteractionMath.isDrag(final) else { return }
        DispatchQueue.main.async { [weak self] in self?.didFinish?(final) }
    }
}

// A real NSView gesture event regression, run with --self-test on the Mac runner.
// No window server or API key required. Verifies that pointer movement does not
// trigger SwiftUI state callbacks until mouseUp, and that input is bounded.
@MainActor
enum MiniCharacterGestureQA {
    static func perform() async throws {
        func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            if !ok() { throw NSError(domain: "MinyraGestureQA", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1.0)
            else { throw NSError(domain: "MinyraGestureQA", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: "Cannot synthesize mouse event"]) }
            return e
        }
        let host = MiniNativeFrameHost(frame: NSRect(x: 0, y: 0, width: 160, height: 210))
        var taps = 0
        var moves: [CGSize] = []
        var resizes: [CGFloat] = []
        host.didTap = { taps += 1 }
        host.didMove = { moves.append($0) }
        host.didResize = { resizes.append($0) }
        host.mouseDown(with: try event(.leftMouseDown, 75, 100))
        for i in 1...30 {
            host.mouseDragged(with: try event(.leftMouseDragged,
                                               75 + CGFloat(i), 100 + CGFloat(i) / 2))
        }
        try require(moves.isEmpty && resizes.isEmpty && taps == 0,
                    "Drag incorrectly mutates SwiftUI on every mouse movement")
        host.mouseUp(with: try event(.leftMouseUp, 105, 115))
        // Let the AppKit mouseUp callback actually execute on MainActor.
        try await Task.sleep(nanoseconds: 80_000_000)
        print("MINYRA_GESTURE_TRACE: frame=\(host.frame) bounds=\(host.bounds) moves=\(moves.map { "\($0.width),\($0.height)" }) resizes=\(resizes) taps=\(taps)")
        print("MINYRA_GESTURE_TRACE: moves=\(moves.count), taps=\(taps), resizes=\(resizes.count), firstMove=\(String(describing: moves.first))")
        try require(moves.count == 1 && taps == 0 && resizes.isEmpty,
                    "Character move did not commit exactly once")
        try require(abs(moves[0].width - 30) < 0.01 && abs(moves[0].height + 15) < 0.01,
                    "Character move delta is wrong")
        host.mouseDown(with: try event(.leftMouseDown, 150, 15))
        host.mouseDragged(with: try event(.leftMouseDragged, 170, 5))
        host.mouseUp(with: try event(.leftMouseUp, 170, 5))
        // Let the AppKit mouseUp callback actually execute on MainActor.
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(resizes.count == 1 && abs(resizes[0] - 30) < 0.01,
                    "Character resize did not commit exactly once")
        host.mouseDown(with: try event(.leftMouseDown, 65, 75))
        host.mouseUp(with: try event(.leftMouseUp, 65, 75))
        // Let the AppKit mouseUp callback actually execute on MainActor.
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(taps == 1, "Tap-to-chat did not register")
        let chatHandle = MiniResizeOnlyView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        var chatSizeChanges: [CGSize] = []
        chatHandle.didFinish = { chatSizeChanges.append($0) }
        chatHandle.mouseDown(with: try event(.leftMouseDown, 10, 10))
        for i in 1...20 {
            chatHandle.mouseDragged(with: try event(.leftMouseDragged,
                                                    10 + CGFloat(i), 10 - CGFloat(i) / 2))
        }
        try require(chatSizeChanges.isEmpty, "Chat panel resizing publishes per-move UI updates")
        chatHandle.mouseUp(with: try event(.leftMouseUp, 30, 0))
        // Let the AppKit mouseUp callback actually execute on MainActor.
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(chatSizeChanges.count == 1 && chatSizeChanges[0].width == 20 &&
                    chatSizeChanges[0].height == 10, "Chat resize did not commit exactly once")
        try require(!host.mouseDownCanMoveWindow && !chatHandle.mouseDownCanMoveWindow,
                    "Companion gesture was incorrectly delegated to moving the whole app window")
        try require(MiniInteractionMath.bounded(140, delta: -99999,
                      minimum: 96, maximum: 240) == 96 &&
                    MiniInteractionMath.bounded(140, delta: 99999,
                      minimum: 96, maximum: 240) == 240,
                    "Character resize bounds failed")
        print("MINYRA_NATIVE_GESTURE_QA_PASS: 30 avatar drag events, 20 chat-resize events, tap and scale with single commits")
    }
}

struct MiniNativeChatResizeHandle: NSViewRepresentable {
    let onResize: (CGSize) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = MiniResizeOnlyView(frame: .zero)
        view.didFinish = onResize
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? MiniResizeOnlyView)?.didFinish = onResize
    }
}
