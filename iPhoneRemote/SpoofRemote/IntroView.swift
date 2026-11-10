import SwiftUI

/// First-launch introduction: three pages over a drifting aurora, each with
/// its own choreographed entrance. Ends by offering to pair with the Mac.
struct IntroView: View {
    /// `true` when the person tapped "Find My Mac".
    var onFinish: (_ pairNow: Bool) -> Void

    @State private var page = 0
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pageCount = 3

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < pageCount - 1 {
                        Button("Skip") { onFinish(false) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .glassCapsule(interactive: true)
                            .transition(.opacity)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 20)

                // A page that doesn't fit (a small iPhone, large text) scrolls. The dots and
                // buttons below stay where they are, so the intro can always be left.
                IntroPageScroll {
                    ZStack {
                        switch page {
                        case 0: WelcomePage().transition(pageTransition)
                        case 1: HowItWorksPage().transition(pageTransition)
                        default: ConnectPage().transition(pageTransition)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Beside the scroll view's own gesture, so a swipe sideways still turns the page.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -60 { go(to: page + 1) }
                        if value.translation.width > 60 { go(to: page - 1) }
                    })

                VStack(spacing: 18) {
                    PageDots(count: pageCount, current: page)
                    GlassGroup(spacing: 10) {
                        VStack(spacing: 10) {
                            Button {
                                if page == pageCount - 1 { onFinish(true) } else { go(to: page + 1) }
                            } label: {
                                Text(page == pageCount - 1 ? "Find My Mac" : "Continue")
                                    .contentTransition(.opacity)
                                    .frame(maxWidth: .infinity)
                            }
                            .prominentButton()
                            if page == pageCount - 1 {
                                Button {
                                    onFinish(false)
                                } label: {
                                    Text("Later").frame(maxWidth: .infinity)
                                }
                                .glassButton()
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                // The buttons stay on screen. At the very largest sizes they would take
                // half of it and leave a few lines for the page.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: page)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to target: Int) {
        guard target >= 0, target < pageCount, target != page else { return }
        forward = target > page
        withAnimation(.spring(duration: 0.55, bounce: 0.18)) { page = target }
    }
}

// MARK: - Pages

/// The area for a page. A page that fits is centred in it, as before. One that
/// doesn't (an iPhone SE, or Larger Text) scrolls instead of being cut off or
/// overlapping the buttons.
private struct IntroPageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .environment(\.introPageHeight, proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private extension EnvironmentValues {
    /// How tall the area for a page is, so a picture can give way on a small screen.
    @Entry var introPageHeight: CGFloat = 600
}

private struct WelcomePage: View {
    @State private var shown = false
    @Environment(\.introPageHeight) private var pageHeight

    /// The globe takes what the words leave, between 150 and 280 points.
    private var globe: CGFloat { min(280, max(150, pageHeight - 300)) }

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            HeroGlobe()
                .frame(width: globe, height: globe)
            VStack(spacing: 10) {
                Text("Your iPhone.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .reveal(shown, order: 3)
                Text("Anywhere.")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [Brand.live, Brand.violet,
                                 Brand.sky],
                        startPoint: .leading, endPoint: .trailing))
                    .reveal(shown, order: 4)
                Text("Pick a place on this phone. Your Mac, or this iPhone on its own, moves its location there. Stop, and the real GPS comes straight back.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 6)
                    .reveal(shown, order: 5)
            }
            Spacer(minLength: 0)
        }
        .onAppear { shown = true }
    }
}

private struct HowItWorksPage: View {
    @State private var shown = false
    @Environment(\.introPageHeight) private var pageHeight

    /// An iPhone SE has about 480 points for a page. Everything gets a little tighter there.
    private var compact: Bool { pageHeight < 600 }

    var body: some View {
        VStack(spacing: compact ? 14 : 28) {
            Spacer(minLength: 0)
            LinkDiagram()
                .frame(height: compact ? 96 : 120)
                .padding(.horizontal, 30)
                .reveal(shown, order: 0)
            VStack(spacing: 8) {
                Text("Your Mac does the work")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .reveal(shown, order: 1)
                Text("iOS doesn't let an app change where the whole phone thinks it is. Your Mac can, through Apple's developer tools, the same way Xcode does. This app is its remote. With a pairing file from your Mac, this iPhone can also do it on its own.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .reveal(shown, order: 2)
            }
            VStack(spacing: compact ? 8 : 12) {
                FeatureRow(symbol: "magnifyingglass", colors: [Brand.indigo, Brand.sky],
                           title: "Search or tap the map", text: "Addresses, landmarks or exact coordinates.")
                    .reveal(shown, order: 3)
                FeatureRow(symbol: "bolt.fill", colors: [Brand.live.opacity(0.8), Brand.live],
                           title: "Moves in an instant", text: "The Mac keeps one live channel to the phone.")
                    .reveal(shown, order: 4)
                FeatureRow(symbol: "arrow.uturn.backward.circle.fill", colors: [Brand.pin[0], Brand.danger],
                           title: "Stop restores everything", text: "Your real location returns right away.")
                    .reveal(shown, order: 5)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .onAppear { shown = true }
    }
}

private struct ConnectPage: View {
    @State private var shown = false
    @Environment(\.introPageHeight) private var pageHeight

    private var compact: Bool { pageHeight < 600 }

    var body: some View {
        VStack(spacing: compact ? 14 : 26) {
            Spacer(minLength: 0)
            // The lock is decoration. On an iPhone SE the room is better spent on the steps.
            if pageHeight >= 520 {
                ZStack {
                    Circle().fill(Brand.gradient).frame(width: compact ? 60 : 96, height: compact ? 60 : 96)
                        .shadow(color: Brand.indigo.opacity(0.7), radius: 30, y: 10)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: compact ? 26 : 42, weight: .semibold))
                        .symbolEffect(.bounce, value: shown)
                }
                .accessibilityHidden(true)
                .reveal(shown, order: 0)
            }
            VStack(spacing: 8) {
                Text("Connect once")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .reveal(shown, order: 1)
                Text("Pair with a one-time code. Only your paired iPhone can control the Mac, and only on your own network.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .reveal(shown, order: 2)
            }
            VStack(spacing: 0) {
                StepRow(number: 1, text: "Plug the iPhone into the Mac and tap **Trust**.")
                    .reveal(shown, order: 3)
                Divider().overlay(.white.opacity(0.12)).padding(.leading, 56)
                StepRow(number: 2, text: "On the Mac, open **AnyWhere ▸ Settings ▸ iPhone Remote** and turn it on.")
                    .reveal(shown, order: 4)
                Divider().overlay(.white.opacity(0.12)).padding(.leading, 56)
                StepRow(number: 3, text: "Enter the **6-digit code** the Mac shows.")
                    .reveal(shown, order: 5)
            }
            .padding(.vertical, 6)
            .glassSurface(cornerRadius: 26)
            .padding(.horizontal, 24)
            // What comes next, before it comes: iOS asks about the local network when the
            // search for the Mac starts. And the way for people with no Mac at hand.
            VStack(spacing: 6) {
                Text("iOS will ask to find devices on your local network. Tap Allow.")
                Text("No Mac nearby? Tap Later, then choose This iPhone.")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .reveal(shown, order: 6)
            Spacer(minLength: 0)
        }
        .onAppear { shown = true }
    }
}

// MARK: - Hero

/// A slowly turning globe, a dotted route drawing itself in, and the pin
/// dropping onto its destination with a squash and a bounce.
private struct HeroGlobe: View {
    @State private var drop = 0
    @State private var routeDrawn: CGFloat = 0
    @State private var ripples = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct PinMotion {
        var offset: Double = 0
        var squash: Double = 1
        var opacity: Double = 1
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Brand.indigo.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 150))
                .blur(radius: 10)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                Globe(phase: context.date.timeIntervalSinceReferenceDate * 0.25)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .padding(24)

            // The route: dots from lower left to the pin.
            RouteCurve()
                .trim(from: 0, to: routeDrawn)
                .stroke(Brand.routeGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.1, 12]))
                .shadow(color: Brand.sky.opacity(0.6), radius: 6)

            // Ripples where the pin lands.
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Ellipse()
                        .stroke(.white.opacity(0.5), lineWidth: 2)
                        .frame(width: 46, height: 14)
                        .scaleEffect(ripples ? 3.2 : 0.6)
                        .opacity(ripples ? 0 : 0.8)
                        .animation(.easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(Double(index) * 0.7),
                                   value: ripples)
                }
            }
            .offset(x: 34, y: 58)

            BrandPin()
                .frame(width: 74, height: 96)
                .keyframeAnimator(initialValue: PinMotion(), trigger: drop) { content, motion in
                    content
                        .scaleEffect(x: 2 - motion.squash, y: motion.squash, anchor: .bottom)
                        .offset(y: motion.offset)
                        .opacity(motion.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.offset) {
                        MoveKeyframe(-260)
                        CubicKeyframe(-260, duration: 0.18)
                        CubicKeyframe(0, duration: 0.42)
                        SpringKeyframe(-30, duration: 0.22, spring: .bouncy)
                        SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                    }
                    KeyframeTrack(\.squash) {
                        LinearKeyframe(1, duration: 0.6)
                        CubicKeyframe(0.74, duration: 0.07)
                        SpringKeyframe(1.0, duration: 0.55, spring: .bouncy)
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0)
                        LinearKeyframe(0, duration: 0.15)
                        LinearKeyframe(1, duration: 0.2)
                    }
                }
                .offset(x: 34, y: 10)
        }
        .onAppear {
            guard !reduceMotion else {
                routeDrawn = 1
                return
            }
            drop += 1
            withAnimation(.easeInOut(duration: 1.3).delay(0.75)) { routeDrawn = 1 }
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                ripples = true
            }
        }
    }
}

