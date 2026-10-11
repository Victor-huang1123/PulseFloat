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
            (.mono, RGB(red: 255, green: 255, blue: 255), RGB(red: 152, green: 161, blue: 180))
        ]
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
