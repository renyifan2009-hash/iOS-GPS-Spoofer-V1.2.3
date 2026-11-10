import SwiftUI
import UIKit

/// SpoofRemote's look: Apple's Liquid Glass (iOS 26 and later, when built
/// with the iOS 26 SDK) in soft sage, mist and lavender tones. Every helper falls
/// back to system materials, so the app still builds with Xcode 16 and runs
/// on iOS 17.
///
/// The glass code is gated on the SDK (`canImport(SwiftUI, _version: 7.0)`;
/// SwiftUI 7 ships in the iOS 26 SDK), not on the compiler version: a newer
/// Swift toolchain can be paired with an older SDK that has no Liquid Glass.
enum Brand {
    // Soft, calm tones: sage and mist with a dusty lavender, warm apricot for "wait" and terracotta
    // for Stop. (The names are the old ones, so every view picked the new palette up at once.)
    /// The main accent: sage.
    static let indigo = Color(red: 0.369, green: 0.545, blue: 0.522)
    /// Dusty lavender.
    static let violet = Color(red: 0.604, green: 0.576, blue: 0.769)
    /// The second accent: mist blue.
    static let sky = Color(red: 0.553, green: 0.706, blue: 0.780)
    /// Live / ready: soft moss.
    static let live = Color(red: 0.498, green: 0.702, blue: 0.541)
    static let warning = Color(red: 0.878, green: 0.659, blue: 0.404)
    /// Stop and errors: terracotta.
    static let danger = Color(red: 0.831, green: 0.478, blue: 0.431)
    /// The dark sheets' background: deep slate green.
    static let night = Color(red: 0.102, green: 0.145, blue: 0.149)
    /// Pins: a softer coral than a warning red.
    static let pin = [Color(red: 0.91, green: 0.56, blue: 0.50), Color(red: 0.78, green: 0.41, blue: 0.37)]

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var routeGradient: LinearGradient {
        LinearGradient(colors: [live, indigo, sky], startPoint: .leading, endPoint: .trailing)
    }

    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// The one spring everything moves with, so the app feels of a piece.
    static let spring = Animation.spring(duration: 0.5, bounce: 0.28)
    static let snappy = Animation.spring(duration: 0.32, bounce: 0.18)
}

/// Colours for text. The brand's amber and sky are made to be seen as shapes:
/// dots, tints, icons. As text on the light glass card they are about 1.5 to
/// 1.9 to 1 against it (4.5 to 1 is the least for small text), so error and
/// help text read as faint. These keep the same hue, a good deal darker when
/// the screen is light. In dark mode, and on the sheets that are always dark,
/// they are the brand colours as they were.
extension Brand {
    /// Apricot for text: about 5 to 1 or better on the light glass card.
    static let warningText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.92, green: 0.72, blue: 0.47, alpha: 1)
            : UIColor(red: 0.50, green: 0.33, blue: 0.10, alpha: 1)
    })

    /// Mist blue for text.
    static let skyText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.78, blue: 0.86, alpha: 1)
            : UIColor(red: 0.20, green: 0.38, blue: 0.47, alpha: 1)
    })

    /// Sage for text and links.
    static let accentText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.78, blue: 0.74, alpha: 1)
            : UIColor(red: 0.22, green: 0.39, blue: 0.37, alpha: 1)
    })
}

extension View {
    /// A Liquid Glass surface (iOS 26+), or a frosted material before that.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 28, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.materialSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        }
        #else
        self.materialSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        #endif
    }

    /// Capsule-shaped glass, for pills and floating controls.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .capsule)
        } else {
            self.materialSurface(Capsule(), tint: tint)
        }
        #else
        self.materialSurface(Capsule(), tint: tint)
        #endif
    }

    /// Circular glass, for icon buttons.
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.materialSurface(Circle(), tint: tint)
        }
        #else
        self.materialSurface(Circle(), tint: tint)
        #endif
    }

    private func materialSurface<S: InsettableShape>(_ shape: S, tint: Color?) -> some View {
        self
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill((tint ?? .clear).opacity(0.22))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    /// The big call-to-action: glass prominent, tinted.
    @ViewBuilder
    func prominentButton(tint: Color = Brand.indigo) -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
        } else {
            self.buttonStyle(ProminentFallbackStyle(tint: tint))
        }
        #else
        self.buttonStyle(ProminentFallbackStyle(tint: tint))
        #endif
    }

    /// Secondary actions: plain glass.
    @ViewBuilder
    func glassButton() -> some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(GlassFallbackStyle())
        }
        #else
        self.buttonStyle(GlassFallbackStyle())
        #endif
    }
}

