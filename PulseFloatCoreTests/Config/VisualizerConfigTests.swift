import CoreFoundation
import Foundation
import PulseFloatCore
import XCTest

final class VisualizerConfigTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prototype-defaults", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func decode(_ json: String) throws -> VisualizerConfig {
        try JSONDecoder().decode(VisualizerConfig.self, from: Data(json.utf8))
    }

    private func modifiedConfig() -> VisualizerConfig {
        VisualizerConfig(
            bands: .init(count: 96, fMinHz: 50, fMaxHz: 18000, tiltDbPerOct: 2),
            level: .init(agc: false, rangeDb: 60, ceilingDb: -20, agcReleaseDbPerSec: 10, gamma: 1.8, gateDb: -100),
            motion: .init(attackMs: 30, releaseMs: 250, spatial: 0.5, peakHoldMs: 200, peakGravity: 4),
            look: .init(theme: .radial, palette: .ember, mirror: true, reflection: false, barGap: 0.4, windowMode: .bare, opacity: 0.7),
            menubar: .init(style: .dots, count: 9, colored: true)
        )
    }

    private func jsonSemanticallyEqual(_ actual: Any, _ expected: Any) -> Bool {
        switch (actual, expected) {
        case let (actual as [String: Any], expected as [String: Any]):
            guard actual.count == expected.count else { return false }
            for (key, value) in actual {
                guard let expectedValue = expected[key], jsonSemanticallyEqual(value, expectedValue) else {
                    return false
                }
            }
            return true
        case let (actual as [Any], expected as [Any]):
            guard actual.count == expected.count else { return false }
            for index in actual.indices {
                guard jsonSemanticallyEqual(actual[index], expected[index]) else { return false }
            }
            return true
        case let (actual as NSNumber, expected as NSNumber):
            let actualIsBoolean = CFGetTypeID(actual) == CFBooleanGetTypeID()
            let expectedIsBoolean = CFGetTypeID(expected) == CFBooleanGetTypeID()
            return actualIsBoolean == expectedIsBoolean && actual.compare(expected) == .orderedSame
        case let (actual as String, expected as String):
            return actual == expected
        case (_ as NSNull, _ as NSNull):
            return true
        default:
            return false
        }
    }

    func testEncodedDefaultsMatchPrototypeSemantically() throws {
        let encoded = try JSONEncoder().encode(VisualizerConfig.default)
        let actual = try JSONSerialization.jsonObject(with: encoded)
        let expected = try JSONSerialization.jsonObject(with: fixtureData())
        XCTAssertTrue(jsonSemanticallyEqual(actual, expected))
    }

    func testJSONSemanticComparisonDistinguishesBooleansFromNumbers() throws {
        for (boolean, number) in [("true", "1"), ("false", "0")] {
            let actual = try JSONSerialization.jsonObject(with: Data("{\"nested\":[\(boolean)]}".utf8))
            let expected = try JSONSerialization.jsonObject(with: Data("{\"nested\":[\(number)]}".utf8))
            XCTAssertFalse(jsonSemanticallyEqual(actual, expected))
            XCTAssertFalse(jsonSemanticallyEqual(expected, actual))
            XCTAssertTrue(jsonSemanticallyEqual(actual, actual))
        }
        let integer = try JSONSerialization.jsonObject(with: Data(#"{"nested":[3]}"#.utf8))
        let decimal = try JSONSerialization.jsonObject(with: Data(#"{"nested":[3.0]}"#.utf8))
        XCTAssertTrue(jsonSemanticallyEqual(integer, decimal))
    }

    func testDecodePrototypeDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(VisualizerConfig.self, from: fixtureData()), .default)
    }

    func testPartialJSONPreservesDefaults() throws {
        var expected = VisualizerConfig.default
        expected.look.theme = .neon
        XCTAssertEqual(try decode(#"{"look":{"theme":"neon"}}"#), expected)
    }

    func testEveryGroupFillsMissingFields() throws {
        var expected = VisualizerConfig.default
        expected.bands.count = 32
        expected.level.agc = false
        expected.motion.attackMs = 20
        expected.look.mirror = true
        expected.menubar.colored = true
        XCTAssertEqual(try decode("""
            {"bands":{"count":32},"level":{"agc":false},"motion":{"attackMs":20},
             "look":{"mirror":true},"menubar":{"colored":true}}
            """), expected)
    }

    func testUnknownEnumsAndKeysUseFieldDefaults() throws {
        var expected = VisualizerConfig.default
        expected.look.palette = .ember
        expected.look.mirror = true
        expected.look.opacity = 0.5
        expected.menubar.count = 5
        expected.menubar.colored = true
        XCTAssertEqual(try decode("""
            {"future":true,"bands":{"future":1},"level":{"future":{}},
             "motion":{"future":[]},"look":{"theme":"plasma","palette":"ember","mirror":true,
             "windowMode":"glass","opacity":0.5,"future":"ignored"},
             "menubar":{"style":"wave","count":5,"colored":true,"future":null}}
            """), expected)

        expected = .default
        expected.look.theme = .neon
        XCTAssertEqual(try decode(#"{"look":{"theme":"neon","palette":"rainbow"}}"#), expected)
    }

    func testEmptyObjectsAndNullsUseDefaults() throws {
        XCTAssertEqual(try decode("{}"), .default)
        XCTAssertEqual(try decode(#"{"bands":{},"level":{},"motion":{},"look":{},"menubar":{}}"#), .default)
        XCTAssertEqual(try decode(#"{"bands":null,"level":{"gamma":null},"look":{"theme":null}}"#), .default)
    }

    func testDecodeDoesNotClampAndAcceptsIntegerLiteralsForDoubles() throws {
        let result = try decode(#"{"bands":{"count":1,"tiltDbPerOct":3},"level":{"gamma":99},"look":{"opacity":-2}}"#)
        XCTAssertEqual(result.bands.count, 1)
        XCTAssertEqual(result.bands.tiltDbPerOct, 3)
        XCTAssertEqual(result.level.gamma, 99)
        XCTAssertEqual(result.look.opacity, -2)
    }

    func testMismatchedJSONTypesUseFieldDefaults() throws {
        var expected = VisualizerConfig.default
        expected.bands.fMinHz = 40
        XCTAssertEqual(try decode(#"{"bands":{"count":"64","fMinHz":40}}"#), expected)

        expected = .default
        expected.look.palette = .ember
        XCTAssertEqual(try decode(#"{"look":{"theme":42,"palette":"ember"}}"#), expected)

        expected = .default
        expected.bands.count = 32
        XCTAssertEqual(try decode(#"{"look":5,"bands":{"count":32}}"#), expected)

        XCTAssertEqual(try decode(#"{"bands":{"count":64.5}}"#), .default)
    }

    func testNonObjectTopLevelJSONThrows() {
        XCTAssertThrowsError(try decode("[]"))
        XCTAssertThrowsError(try decode(#""x""#))
    }

    func testAllDoubleClampBounds() {
        let cases: [(WritableKeyPath<VisualizerConfig, Double>, Double, Double)] = [
            (\.bands.fMinHz, 20, 120),
            (\.bands.fMaxHz, 6000, 20000),
            (\.bands.tiltDbPerOct, 0, 6),
            (\.level.rangeDb, 24, 84),
            (\.level.ceilingDb, -40, 0),
            (\.level.agcReleaseDbPerSec, 1, 20),
            (\.level.gamma, 0.6, 2.4),
            (\.level.gateDb, -160, -30),
            (\.motion.attackMs, 2, 80),
            (\.motion.releaseMs, 40, 600),
            (\.motion.spatial, 0, 0.8),
            (\.motion.peakHoldMs, 0, 600),
            (\.motion.peakGravity, 0.5, 10),
            (\.look.barGap, 0.05, 0.6),
            (\.look.opacity, 0.3, 1)
        ]
        for (keyPath, lower, upper) in cases {
            var config = VisualizerConfig.default
            config[keyPath: keyPath] = lower - 1
            XCTAssertEqual(config.clamped()[keyPath: keyPath], lower, "Lower bound: \(keyPath)")
            XCTAssertEqual(config[keyPath: keyPath], lower - 1, "clamped() must not mutate its input")
            config[keyPath: keyPath] = upper + 1
            XCTAssertEqual(config.clamped()[keyPath: keyPath], upper, "Upper bound: \(keyPath)")
            config[keyPath: keyPath] = (lower + upper) / 2
            XCTAssertEqual(config.clamped()[keyPath: keyPath], config[keyPath: keyPath])
            config[keyPath: keyPath] = .nan
            XCTAssertEqual(config.clamped()[keyPath: keyPath], VisualizerConfig.default[keyPath: keyPath])
            config[keyPath: keyPath] = -.infinity
            XCTAssertEqual(config.clamped()[keyPath: keyPath], lower)
            config[keyPath: keyPath] = .infinity
            XCTAssertEqual(config.clamped()[keyPath: keyPath], upper)
        }
    }

    func testCountRoundingAndIntegerBounds() {
        let cases = [(62, 64), (65, 64), (66, 68), (8, 16), (200, 128), (Int.min, 16), (Int.max, 128)]
        for (input, expected) in cases {
            var config = VisualizerConfig.default
            config.bands.count = input
            XCTAssertEqual(config.clamped().bands.count, expected)
        }
        for (input, expected) in [(4, 5), (10, 9), (Int.min, 5), (Int.max, 9)] {
            var config = VisualizerConfig.default
            config.menubar.count = input
            XCTAssertEqual(config.clamped().menubar.count, expected)
        }
    }

    func testClampPreservesDefaultsAndFrequencyConstraint() {
        XCTAssertEqual(VisualizerConfig.default.clamped(), .default)
        var config = VisualizerConfig.default
        config.bands.fMinHz = 100000
        config.bands.fMaxHz = -1
        let result = config.clamped()
        XCTAssertGreaterThanOrEqual(result.bands.fMaxHz, result.bands.fMinHz * 4)
        XCTAssertEqual(result.clamped(), result)
    }

    func testModifiedConfigRoundTrip() throws {
        let config = modifiedConfig()
        XCTAssertEqual(try JSONDecoder().decode(VisualizerConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testClampPreservesEveryInRangeAndNonNumericField() {
        let config = modifiedConfig()
        XCTAssertEqual(config.clamped(), config)
    }

    func testEveryKnownEnumValueDecodes() throws {
        for theme in ThemeID.allCases {
            XCTAssertEqual(try decode("{\"look\":{\"theme\":\"\(theme.rawValue)\"}}").look.theme, theme)
        }
        for palette in PaletteID.allCases {
            XCTAssertEqual(try decode("{\"look\":{\"palette\":\"\(palette.rawValue)\"}}").look.palette, palette)
        }
        for mode in WindowMode.allCases {
            XCTAssertEqual(try decode("{\"look\":{\"windowMode\":\"\(mode.rawValue)\"}}").look.windowMode, mode)
        }
        for style in MenuBarStyle.allCases {
            XCTAssertEqual(try decode("{\"menubar\":{\"style\":\"\(style.rawValue)\"}}").menubar.style, style)
        }
    }
}

final class ThemeSelectionTests: XCTestCase {
    func testAnalysisIsMergedIntoMobius() {
        var config = VisualizerConfig()
        config.look.theme = .analysis
        XCTAssertEqual(config.clamped().look.theme, .mobius)
        XCTAssertFalse(ThemeID.selectable.contains(.analysis))
        XCTAssertTrue(ThemeID.selectable.contains(.mobius))
        XCTAssertEqual(ThemeID.selectable.count, ThemeID.allCases.count - 1)
    }

    func testThemeCapabilitiesDriveTheMenu() {
        XCTAssertTrue(ThemeID.radial.showsCenterArtwork && ThemeID.blackHole.showsCenterArtwork)
        XCTAssertFalse(ThemeID.terrain.showsCenterArtwork || ThemeID.bars.showsCenterArtwork)
        XCTAssertTrue(ThemeID.mobius.usesSculptureStyle && ThemeID.particleSphere.usesSculptureStyle)
        XCTAssertFalse(ThemeID.radial.usesSculptureStyle || ThemeID.orbit.usesSculptureStyle)
    }
}
