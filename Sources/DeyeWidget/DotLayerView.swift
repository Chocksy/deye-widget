import AppKit
import SwiftUI

// MARK: - Dot spine model

/// One traveling-dot spine rendered as CALayers driven by repeating
/// CAKeyframeAnimations -- the render server animates them, so the app does no
/// per-frame work at all. A SwiftUI Canvas redrawn at 30 fps feeds RenderBox
/// SurfacePool eviction timers faster than they retire: after 24 h uptime that
/// left ~669k armed dispatch sources and ~45% CPU, even with only the dots left
/// in the per-frame canvas.
struct DotSpec: Equatable {
    /// Stable per spine, so an unchanged spine keeps its running animations.
    let id: String
    /// The spine curve sampled at equal Bézier-parameter steps across the travel
    /// window, in view coordinates, already reversed when travel runs
    /// inverter -> node. Equal-u spacing is what preserves the old
    /// parameter-speed pacing -- arc-length pacing would visibly differ.
    let points: [CGPoint]
    let dotCount: Int
    let period: Double
    /// The GlowSprite image, i.e. the same instance the canvas stamped.
    let sprite: NSImage
    /// Sprite point size (square).
    let side: CGFloat
}

// MARK: - Layer-hosting representable

struct DotLayerView: NSViewRepresentable {
    let specs: [DotSpec]
    let displayScale: CGFloat

    func makeNSView(context: Context) -> DotHostView {
        let v = DotHostView()
        v.apply(specs: specs, displayScale: displayScale)
        return v
    }

    func updateNSView(_ nsView: DotHostView, context: Context) {
        nsView.apply(specs: specs, displayScale: displayScale)
    }
}

/// Layer-hosting NSView: it owns its root layer and never draws itself.
final class DotHostView: NSView {
    private var applied: [String: DotSpec] = [:]
    private var layersBySpine: [String: [CALayer]] = [:]
    /// NSImage -> CGImage once per sprite, not once per dot layer. GlowSprite
    /// hands back the same NSImage instance per color/size, so identity keys are
    /// stable and the cache stays as small as GlowSprite's own.
    private var cgCache: [ObjectIdentifier: CGImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        // Dots ride 1-2 pt proud of the bounds mid-curve, exactly as they did
        // when the canvas drew them.
        root.masksToBounds = false
        layer = root        // assign before wantsLayer -> layer-hosting, not layer-backed
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("DotHostView is code-only") }

    /// Match SwiftUI's top-left origin so spec points need no conversion.
    override var isFlipped: Bool { true }

    /// Diff by id: untouched spines keep animating, changed ones are rebuilt.
    func apply(specs: [DotSpec], displayScale: CGFloat) {
        guard let root = layer else { return }
        let incoming = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let stale = applied.filter { incoming[$0.key] != $0.value }.map(\.key)
        for id in stale {
            layersBySpine[id]?.forEach { $0.removeFromSuperlayer() }
            layersBySpine.removeValue(forKey: id)
            applied.removeValue(forKey: id)
        }
        for spec in specs where applied[spec.id] == nil {
            layersBySpine[spec.id] = build(spec, root: root, displayScale: displayScale)
            applied[spec.id] = spec
        }

        CATransaction.commit()
    }

    private func build(_ spec: DotSpec, root: CALayer, displayScale: CGFloat) -> [CALayer] {
        guard let image = cgImage(for: spec.sprite), let start = spec.points.first,
              spec.dotCount > 0, spec.period > 0 else { return [] }
        let values = spec.points.map { NSValue(point: $0) }
        var made: [CALayer] = []

        for i in 0..<spec.dotCount {
            let dot = CALayer()
            dot.contents = image
            dot.contentsScale = displayScale
            dot.bounds = CGRect(x: 0, y: 0, width: spec.side, height: spec.side)
            dot.position = start        // anchorPoint (0.5,0.5) -> position is the dot centre

            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.values = values
            anim.calculationMode = .linear      // even key spacing == parameter-speed pacing
            anim.duration = spec.period
            anim.repeatCount = .greatestFiniteMagnitude
            anim.isRemovedOnCompletion = false
            // Phase anchored to the media clock rather than to when this layer was
            // built, so a rebuild (every poll, since the period tracks |W|) resumes
            // at the phase the old animation would have reached instead of snapping
            // back to the start. The i/dotCount term reproduces the old
            // (base + i/dotCount) stagger.
            anim.timeOffset = (CACurrentMediaTime()
                               + Double(i) / Double(spec.dotCount) * spec.period)
                .truncatingRemainder(dividingBy: spec.period)
            dot.add(anim, forKey: "travel")

            root.addSublayer(dot)
            made.append(dot)
        }
        return made
    }

    private func cgImage(for image: NSImage) -> CGImage? {
        let key = ObjectIdentifier(image)
        if let hit = cgCache[key] { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cgCache[key] = cg
        return cg
    }
}
