import PhoneOnlyCore
import XCTest

final class WaitDurationTests: XCTestCase {
    private func seconds(_ text: String) -> Double? {
        if case .wait(let s) = WaitDuration.parse(text) { return s }
        return nil
    }

    func testABareNumberIsMinutes() {
        XCTAssertEqual(seconds("30"), 1800)
        XCTAssertEqual(seconds(" 5 "), 300)
        XCTAssertEqual(seconds("1.5"), 90)
        XCTAssertEqual(seconds("0"), 0)
    }

    func testUnitsInManySpellings() {
        XCTAssertEqual(seconds("45s"), 45)
        XCTAssertEqual(seconds("45 sec"), 45)
        XCTAssertEqual(seconds("45 seconds"), 45)
        XCTAssertEqual(seconds("20m"), 1200)
        XCTAssertEqual(seconds("20 min"), 1200)
        XCTAssertEqual(seconds("20 Minutes"), 1200)
        XCTAssertEqual(seconds("2h"), 7200)
        XCTAssertEqual(seconds("2 hr"), 7200)
        XCTAssertEqual(seconds("2 hours"), 7200)
        XCTAssertEqual(seconds("1.5h"), 5400)
        XCTAssertEqual(seconds("90 min"), 5400)
    }

    func testCombinations() {
        XCTAssertEqual(seconds("1h 30m"), 5400)
        XCTAssertEqual(seconds("1h30m"), 5400)
        XCTAssertEqual(seconds("1 hour 30 minutes"), 5400)
        XCTAssertEqual(seconds("1h30"), 5400)        // a bare number after hours is minutes
        XCTAssertEqual(seconds("5m30"), 330)         // and after minutes, seconds
        XCTAssertEqual(seconds("1 h, 15 min"), 4500)
        XCTAssertEqual(seconds("2 hours and 5 minutes"), 7500)
    }

    func testClockStyle() {
        XCTAssertEqual(seconds("1:30"), 5400)        // h:mm
        XCTAssertEqual(seconds("0:45"), 2700)
        XCTAssertEqual(seconds("1:02:03"), 3723)     // h:mm:ss
    }

    func testWords() {
        XCTAssertEqual(seconds("half an hour"), 1800)
        XCTAssertEqual(seconds("half hour"), 1800)
        XCTAssertEqual(seconds("an hour"), 3600)
        XCTAssertEqual(seconds("a minute"), 60)
        XCTAssertEqual(seconds("no wait"), 0)
        XCTAssertEqual(seconds("none"), 0)
    }

    func testADecimalCommaIsADecimal() {
        XCTAssertEqual(seconds("0,5 h"), 1800)
        XCTAssertEqual(seconds("1,5"), 90)            // minutes
        XCTAssertEqual(seconds("1,5h"), 5400)
        XCTAssertEqual(seconds("1 h, 15 min"), 4500)  // a comma with a space after it still separates
        XCTAssertEqual(seconds("1h,15m"), 4500)
    }

    func testWhatAnEditorStartsWithReadsBackAsTheSameWait() {
        for value: Double in [0, 1, 45, 59, 60, 61, 90, 300, 1800, 3599, 3600, 3601, 3723, 5400, 7200, 86_399, 86_400]
            + WaitDuration.presets {
            XCTAssertEqual(WaitDuration.parse(WaitDuration.format(value)), .wait(value), "\(value) s")
        }
    }

    func testRoundsToWholeSeconds() {
        XCTAssertEqual(seconds("0.51"), 31)   // 30.6 s
    }

    func testUnreadableInput() {
        for text in ["", "   ", "soon", "abc min", "-5", "5 -m", "1:75", "1:2:3:4", "h", "30 parsecs", "1e400",
                     "nan", "inf", "5..5", "1h h", "m30"] {
            XCTAssertEqual(WaitDuration.parse(text), .unreadable, "\"\(text)\" should be unreadable")
        }
    }

    func testLongerThanTheMaximum() {
        XCTAssertEqual(WaitDuration.parse("25h"), .tooLong)
        XCTAssertEqual(WaitDuration.parse("1441"), .tooLong)      // minutes
        XCTAssertEqual(WaitDuration.parse("99999999999999999999 h"), .tooLong)
        XCTAssertEqual(seconds("24h"), 24 * 3600)
        XCTAssertEqual(WaitDuration.maxSeconds, 24 * 3600)
    }