/// The app's pin: a white teardrop with a gradient lens.
private struct BrandPin: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .top) {
                PinShape()
                    .fill(LinearGradient(colors: [.white, Color(red: 0.86, green: 0.89, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Brand.night.opacity(0.6), radius: 14, y: 10)
                Circle()
                    .fill(LinearGradient(colors: [Brand.violet, Brand.indigo, Brand.sky],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: w * 0.44, height: w * 0.44)
                    .padding(.top, w * 0.28)
            }
        }
    }
}

/// A map-pin teardrop: round head, pointed tip at the bottom.
struct PinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let center = CGPoint(x: rect.midX, y: r)
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        var path = Path()
        path.move(to: tip)
        path.addCurve(to: CGPoint(x: rect.minX, y: r),
                      control1: CGPoint(x: rect.midX - r * 0.35, y: rect.maxY - r * 0.55),
                      control2: CGPoint(x: rect.minX, y: r + r * 0.75))
        path.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: tip,
                      control1: CGPoint(x: rect.maxX, y: r + r * 0.75),
                      control2: CGPoint(x: rect.midX + r * 0.35, y: rect.maxY - r * 0.55))
        path.closeSubpath()
        return path
    }
}

/// Latitude/longitude lines; `phase` turns the meridians.
private struct Globe: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for index in 0..<6 {
            let angle = phase + Double(index) * Double.pi / 6
            let half = r * CGFloat(abs(cos(angle)))
            path.addEllipse(in: CGRect(x: c.x - half, y: c.y - r, width: 2 * half, height: 2 * r))
        }
        for k: CGFloat in [-0.66, -0.33, 0, 0.33, 0.66] {
            let y = c.y + r * k
            let half = r * (1 - k * k).squareRoot()
            path.move(to: CGPoint(x: c.x - half, y: y))
            path.addLine(to: CGPoint(x: c.x + half, y: y))
        }
        return path
    }
}

