import AppKit
import SwiftUI

/// The one pane of glass this app draws.
///
/// Every translucent surface here — the lock card, the lyric page's sync pill,
/// the output picker — used to mix its own gradients by hand, which is why no
/// two of them agreed and why each needed retuning whenever the last one
/// changed. This is the recipe, in one place, in terms every surface can ask
/// for: how far off the ground it sits, and whether it has a colour to carry.
///
/// It deliberately does not depend on sampling what is behind it. Vibrancy is
/// laid underneath where it can help — over an ordinary desktop it samples and
/// the surface is better for it — but the glass reads as glass without it,
/// which matters because there is one place it can never work: above the login
/// shield, which is protected content that no window is given a backdrop for.
/// The system's own lock-screen widgets are built the same way, and for the
/// same reason.
struct GlassSurface: View {
    enum Elevation {
        /// A whole panel resting on the wallpaper.
        case card
        /// Something opened over a panel — a picker, a menu.
        case popover
        /// A small control floating over content.
        case pill

        var rimOpacity: (top: Double, middle: Double, bottom: Double) {
            switch self {
            case .card: return (0.72, 0.20, 0.08)
            case .popover: return (0.44, 0.14, 0.06)
            case .pill: return (0.34, 0.12, 0.05)
            }
        }

        /// How dark the pane is before anything is drawn on it. A pill sits on
        /// content that is already dark; a card sits on a wallpaper and has to
        /// carry white type over whatever that is.
        var base: (leading: Double, trailing: Double) {
            switch self {
            case .card: return (0.34, 0.16)
            case .popover: return (0.62, 0.52)
            case .pill: return (0.55, 0.55)
            }
        }

        var grain: Double {
            switch self {
            case .card: return 0.035
            case .popover, .pill: return 0.02
            }
        }
    }

    var elevation: Elevation = .card
    /// A colour for the glass to carry — the artwork's, usually. Held weak on
    /// purpose: at full strength a cover turns the pane into a stained window,
    /// which is a coloured slab by another name.
    var tint: Color?
    /// An image to light the pane from behind, blurred past recognition.
    var light: NSImage?
    /// Whether to lay window vibrancy underneath. Off for surfaces drawn inside
    /// a window that is already opaque, where it would sample nothing.
    var samplesBackdrop = true

    var body: some View {
        ZStack {
            if samplesBackdrop {
                VibrancyBackdrop(material: .hudWindow, appearance: .vibrantDark)
            }

            if let light {
                Color.clear
                    .overlay {
                        Image(nsImage: light)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 52)
                            .saturation(0.72)
                            .opacity(0.28)
                    }
                    .transition(.opacity)
            }

            // The pane's own colour, so it is grey glass rather than only
            // whatever is lighting it.
            LinearGradient(
                colors: [
                    .black.opacity(elevation.base.leading),
                    .black.opacity(elevation.base.trailing),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [.white.opacity(0.10), .white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let tint {
                LinearGradient(
                    colors: [tint.opacity(0.14), tint.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // The specular streak: light crossing the pane, raked over the
            // top-left shoulder. Without it a translucent rectangle is just a
            // translucent rectangle.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .white.opacity(0.14), location: 0.16),
                    .init(color: .white.opacity(0.02), location: 0.30),
                    .init(color: .clear, location: 0.42),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)

            // And the grain. Real glass is never a clean gradient, and this is
            // the single mark that stops the surface reading as a flat fill —
            // worth more than any amount of tuning the gradients above it.
            Image(nsImage: Self.grain)
                .resizable(resizingMode: .tile)
                .opacity(elevation.grain)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Grain

    /// A small tile of noise, made once and reused. Deterministic, so the
    /// surface looks the same every launch and a test can say what it is.
    nonisolated(unsafe) static let grain: NSImage = grainTile(side: 96)

    /// Plain value noise from a fixed seed — no Foundation randomness, so this
    /// is the same tile on every machine and in every run.
    static func grainTile(side: Int, seed: UInt64 = 0x5EED_1515_D0D0_CAFE) -> NSImage {
        var state = seed
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            // xorshift64*, which is small, fast and entirely predictable.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 33)
            let offset = index * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32
        )
        if let rep, let data = rep.bitmapData {
            pixels.withUnsafeBufferPointer { buffer in
                data.update(from: buffer.baseAddress!, count: pixels.count)
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        if let rep { image.addRepresentation(rep) }
        return image
    }
}

extension View {
    /// Puts this content on a pane of glass, clipped and edged to match.
    func glassSurface(
        cornerRadius: CGFloat,
        elevation: GlassSurface.Elevation = .card,
        tint: Color? = nil,
        light: NSImage? = nil,
        samplesBackdrop: Bool = true
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            GlassSurface(elevation: elevation, tint: tint, light: light, samplesBackdrop: samplesBackdrop)
        }
        .clipShape(shape)
        .overlay {
            // An edge that catches light along the top and loses it toward the
            // bottom, the way a lit pane does. A single flat stroke reads as a
            // drawn border instead.
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(elevation.rimOpacity.top),
                        .white.opacity(elevation.rimOpacity.middle),
                        .white.opacity(elevation.rimOpacity.bottom),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
    }
}