    func testFormat() {
        XCTAssertEqual(WaitDuration.format(0), "No wait")
        XCTAssertEqual(WaitDuration.format(45), "45 sec")
        XCTAssertEqual(WaitDuration.format(60), "1 min")
        XCTAssertEqual(WaitDuration.format(90), "1 min 30 sec")
        XCTAssertEqual(WaitDuration.format(1800), "30 min")
        XCTAssertEqual(WaitDuration.format(3600), "1 h")
        XCTAssertEqual(WaitDuration.format(5400), "1 h 30 min")
        XCTAssertEqual(WaitDuration.format(3723), "1 h 2 min 3 sec")
        XCTAssertEqual(WaitDuration.format(3605), "1 h 5 sec")
        XCTAssertEqual(WaitDuration.format(.nan), "No wait")
        XCTAssertEqual(WaitDuration.format(-5), "No wait")
        XCTAssertEqual(WaitDuration.format(1e300), "24 h")         // never a crash on a silly number
    }

    func testShortFormatForMapPins() {
        XCTAssertEqual(WaitDuration.short(45), "45s")
        XCTAssertEqual(WaitDuration.short(1800), "30m")
        XCTAssertEqual(WaitDuration.short(5400), "1h30")
        XCTAssertEqual(WaitDuration.short(7200), "2h")
        XCTAssertEqual(WaitDuration.short(0), "")
    }

    func testCountdown() {
        XCTAssertEqual(WaitDuration.countdown(0), "0:00")
        XCTAssertEqual(WaitDuration.countdown(5.2), "0:06")        // rounds up: it never shows 0:00 early
        XCTAssertEqual(WaitDuration.countdown(1781), "29:41")
        XCTAssertEqual(WaitDuration.countdown(3723), "1:02:03")
        XCTAssertEqual(WaitDuration.countdown(.infinity), "0:00")
        XCTAssertEqual(WaitDuration.countdown(-3), "0:00")
    }

    func testWhatATypedValueReadsBackAs() {
        // What the editor shows back under the field.
        XCTAssertEqual(WaitDuration.parse("1h30").description, "1 h 30 min")
        XCTAssertEqual(WaitDuration.parse("25h").description, "That's longer than 24 hours.")
        XCTAssertEqual(WaitDuration.parse("soon").description, "Type a time like 20, 45 min or 1h 30m.")
    }

    func testPresetsAreSortedAndInRange() {
        XCTAssertEqual(WaitDuration.presets, WaitDuration.presets.sorted())
        XCTAssertTrue(WaitDuration.presets.allSatisfy { $0 >= 0 && $0 <= WaitDuration.maxSeconds })
        XCTAssertEqual(WaitDuration.presets.first, 0)
    }
}

final class SpeedUnitsTests: XCTestCase {
    private let mph = SpeedUnits(imperial: true)
    private let kmh = SpeedUnits(imperial: false)

    func testLabels() {
        XCTAssertEqual(mph.label, "mph")
        XCTAssertEqual(kmh.label, "km/h")
    }

    func testConversionRoundTrips() {
        XCTAssertEqual(mph.display(kmh: 48.28032), 30, accuracy: 1e-6)
        XCTAssertEqual(mph.kmh(fromDisplay: 30), 48.28032, accuracy: 1e-6)
        XCTAssertEqual(kmh.display(kmh: 50), 50)
        XCTAssertEqual(kmh.kmh(fromDisplay: 50), 50)
        for value in stride(from: 1.0, through: 75, by: 0.5) {
            XCTAssertEqual(mph.display(kmh: mph.kmh(fromDisplay: value)), value, accuracy: 1e-9)
        }
    }

    func testRouteSliderRangesAreInTheShownUnit() {
        XCTAssertEqual(mph.routeRange(driving: true), 5...75)
        XCTAssertEqual(mph.routeStep(driving: true), 5)
        XCTAssertEqual(mph.routeRange(driving: false), 1...6)
        XCTAssertEqual(mph.routeStep(driving: false), 0.5)
        XCTAssertEqual(kmh.routeRange(driving: true), 10...120)
        XCTAssertEqual(kmh.routeStep(driving: true), 5)
        XCTAssertEqual(kmh.routeRange(driving: false), 1...10)
        XCTAssertEqual(kmh.routeStep(driving: false), 1)
    }