private struct RouteCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.86))
        path.addCurve(to: CGPoint(x: rect.midX + 26, y: rect.midY + 64),
                      control1: CGPoint(x: rect.width * 0.22, y: rect.height * 0.46),
                      control2: CGPoint(x: rect.width * 0.42, y: rect.height * 0.92))
        return path
    }
}

// MARK: - How it works diagram

/// iPhone ⇄ Mac with packets of light travelling between them.
private struct LinkDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midY = proxy.size.height / 2
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: width - 150, height: 3)
                    .position(x: width / 2, y: midY)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let progress = (t * 0.45 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .fill(index == 1 ? Brand.live : Brand.sky)
                                .frame(width: 9, height: 9)
                                .shadow(color: (index == 1 ? Brand.live : Brand.sky).opacity(0.9), radius: 8)
                                .opacity(sin(progress * Double.pi))
                                .position(x: 75 + (width - 150) * CGFloat(index == 1 ? 1 - progress : progress), y: midY)
                        }
                    }
                }
                Endpoint(symbol: "iphone", label: "This iPhone")
                    .position(x: 40, y: midY)
                Endpoint(symbol: "laptopcomputer", label: "Your Mac")
                    .position(x: width - 40, y: midY)
            }
        }
    }

    private struct Endpoint: View {
        let symbol: String
        let label: String

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 72, height: 72)
                    .glassCircle(tint: Brand.indigo)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
            }
        }
    }
}

// MARK: - Small pieces

private struct FeatureRow: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, colors: colors, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
            // Wrap, don't cut the line short: the page scrolls if it needs the room.
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassSurface(cornerRadius: 22)
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 30, height: 30)
                .background(Brand.gradient, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.3))
                    .frame(width: index == current ? 24 : 7, height: 7)
            }
        }
        .animation(Brand.spring, value: current)
    }
}

/// Staggered entrance: rise, sharpen and fade in, one element after another.
private struct Reveal: ViewModifier {
    let visible: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 18)
            .blur(radius: visible || reduceMotion ? 0 : 8)
            .animation(.spring(duration: 0.75, bounce: 0.22).delay(0.1 + Double(order) * 0.08), value: visible)
    }
}

private extension View {
    func reveal(_ visible: Bool, order: Int) -> some View {
        modifier(Reveal(visible: visible, order: order))
    }
}