/// Groups neighbouring glass shapes so they blend and morph together on
/// iOS 26; just the content before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct ProminentFallbackStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    .padding(1.5)
            }
            .shadow(color: tint.opacity(configuration.isPressed ? 0.2 : 0.45), radius: configuration.isPressed ? 6 : 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Brand.snappy, value: configuration.isPressed)
    }
}

struct GlassFallbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Brand.snappy, value: configuration.isPressed)
    }
}

/// A rounded gradient square with a white symbol, like Settings icons.
struct IconTile: View {
    let symbol: String
    var colors: [Color] = [Brand.indigo, Brand.sky]
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)      // decoration: the words beside it say it
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.6)
            }
            .frame(width: size, height: size)
            .shadow(color: (colors.last ?? .black).opacity(0.3), radius: size * 0.12, y: size * 0.05)
    }
}

/// A dot with a soft, repeating ripple: "this is live".
struct PulsingDot: View {
    var color: Color = Brand.live
    var size: CGFloat = 9
    @State private var ripple = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                // The ripple is the motion. With Reduce Motion on, the dot stands alone.
                Circle()
                    .fill(color.opacity(0.5))
                    .scaleEffect(ripple ? 2.8 : 1)
                    .opacity(reduceMotion ? 0 : (ripple ? 0 : 0.9))
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { ripple = true }
            }
    }
}

/// The animated night-sky background of the intro and pairing screens:
/// a slowly drifting mesh gradient on iOS 18+, layered glows before that.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Paused with Reduce Motion on: the sky stays as it was drawn at first.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            if #available(iOS 18.0, *) {
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors)
                    .ignoresSafeArea()
            } else {
                ZStack {
                    Brand.night
                    Circle().fill(Brand.violet.opacity(0.35)).frame(width: 420).blur(radius: 90)
                        .offset(x: -120 + 40 * cos(t / 5), y: -260 + 30 * sin(t / 4))
                    Circle().fill(Brand.sky.opacity(0.3)).frame(width: 380).blur(radius: 90)
                        .offset(x: 140 + 30 * sin(t / 6), y: 220 + 40 * cos(t / 5))
                    Circle().fill(Brand.indigo.opacity(0.4)).frame(width: 340).blur(radius: 80)
                        .offset(x: 60 * cos(t / 7), y: 40 * sin(t / 6))
                }
                .ignoresSafeArea()
            }
        }
    }

    private static let colors: [Color] = [
        Brand.night, Color(red: 0.16, green: 0.24, blue: 0.24), Brand.night,
        Color(red: 0.19, green: 0.25, blue: 0.30), Color(red: 0.27, green: 0.40, blue: 0.38), Color(red: 0.26, green: 0.25, blue: 0.34),
        Brand.night, Color(red: 0.24, green: 0.33, blue: 0.37), Color(red: 0.08, green: 0.11, blue: 0.12),
    ]

    private static func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func wobble(_ base: Float, _ speed: Double, _ amount: Float) -> Float {
            base + amount * Float(sin(t * speed))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            SIMD2(0, wobble(0.5, 0.31, 0.08)), SIMD2(wobble(0.5, 0.23, 0.12), wobble(0.5, 0.29, 0.1)), SIMD2(1, wobble(0.5, 0.27, 0.08)),
            SIMD2(0, 1), SIMD2(wobble(0.5, 0.19, 0.1), 1), SIMD2(1, 1),
        ]
    }
}

extension AnyTransition {
    /// Fade, blur and settle into place.
    static var rise: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .scale(scale: 0.98)))
    }
}
