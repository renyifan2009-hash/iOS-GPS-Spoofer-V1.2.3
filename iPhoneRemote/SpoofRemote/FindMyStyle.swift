import SwiftUI

// The pieces of the main screen, in the style of Apple's Find My: the map fills the screen, a floating
// panel with a grabber holds a large title and the list or the details, a tab bar runs along the
// panel's bottom, and the map's own buttons sit in a glass stack at the top right.

/// How far the panel is pulled up.
enum PanelDetent: CaseIterable {
    /// Just the title and the tab bar.
    case collapsed
    case medium
    case large
}

/// The main screen's tabs.
enum MainTab: Hashable, CaseIterable {
    case teleport, route, joystick, me

    var title: String {
        switch self {
        case .teleport: "Teleport"
        case .route: "Route"
        case .joystick: "Joystick"
        case .me: "Me"
        }
    }

    var symbol: String {
        switch self {
        case .teleport: "mappin.and.ellipse"
        case .route: "point.topleft.down.to.point.bottomright.curvepath.fill"
        case .joystick: "gamecontroller.fill"
        case .me: "person.crop.circle"
        }
    }
}

/// Find My's floating panel: a grabber and a header you drag to change its height, the content under
/// them (scrolling past the height it has), and the tab bar along the bottom.
struct FindMyPanel<Header: View, Content: View, Footer: View>: View {
    @Binding var detent: PanelDetent
    /// The screen's height, which the detents are fractions of.
    let screenHeight: CGFloat
    /// The medium detent, as a fraction of the screen.
    var mediumFraction: CGFloat = 0.46
    /// The home indicator's room, kept free under the tab bar.
    var bottomInset: CGFloat = 0
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    @GestureState private var drag: CGFloat = 0
    @State private var headerHeight: CGFloat = 96
    @State private var footerHeight: CGFloat = 64

    private func height(_ detent: PanelDetent) -> CGFloat {
        // (The footer's height already has the home indicator's room under the tabs.)
        let collapsed = headerHeight + footerHeight
        switch detent {
        case .collapsed: return collapsed
        case .medium: return max(collapsed + 120, screenHeight * mediumFraction)
        case .large: return max(collapsed + 160, screenHeight * 0.86)
        }
    }

    var body: some View {
        let current = min(height(.large), max(height(.collapsed), height(detent) - drag))
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 36, height: 5)
                    .padding(.top, 7)
                    .accessibilityHidden(true)
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .gesture(dragGesture)
            .accessibilityAction(named: "Expand") { withAnimation(Brand.spring) { step(up: true) } }
            .accessibilityAction(named: "Collapse") { withAnimation(Brand.spring) { step(up: false) } }

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .opacity(detent == .collapsed && drag >= 0 ? 0 : 1)
            // Folded away is gone for VoiceOver too.
            .accessibilityHidden(detent == .collapsed)

            footer
                .padding(.bottom, max(6, bottomInset - 14))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(height: current, alignment: .top)
        .frame(maxWidth: .infinity)
        // Find My's sheet is nearly solid: the map only tints its edges, and the text stays easy to read.
        .background {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.78))
        }
        .glassSurface(cornerRadius: 36)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .animation(Brand.spring, value: detent)
        // The middle height changes with the tab (and when steering starts): it moves, it doesn't jump.
        .animation(Brand.spring, value: mediumFraction)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                // Where the panel would end up with its momentum, then the nearest detent to that.
                let target = height(detent) - value.predictedEndTranslation.height
                let nearest = PanelDetent.allCases.min { abs(height($0) - target) < abs(height($1) - target) } ?? detent
                withAnimation(Brand.spring) { detent = nearest }
            }
    }

    private func step(up: Bool) {
        let all = PanelDetent.allCases
        guard let index = all.firstIndex(of: detent) else { return }
        detent = all[max(0, min(all.count - 1, index + (up ? 1 : -1)))]
    }
}

/// The tab bar along the panel's bottom: icon over label, the chosen one in the accent colour.
struct PanelTabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 20)
            HStack(spacing: 0) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(Brand.snappy) { selection = tab }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 21, weight: .semibold))
                                .frame(height: 26)
                                .accessibilityHidden(true)
                            Text(tab.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(selection == tab ? Brand.sky : Color.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        // Four tabs fit in a row up to the first accessibility size, as in Apple's own tab bars.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Find My's action tiles: a rounded square with an icon in a circle at the top and a word under it.
/// The main action is filled; the others are light.
struct ActionTile: View {
    let symbol: String
    let title: String
    var fill: Color? = nil
    var iconColor: Color = Brand.sky
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle().fill(fill == nil ? iconColor.opacity(0.16) : Color.white.opacity(0.95))
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(fill ?? iconColor)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(fill == nil ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(fill.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color(.secondarySystemFill)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(TilePressStyle())
    }
}

/// A little give when a tile is pressed.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Brand.snappy, value: configuration.isPressed)
    }
}

/// The map's buttons, stacked in glass at the top right as in Find My: the map style, then where iOS
/// says this iPhone is.
struct MapControlStack: View {
    @Binding var hybrid: Bool
    let showsLocation: Bool
    let toggleLocation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Brand.snappy) { hybrid.toggle() }
            } label: {
                Image(systemName: hybrid ? "map.fill" : "map")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(hybrid ? "Show the standard map" : "Show the satellite map")
            Divider().frame(width: 28)
            Button(action: toggleLocation) {
                Image(systemName: showsLocation ? "location.fill" : "location")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(showsLocation ? Brand.sky : Color.primary)
                    .frame(width: 46, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Show where iOS says this iPhone is")
            .accessibilityValue(showsLocation ? "On" : "Off")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassSurface(cornerRadius: 23)
    }
}

/// A list row like Find My's: a round icon, the name in bold with a line under it, and something on
/// the right.
struct PanelPlaceRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.gradient)
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A rounded card of rows, like Find My's settings groups.
struct GroupedCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemFill))
        }
    }
}

/// A row in a `GroupedCard`: an icon, a title, an optional value, and a chevron when it opens something.
struct PanelRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    var valueColor: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.sky)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A round button in the panel's header, like Find My's ✕ and +.
struct PanelHeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(.secondarySystemFill)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
