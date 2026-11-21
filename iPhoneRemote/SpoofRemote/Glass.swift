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
    // Find My's colours: the system blue for actions and selection, green for what's running ("Now"),
    // orange for things to check, red for Stop. They follow light and dark mode and Increase Contrast by
    // themselves. (The names are the old ones, so every view picked the new palette up at once.)
    /// The main accent: the system blue.
    static let indigo = Color(.systemBlue)
    static let violet = Color(.systemIndigo)
    /// The second accent: the system blue as well, so actions look the same everywhere.
    static let sky = Color(.systemBlue)
    /// Live / ready: the system green, Find My's "Now".
    static let live = Color(.systemGreen)
    static let warning = Color(.systemOrange)
    /// Stop and errors.
    static let danger = Color(.systemRed)
    /// Behind sheets: the system's grouped background, like Find My's.
    static let night = Color(.systemGroupedBackground)
    /// Pins: the system red.
    static let pin = [Color(.systemRed), Color(red: 0.80, green: 0.16, blue: 0.14)]

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var routeGradient: LinearGradient {
        LinearGradient(colors: [live, indigo, sky], startPoint: .leading, endPoint: .trailing)
    }

    /// Titles: bold SF Pro, as Find My's are. (It was SF Rounded once, hence the name.)
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .default, weight: weight)
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
    /// Orange for text: the system orange is made for shapes and reads faint as small text on white, so
    /// light mode uses a darker orange (about 5 to 1).
    static let warningText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemOrange
            : UIColor(red: 0.62, green: 0.31, blue: 0.0, alpha: 1)
    })

    /// Green for text ("Ready", "Now"): the system green is about 2 to 1 on white, so light mode uses a
    /// darker green (about 5 to 1).
    static let liveText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGreen
            : UIColor(red: 0.0, green: 0.48, blue: 0.16, alpha: 1)
    })

    /// Blue for text.
    static let skyText = Color(.systemBlue)

    /// Blue for text and links, as in Find My.
    static let accentText = Color(.systemBlue)
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

    /// A solid card, the way Find My's sheets group things: white on the gray background (dark gray in
    /// dark mode), or lightly tinted for something to check. Glass is for what floats over the map.
    func cardSurface(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
        }
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
            // Find My's second buttons: a gray capsule with blue words.
            self.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
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

/// Behind the intro, setup and pairing screens: the system's grouped background, as Find My's sheets
/// have (white in light mode, black in dark).
struct AuroraBackground: View {
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
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