    func testDefaultsSitOnTheSlidersSteps() {
        for units in [mph, kmh] {
            for driving in [true, false] {
                let shown = units.display(kmh: units.defaultKmh(driving: driving))
                let range = units.routeRange(driving: driving), step = units.routeStep(driving: driving)
                XCTAssertTrue(range.contains(shown))
                XCTAssertEqual((shown - range.lowerBound).truncatingRemainder(dividingBy: step), 0, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(mph.display(kmh: mph.defaultKmh(driving: true)), 30, accuracy: 1e-9)
        XCTAssertEqual(kmh.defaultKmh(driving: true), 50)
    }

    func testText() {
        XCTAssertEqual(mph.text(kmh: 48.28032), "30 mph")
        XCTAssertEqual(mph.text(kmh: mph.kmh(fromDisplay: 2.5)), "2.5 mph")    // walking steps are halves
        XCTAssertEqual(kmh.text(kmh: 50), "50 km/h")
        XCTAssertEqual(mph.text(metersPerSecond: 13.4112), "30 mph")
        XCTAssertEqual(kmh.text(metersPerSecond: .nan), "0 km/h")
        XCTAssertEqual(mph.text(kmh: 1e300), "9999 mph")       // never a crash on a silly number
    }

    func testJoystickRange() {
        XCTAssertEqual(mph.joystickRange, 1...75)
        XCTAssertEqual(kmh.joystickRange, 1...120)
    }

    func testRegions() {
        XCTAssertTrue(SpeedUnits(region: .us).imperial)
        XCTAssertTrue(SpeedUnits(region: .uk).imperial)       // UK road speeds are in mph
        XCTAssertFalse(SpeedUnits(region: .metric).imperial)
    }

    func testAPickedUnitBeatsTheRegion() {
        XCTAssertFalse(SpeedUnits.resolve(.automatic, region: .metric).imperial)   // a metric phone: km unless picked
        XCTAssertTrue(SpeedUnits.resolve(.automatic, region: .us).imperial)
        XCTAssertTrue(SpeedUnits.resolve(.miles, region: .metric).imperial)
        XCTAssertFalse(SpeedUnits.resolve(.kilometers, region: .us).imperial)
        XCTAssertEqual(UnitsChoice(rawValue: "miles"), .miles)                     // what @AppStorage saves
    }

    func testDistanceTextFollowsTheUnitNotTheRegion() {
        let us = Locale(identifier: "en_US"), germany = Locale(identifier: "de_DE")
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }
        XCTAssertEqual(plain(mph.distanceText(meters: 3_057.7, locale: us)), "1.9 mi")
        XCTAssertEqual(plain(mph.distanceText(meters: 482.8, locale: us)), "0.3 mi")
        XCTAssertEqual(plain(mph.distanceText(meters: 152.4, locale: us)), "500 ft")
        XCTAssertEqual(plain(mph.distanceText(meters: 19_312, locale: us)), "12 mi")
        XCTAssertEqual(plain(kmh.distanceText(meters: 850, locale: us)), "850 m")
        XCTAssertEqual(plain(kmh.distanceText(meters: 1_900, locale: us)), "1.9 km")
        XCTAssertEqual(plain(kmh.distanceText(meters: 12_400, locale: us)), "12 km")
        XCTAssertEqual(plain(mph.distanceText(meters: 3_057.7, locale: germany)), "1,9 mi")   // miles on a German phone
        XCTAssertEqual(plain(mph.distanceText(meters: .nan, locale: us)), "0 ft")
    }
}

final class RouteWaitTextTests: XCTestCase {
    func testWaitingAtTheStartIsADepartureCountdown() {
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: 1781), "Leaving in 29:41")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: nil), "Waiting to leave")
    }

    func testRestStopsCountFromOneLikeThePins() {
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 1, remaining: 723), "Resting at stop 2 · 12:03 left")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 1, remaining: nil), "Resting at stop 2")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: nil, remaining: 60), "Resting · 1:00 left")
    }

    func testTrafficStops() {
        XCTAssertEqual(RouteWaitText.describe(reason: "light", stop: nil, remaining: 25.2), "Red light · 0:26")
        XCTAssertEqual(RouteWaitText.describe(reason: "sign", stop: nil, remaining: 2), "Stop sign")
        XCTAssertEqual(RouteWaitText.describe(reason: "yield", stop: nil, remaining: nil), "Giving way")
        XCTAssertEqual(RouteWaitText.describe(reason: "break", stop: nil, remaining: 300), "Taking a break · 5:00")
        XCTAssertEqual(RouteWaitText.describe(reason: "arrived", stop: nil, remaining: nil), "Arrived")
        XCTAssertNil(RouteWaitText.describe(reason: "something new", stop: nil, remaining: 5))   // an older iPhone shows progress instead
    }

    func testPausedKeepsTheCountdownForYourOwnStops() {
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: 1781, paused: true), "Paused · leaves in 29:41")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 2, remaining: 60, paused: true), "Paused · 1:00 left at stop 3")
        XCTAssertNil(RouteWaitText.describe(reason: "light", stop: nil, remaining: 20, paused: true))
    }

    func testAStopNumberFromTheNetworkIsChecked() {
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: Int.max, remaining: 60), "Resting · 1:00 left")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: -1, remaining: 60), "Resting · 1:00 left")
    }

    func testASillyTimeLeftNeverCrashes() {
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: .infinity), "Leaving in 0:00")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: -4), "Leaving in 0:00")
        XCTAssertEqual(RouteWaitText.describe(reason: "stop", stop: 0, remaining: 1e300), "Leaving in 24:00:00")
    }
}
