import PhoneOnlyCore
import RemoteAPI
import SwiftUI

/// A numbered pin for a route waypoint on the map, with how long it waits there.
struct RouteStopPin: View {
    let number: Int
    var wait: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.sky.gradient)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            if wait > 0 {
                Label(WaitDuration.short(wait), systemImage: "pause.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Brand.indigo))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: 15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wait > 0 ? "Stop \(number), waits \(WaitDuration.format(wait))" : "Stop \(number)")
    }
}

/// Short, locale-aware text for lengths and times.
enum RouteText {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return total < 60 ? "under a minute" : "\(max(1, m)) min"
    }

    /// Mph or km/h, by region.
    static func speed(_ metersPerSecond: Double) -> String {
        SpeedUnits.current.text(metersPerSecond: metersPerSecond)
    }

    /// "45 sec", "30 min", "1 h 30 min".
    static func wait(_ seconds: Double) -> String { WaitDuration.format(seconds) }
}

// MARK: - Build a route

/// Build a route on the map, then send it to the Mac to drive.
struct RouteCardView: View {
    @Bindable var route: RouteDraft
    var connection: any ControlTarget
    var library: RouteLibrary

    @State private var showStops = false
    @State private var showHistory = false
    @State private var editStartWait = false
    @State private var askName = false
    @State private var nameText = ""

    private var units: SpeedUnits { .current }

