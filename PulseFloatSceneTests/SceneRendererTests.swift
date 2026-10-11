import PulseFloatCore
import PulseFloatScene
import XCTest

/// 三個 SceneKit 主題的共同契約：畫得出東西、靜音時逐像素靜止並回報 isAtRest、
/// 所有風格／畫質／呈現方式都能套用、CPU 每幀工作量有上限。
@MainActor
final class SceneRendererTests: XCTestCase {
    private static let themes: [ThemeID] = [.blackHole, .particleSphere, .terrain]
    private let width = 520, height = 200
    private let dt = 1.0 / 60

    private func makeRenderer(_ theme: ThemeID, _ settings: SceneSettings = SceneSettings()) throws -> SceneRenderer {
        let renderer = try XCTUnwrap(SceneRenderer(), "這台機器沒有 Metal 裝置")
        renderer.setTheme(theme, settings: settings)
        XCTAssertNotNil(renderer.theme, "\(theme) 應該是 SceneKit 主題")
        return renderer
    }

    private func play(_ renderer: SceneRenderer, _ audio: DemoAudio, seconds: Double, program: DemoAudio.Program) {
        audio.program = program
        let end = audio.seconds + seconds
        while audio.seconds < end { renderer.advance(frame: audio.next(dt: dt), dt: dt) }
    }

    func testNonSceneThemesHaveNoSceneTheme() throws {
        let renderer = try XCTUnwrap(SceneRenderer())
        renderer.setTheme(.bars, settings: SceneSettings())
        XCTAssertNil(renderer.theme)
        XCTAssertNil(renderer.renderOffscreen(frame: .silent(bandCount: 64), dt: dt, width: 10, height: 10))
        XCTAssertTrue(ThemeID.blackHole.isScene && ThemeID.particleSphere.isScene && ThemeID.terrain.isScene)
        XCTAssertFalse(ThemeID.mobius.isScene)
    }

    func testEveryThemeDrawsInBothPresentationsWithMusic() throws {
        for theme in Self.themes {
            for presentation in ScenePresentation.allCases {
                let renderer = try makeRenderer(theme, SceneSettings(presentation: presentation))
                let audio = DemoAudio(seed: 5)
                play(renderer, audio, seconds: 2, program: .music)
                let image = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
                XCTAssertGreaterThan(image.visibleRatio, 0.02, "\(theme) \(presentation)")
                XCTAssertGreaterThan(image.timing.gpuMs, 0)
            }
        }
    }

    func testMusicChangesTheImageOverTime() throws {
        for theme in Self.themes {
            let renderer = try makeRenderer(theme)
            let audio = DemoAudio(seed: 8)
            play(renderer, audio, seconds: 1, program: .music)
            let a = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
            play(renderer, audio, seconds: 0.37, program: .music)
            let b = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
            XCTAssertFalse(a.pixels == b.pixels, "\(theme) 播放音樂時畫面應該隨聲音改變")
        }
    }

    func testSilenceAfterMusicIsPixelStaticAndReportsRest() throws {
        for theme in Self.themes {
            for presentation in ScenePresentation.allCases {
                let renderer = try makeRenderer(theme, SceneSettings(presentation: presentation))
                let audio = DemoAudio(seed: 9)
                play(renderer, audio, seconds: 3, program: .music)
                XCTAssertFalse(renderer.isAtRest, "\(theme) 播放中不應該回報靜止")
                play(renderer, audio, seconds: 4, program: .silence)
                XCTAssertTrue(renderer.isAtRest, "\(theme) \(presentation) 靜音 4 秒後應該靜止")
                let a = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
                play(renderer, audio, seconds: 0.5, program: .silence)
                let b = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
                XCTAssertTrue(a.pixels == b.pixels, "\(theme) \(presentation) 靜音時畫面仍在變")
                XCTAssertGreaterThan(a.visibleRatio, 0.005, "\(theme) 靜音時保留靜止的畫面，不是全空")
            }
        }
    }

    func testEveryStyleQualityAndPaletteApplies() throws {
        for theme in Self.themes {
            let renderer = try makeRenderer(theme)
            let audio = DemoAudio(seed: 2)
            play(renderer, audio, seconds: 1, program: .music)
            for quality in RenderQuality.allCases {
                for style in SculptureStyle.allCases {
                    renderer.apply(SceneSettings(style: style, palette: .neotokyo, presentation: .sculpture, quality: quality))
                    let image = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 260, height: 100))
                    XCTAssertGreaterThan(image.visibleRatio, 0.01, "\(theme) \(quality) \(style)")
                }
            }
        }
    }

    func testMalformedFramesAndDegenerateSizesAreSafe() throws {
        let frames = [
            SpectrumFrame(values: [], peaks: [], bass: 0),
            SpectrumFrame(values: [1], peaks: [1], bass: 1),
            SpectrumFrame(values: [Float](repeating: .nan, count: 64), peaks: [Float](repeating: .infinity, count: 64), bass: .nan),
        ]
        for theme in Self.themes {
            let renderer = try makeRenderer(theme)
            for frame in frames {
                for step in [0, dt, 5, -1, .nan] {
                    renderer.advance(frame: frame, dt: step)
                }
                XCTAssertNil(renderer.renderOffscreen(frame: frame, dt: dt, width: 0, height: 10))
                XCTAssertNotNil(renderer.renderOffscreen(frame: frame, dt: dt, width: 8, height: 4))
            }
        }
    }

    func testUserCameraChangesTheImageEvenWhenSilent() throws {
        for theme in Self.themes {
            let renderer = try makeRenderer(theme, SceneSettings(presentation: .sculpture))
            let audio = DemoAudio(seed: 6)
            play(renderer, audio, seconds: 1, program: .music)
            play(renderer, audio, seconds: 4, program: .silence)
            let before = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
            renderer.setUserCamera(yaw: 40, pitch: 10, zoom: 1.2)
            let after = try XCTUnwrap(renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height))
            XCTAssertFalse(before.pixels == after.pixels, "\(theme) 使用者鏡頭操作應該改變畫面")
            XCTAssertTrue(renderer.isAtRest, "鏡頭操作不會讓主題離開靜止狀態")
        }
    }

    /// Debug build 的寬鬆上限；Release 數字由 PulseFloatShots --perf 量。
    func testCPUWorkPerFrameIsBounded() throws {
        for theme in Self.themes {
            let renderer = try makeRenderer(theme, SceneSettings(quality: .high))
            let audio = DemoAudio(seed: 4)
            play(renderer, audio, seconds: 1, program: .music)
            // 第一次繪製會編譯 shader／建立 pipeline，不計入每幀預算。
            _ = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 1040, height: 400)
            var total = 0.0
            var i = 0
            while i < 60 {
                _ = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: 1040, height: 400)
                total += renderer.timing.cpuMs
                i += 1
            }
            let average = total / 60
            print("SceneRendererTests \(theme): CPU \(String(format: "%.2f", average)) ms/frame (Debug, update + encode)")
            XCTAssertLessThan(average, 8, "\(theme)")
        }
    }
}
