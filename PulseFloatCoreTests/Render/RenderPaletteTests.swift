import CoreGraphics
import PulseFloatCore
import XCTest

final class RenderPaletteTests: XCTestCase {
    func testAuroraStopsInterpolationAndClamping() {
        let palette = Palette(.aurora)
        XCTAssertEqual(palette.color(at: 0), RGB(red: 33, green: 230, blue: 193))
        XCTAssertEqual(palette.color(at: 0.25), RGB(red: 46, green: 193, blue: 224))
        XCTAssertEqual(palette.color(at: 0.5), RGB(red: 58, green: 155, blue: 255))
        XCTAssertEqual(palette.color(at: 1), RGB(red: 163, green: 92, blue: 255))
        XCTAssertEqual(palette.color(at: -1), palette.color(at: 0))
        XCTAssertEqual(palette.color(at: 2), palette.color(at: 1))
    }

    func testOtherPaletteEndpoints() {
        let endpoints: [(PaletteID, RGB, RGB)] = [
            (.ember, RGB(red: 255, green: 210, blue: 63), RGB(red: 255, green: 45, blue: 135)),
            (.glacier, RGB(red: 234, green: 247, blue: 255), RGB(red: 76, green: 111, blue: 255)),
            (.mono, RGB(red: 255, green: 255, blue: 255), RGB(red: 152, green: 161, blue: 180)),
            (.lab, RGB(red: 242, green: 238, blue: 228), RGB(red: 226, green: 240, blue: 150)),
            (.sakura, RGB(red: 255, green: 224, blue: 233), RGB(red: 199, green: 125, blue: 255)),
            (.sunset, RGB(red: 255, green: 183, blue: 3), RGB(red: 131, green: 56, blue: 236)),
            (.matcha, RGB(red: 233, green: 245, blue: 219), RGB(red: 45, green: 106, blue: 79)),
            (.neotokyo, RGB(red: 0, green: 245, blue: 212), RGB(red: 155, green: 93, blue: 229)),
            (.graphite, RGB(red: 245, green: 245, blue: 245), RGB(red: 58, green: 58, blue: 58))
        ]
        XCTAssertEqual(PaletteID.allCases.count, 10, "原本 4 組 + 新增 6 組")
        for (id, start, end) in endpoints {
            XCTAssertEqual(Palette(id).color(at: 0), start)
            XCTAssertEqual(Palette(id).color(at: 1), end)
        }
    }

    func testCGColorUsesSRGBAndRequestedAlpha() throws {
        let color = Palette(.aurora).color(at: 0).cgColor(alpha: 0.4)
        XCTAssertEqual(color.colorSpace?.name, CGColorSpace.sRGB)
        let components = try XCTUnwrap(color.components)
        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(components[0], 33.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(components[1], 230.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(components[2], 193.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(components[3], 0.4, accuracy: 1e-6)
    }
}