    /// The slider moves in the shown unit (5 mph steps where miles are used); the route keeps km/h.
    private var speedInShownUnits: Binding<Double> {
        Binding(get: { units.display(kmh: route.speedKmh) },
                set: { route.speedKmh = units.kmh(fromDisplay: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if route.canDrive {
                summary
                options
            }
            toolRow
        }
        .animation(Brand.spring, value: route.stops.count)
        .animation(Brand.spring, value: route.driving)
        .sheet(isPresented: $showStops) {
            RouteStopsSheet(route: route)
        }
        .sheet(isPresented: $showHistory) {
            RouteHistorySheet(route: route, library: library)
        }
        .sheet(isPresented: $editStartWait) {
            WaitEditorSheet(title: "Leave after", prompt: "How long to wait at the start before leaving.",
                            initial: route.startWait, zeroLabel: "Leave now") { seconds in
                withAnimation(Brand.snappy) { route.setStartWait(seconds) }
            }
        }
        .alert("Save this route", isPresented: $askName) {
            TextField("Name", text: $nameText)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved routes stay on this iPhone and are listed under Saved.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.stops.isEmpty ? "Build a route"
                     : route.name ?? "\(route.stops.count) stop\(route.stops.count == 1 ? "" : "s")")
                    .font(Brand.rounded(.title3))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(route.canDrive ? "Tap the map to add more, or drive it."
                     : route.canAddStop ? "Tap the map to add points (two or more)."
                     : "That's the most stops a route can have.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !route.stops.isEmpty {
                Button {
                    withAnimation(Brand.snappy) { route.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove the last stop")
                Button {
                    withAnimation(Brand.snappy) { route.clear() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.danger)
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the route")
            }
        }
    }

    /// How long it is and about how long it takes. The Mac plans the real roads, so this is the least.
    private var summary: some View {
        HStack(spacing: 14) {
            Label(RouteText.distance(route.straightLineMeters), systemImage: "ruler")
            if let seconds = route.roughSeconds {
                Label(RouteText.duration(seconds) == "under a minute" ? "under a minute" : "about \(RouteText.duration(seconds))",
                      systemImage: "clock")
            }
            if route.restCount > 0 {
                Label("\(route.restCount) rest\(route.restCount == 1 ? "" : "s")", systemImage: "pause.circle")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            leaveRow
            if route.startWait > 0, macIsTooOldToWait {
                Label("This Mac's AnyWhere is too old to wait before leaving. Update it, or the route leaves right away.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Travel", selection: Binding(get: { route.driving }, set: { driving in
                guard driving != route.driving else { return }
                route.driving = driving
                route.speedKmh = units.defaultKmh(driving: driving)   // a walk's pace for a walk, a drive's for a drive
            })) {
                Text("Driving").tag(true)
                Text("Walking").tag(false)
            }
            .pickerStyle(.segmented)

            Picker("Repeat", selection: $route.repeats) {
                ForEach(RouteDraft.Repeat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Follow roads & paths", isOn: $route.followRoads)
            Toggle(route.driving ? "Drive like a real person" : "Walk like a real person", isOn: $route.natural)
            if route.driving, connection.executionName == "Mac" {
                Toggle("Slower in rush hour", isOn: $route.timeOfDayTraffic)
            }

            HStack(spacing: 12) {
                Text("Speed")
                Slider(value: speedInShownUnits, in: units.routeRange(driving: route.driving),
                       step: units.routeStep(driving: route.driving))
                    .accessibilityLabel("Top speed")
                    .accessibilityValue(units.text(kmh: route.speedKmh))
                Text(units.text(kmh: route.speedKmh))
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
        }
        .font(.subheadline)
    }

    /// A Mac before protocol version 2 drives a one-way route straight off, whatever the start's wait says.
    private var macIsTooOldToWait: Bool {
        guard let status = connection.status else { return false }   // not heard from yet: don't guess
        return (status.apiVersion ?? 1) < 2
    }

    /// When to leave the start: now, or after a wait you type ("leave in half an hour").
    private var leaveRow: some View {
        Button {
            editStartWait = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: route.startWait > 0 ? "clock.badge.checkmark" : "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.indigo)
                    .frame(width: 22)
                Text("Leave")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(route.startWait > 0 ? "in \(RouteText.wait(route.startWait))" : "Now")
                    .foregroundStyle(route.startWait > 0 ? Brand.indigo : Color.secondary)
                    .fontWeight(route.startWait > 0 ? .semibold : .regular)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Leave")
        .accessibilityValue(route.startWait > 0 ? "after \(RouteText.wait(route.startWait))" : "now")
        .accessibilityHint("Wait at the start for a while before the route sets off")
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            toolButton("Stops", symbol: "list.number", enabled: !route.stops.isEmpty) { showStops = true }
            toolButton("Save", symbol: "bookmark", enabled: route.canDrive) {
                nameText = route.name ?? ""
                askName = true
            }
            toolButton("Saved", symbol: "clock.arrow.circlepath", enabled: true) { showHistory = true }
        }
    }

    private func toolButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func save() {
        guard let saved = library.save(route.snapshot(named: nameText)) else { return }
        route.name = saved.name
    }
}

// MARK: - While it drives

/// A route that is driving: how far along, and pause, resume or stop.
struct RouteProgressCardView: View {
    var route: RouteDraft
    var connection: any ControlTarget

    private var status: RemoteStatus? { connection.status }
    private var planning: Bool { status?.activity == "planning" }
    private var paused: Bool { status?.routePaused ?? false }
    /// Waiting at one of your stops (the start included), as opposed to a light or a sign.
    private var restingAtStop: Bool { status?.routeWait?.reason == "stop" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: planning ? "map.fill"
                            : (paused ? "pause.fill"
                                : (restingAtStop ? "clock.fill" : "point.topleft.down.to.point.bottomright.curvepath.fill")),
                         colors: paused ? [Brand.warning, Brand.warning.opacity(0.7)] : [Brand.indigo, Brand.sky], size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name ?? "Route").font(Brand.rounded(.title3)).lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                AutoStopRow(connection: connection, compact: true)
            }
            if planning {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if let progress = status?.routeProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(paused ? Brand.warning : Brand.indigo)
                    .accessibilityLabel("Route progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            }
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { await connection.setPaused(!paused) }
                    } label: {
                        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(planning || connection.isWorking)
                    Button {
                        Task { await connection.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                }
            }
            .disabled(connection.isWorking && !planning)
        }
        .animation(Brand.spring, value: paused)
        .animation(Brand.spring, value: planning)
    }

    private var subtitle: String {
        if planning { return "Planning the route on the \(connection.executionName)…" }
        if let wait = status?.routeWait,
           let text = RouteWaitText.describe(reason: wait.reason, stop: wait.stop, remaining: wait.remaining,
                                             paused: paused) {
            return text
        }
        var parts: [String] = []
        if let progress = status?.routeProgress { parts.append("\(Int((progress * 100).rounded()))%") }
        if paused {
            parts.append("paused")
        } else if let speed = status?.speed, speed > 0.1 {
            parts.append(RouteText.speed(speed))
        }
        return parts.isEmpty ? "Driving" : parts.joined(separator: " · ")
    }
}
