import AgentNotchCore
import AppKit
import QuartzCore
import SwiftUI

/// D42: the three D34 motions as Core Animation keyframes. The window server runs them, so a moving
/// notch costs the app nothing per frame; SwiftUI timelines cost 4–7% CPU each. Every copy starts in
/// step with the wall clock (`Motion.timeOffset`), as the timeline versions did.
enum LayerMotion {
    /// A SwiftUI colour as a CGColor for the given scheme: the notch is always dark, the dropdown
    /// follows the system, and a layer does not resolve dynamic colours on its own.
    static func cgColor(_ color: Color, dark: Bool) -> CGColor {
        let ns = NSColor(color)
        var cg = ns.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cg = ns.cgColor }
        return cg
    }

    static func loop(_ keyPath: String, _ values: [Double], period: TimeInterval, lag: Double = 0) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { NSNumber(value: $0) }
        a.duration = period
        a.repeatCount = .infinity
        a.calculationMode = .linear
        a.timeOffset = Motion.timeOffset(now: Date(), period: period, lag: lag)
        a.isRemovedOnCompletion = false
        return a
    }

    static let keyframes = 33
}

// MARK: - Working dots

/// Three dots rising in turn (Q4), drawn by three layers.
final class DotsLayerView: NSView {
    private let dots = (0..<3).map { _ in CALayer() }
    private var animatedSize: CGFloat = 0
    var dotSize: CGFloat = 4.5 { didSet { if dotSize != oldValue { needsLayout = true } } }
    var color: CGColor = .clear { didSet { dots.forEach { $0.backgroundColor = color } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()                     // layer-hosting: AppKit leaves the sublayers alone
        wantsLayer = true
        dots.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.position = CGPoint(x: dotSize / 2 + CGFloat(i) * 1.6 * dotSize, y: bounds.midY)
        }
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    /// Lift `0.4 × size × wave²` and fade `0.35 + 0.65 × wave²`, as `WorkingDots` always drew them.
    private func animate() {
        guard window != nil, animatedSize != dotSize || dots[0].animation(forKey: "lift") == nil else { return }
        animatedSize = dotSize
        let lift = Motion.dotLift(samples: LayerMotion.keyframes)
        for (i, dot) in dots.enumerated() {
            let lag = Double(i) * Motion.dotsStagger
            dot.add(LayerMotion.loop("transform.translation.y", lift.map { 0.4 * Double(dotSize) * $0 }, period: Motion.dotsPeriod, lag: lag), forKey: "lift")
            dot.add(LayerMotion.loop("opacity", lift.map { 0.35 + 0.65 * $0 }, period: Motion.dotsPeriod, lag: lag), forKey: "fade")
        }
    }
}

struct DotsLayer: NSViewRepresentable {
    let color: CGColor
    let size: CGFloat

    func makeNSView(context: Context) -> DotsLayerView { DotsLayerView() }

    func updateNSView(_ view: DotsLayerView, context: Context) {
        view.dotSize = size
        view.color = color
    }
}

// MARK: - Needs-you glow

/// SwiftUI content whose shadow breathes every two seconds (Q4): opacity `0.35 + 0.5 × wave`,
/// radius `radius × (0.4 + 0.6 × wave)`. The shadow follows the content's shape, like `.shadow`.
final class GlowHostView<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private var animatedRadius: CGFloat = -1
    var radius: CGFloat = 6 { didSet { if radius != oldValue { animate() } } }
    var color: CGColor = .clear { didSet { layer?.shadowColor = color } }

    init(content: Content) {
        hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOffset = .zero
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        guard window != nil, let layer, animatedRadius != radius || layer.animation(forKey: "breath") == nil else { return }
        animatedRadius = radius
        let levels = Motion.glowLevels(samples: LayerMotion.keyframes)
        layer.add(LayerMotion.loop("shadowOpacity", levels.map { 0.35 + 0.5 * $0 }, period: Motion.glowPeriod), forKey: "breath")
        layer.add(LayerMotion.loop("shadowRadius", levels.map { Double(radius) * (0.4 + 0.6 * $0) }, period: Motion.glowPeriod), forKey: "spread")
    }
}

struct GlowLayer<Content: View>: NSViewRepresentable {
    let content: Content
    let color: CGColor
    let radius: CGFloat

    func makeNSView(context: Context) -> GlowHostView<Content> { GlowHostView(content: content) }

    func updateNSView(_ view: GlowHostView<Content>, context: Context) {
        view.hosting.rootView = content
        view.color = color
        view.radius = radius
    }

    /// The frame of the hidden copy it overlays.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GlowHostView<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - Thinking shimmer

/// The highlight text, seen through a band that sweeps across it every 2.2 s (Q5). The band is 35%
/// of the width and travels from just before the leading edge to just past the trailing one.
final class ShimmerHostView<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private let band = CAGradientLayer()
    private var animatedWidth: CGFloat = -1

    init(content: Content) {
        hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        band.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = band
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.35, height: bounds.height)
        band.position = CGPoint(x: -bounds.width * 0.175, y: bounds.midY)
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        let w = bounds.width
        guard window != nil, w > 0, animatedWidth != w || band.animation(forKey: "sweep") == nil else { return }
        animatedWidth = w
        let travel = (0..<LayerMotion.keyframes).map { Double(-0.175 * w + 1.35 * w * CGFloat($0) / CGFloat(LayerMotion.keyframes - 1)) }
        band.add(LayerMotion.loop("position.x", travel, period: Motion.shimmerPeriod), forKey: "sweep")
    }
}

struct ShimmerLayer<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> ShimmerHostView<Content> { ShimmerHostView(content: content) }

    func updateNSView(_ view: ShimmerHostView<Content>, context: Context) { view.hosting.rootView = content }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerHostView<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
