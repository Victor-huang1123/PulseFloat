import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PulseFloatCore
import PulseFloatScene
import UniformTypeIdentifiers

// PulseFloatShots：用真正的 SceneRenderer 產生設計探索截圖與效能數據。
// 用法：PulseFloatShots <輸出資料夾> [--themes blackhole,particles,terrain] [--style porcelain] [--styles] [--perf] [--quick]
// 截圖：每個主題一張總表（列：精簡/雕塑 × 深色/淺色桌布；欄：主歌、副歌拍點、靜音），以及各別 PNG。
// 效能：每個主題 × 畫質 × 呈現方式，量 CPU update、CPU encode、GPU（離屏，等 GPU 完成，精確到該幀）。

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: PulseFloatShots <outDir> [--themes a,b] [--style name] [--styles] [--perf] [--quick]")
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let themes: [ThemeID] = (option("--themes") ?? "blackhole,particles,terrain").split(separator: ",").compactMap { ThemeID(rawValue: String($0)) }
let baseStyle = option("--style").flatMap(SculptureStyle.init(rawValue:))
let quick = arguments.contains("--quick")
let width = 1040, height = 400
let dt = 1.0 / 60

let darkTop = RGB(red: 30, green: 36, blue: 54), darkBottom = RGB(red: 9, green: 11, blue: 19)
let lightTop = RGB(red: 243, green: 241, blue: 236), lightBottom = RGB(red: 216, green: 212, blue: 204)

func defaultStyle(_ theme: ThemeID) -> SculptureStyle {
    if let baseStyle { return baseStyle }
    switch theme {
    case .blackHole: return .amber
    case .particleSphere: return .aurora
    default: return .porcelain
    }
}

func save(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func label(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 22, dark: Bool = true) {
    let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let color = dark ? CGColor(gray: 1, alpha: 0.85) : CGColor(gray: 0, alpha: 0.75)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

/// 把 rows × cols 張圖拼成一張（CG 座標原點在左下，第一列放最上面）。
func sheet(_ cells: [[CGImage?]], captions: [[String]], cellWidth: Int, cellHeight: Int) -> CGImage? {
    let rows = cells.count, cols = cells.first?.count ?? 0
    let gap = 8
    let w = cols * cellWidth + (cols + 1) * gap, h = rows * cellHeight + (rows + 1) * gap
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    var r = 0
    while r < rows {
        var c = 0
        while c < cols {
            let x = gap + c * (cellWidth + gap), y = h - (r + 1) * (cellHeight + gap)
            if let image = cells[r][c] {
                ctx.draw(image, in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
            let caption = captions[r][c]
            label(ctx, caption, x: CGFloat(x + 14), y: CGFloat(y + 14), dark: !caption.contains("淺色"))
            c += 1
        }
        r += 1
    }
    return ctx.makeImage()
}

struct Capture {
    var verse: SceneImage?
    var chorus: SceneImage?
    var silent: SceneImage?
    var staticInSilence = false
    var restReported = false
}

/// 跑一段示範音樂並在主歌、副歌拍點、靜音三個時間點截圖。
@MainActor
func capture(_ theme: ThemeID, presentation: ScenePresentation, style: SculptureStyle, quality: RenderQuality = .high) -> Capture {
    var result = Capture()
    guard let renderer = SceneRenderer() else { return result }
    renderer.setTheme(theme, settings: SceneSettings(style: style, palette: .aurora, presentation: presentation, quality: quality,
                                                     aspect: Double(width) / Double(height)))
    let audio = DemoAudio(seed: 7)
    audio.program = .music
    func advance(to seconds: Double) {
        while audio.seconds < seconds - 1e-6 { renderer.advance(frame: audio.next(dt: dt), dt: dt) }
    }
    advance(to: 4.26)
    result.verse = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height)
    advance(to: 12.53)
    result.chorus = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height)
    audio.program = .silence
    let silenceEnd = audio.seconds + 4
    while audio.seconds < silenceEnd { renderer.advance(frame: audio.next(dt: dt), dt: dt) }
    result.silent = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height)
    result.restReported = renderer.isAtRest
    let again = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height)
    result.staticInSilence = again?.pixels == result.silent?.pixels
    return result
}

var report: [String] = ["# PulseFloat 3D themes — design exploration", ""]

for theme in themes {
    let style = defaultStyle(theme)
    var cells: [[CGImage?]] = []
    var captions: [[String]] = []
    for presentation in [ScenePresentation.compact, .sculpture] {
        let shot = capture(theme, presentation: presentation, style: style)
        report.append("- \(theme.rawValue) \(presentation.rawValue) \(style.rawValue): silence static = \(shot.staticInSilence), isAtRest = \(shot.restReported)")
        for (bgName, top, bottom) in [("深色桌布", darkTop, darkBottom), ("淺色桌布", lightTop, lightBottom)] {
            let images = [shot.verse, shot.chorus, shot.silent].map { $0?.composited(top: top, bottom: bottom) }
            cells.append(images)
            let mode = presentation == .compact ? "精簡" : "雕塑"
            captions.append(["\(mode)·\(bgName)·主歌", "\(mode)·\(bgName)·副歌拍點", "\(mode)·\(bgName)·靜音"])
            let suffix = "\(theme.rawValue)-\(presentation.rawValue)-\(bgName == "深色桌布" ? "dark" : "light")"
            if let chorus = images[1] { save(chorus, "\(suffix)-chorus.png") }
            if let silent = images[2] { save(silent, "\(suffix)-silent.png") }
        }
    }
    if let image = sheet(cells, captions: captions, cellWidth: width / 2, cellHeight: height / 2) {
        save(image, "\(theme.rawValue)-sheet.png")
    }
    print("wrote \(theme.rawValue)-sheet.png")

    if arguments.contains("--styles") {
        var styleCells: [[CGImage?]] = [[], []]
        var styleCaptions: [[String]] = [[], []]
        for (index, s) in SculptureStyle.allCases.enumerated() {
            let shot = capture(theme, presentation: .compact, style: s, quality: .medium)
            styleCells[index / 4].append(shot.chorus?.composited(top: darkTop, bottom: darkBottom))
            styleCaptions[index / 4].append(s.rawValue)
        }
        if let image = sheet(styleCells, captions: styleCaptions, cellWidth: width / 2, cellHeight: height / 2) {
            save(image, "\(theme.rawValue)-styles.png")
        }
        print("wrote \(theme.rawValue)-styles.png")
    }
}

if arguments.contains("--perf") {
    report.append("")
    report.append("## Performance (\(width)×\(height) px, offscreen, median / p95 ms)")
    report.append("")
    report.append("| theme | quality | presentation | CPU update | CPU encode | CPU total | GPU | silent CPU |")
    report.append("|---|---|---|---|---|---|---|---|")
    var json: [[String: Any]] = []
    func stats(_ values: [Double]) -> (Double, Double) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return (0, 0) }
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }
    for theme in themes {
        for quality in RenderQuality.allCases {
            for presentation in [ScenePresentation.compact, .sculpture] {
                guard let renderer = SceneRenderer() else { continue }
                renderer.setTheme(theme, settings: SceneSettings(style: defaultStyle(theme), palette: .aurora, presentation: presentation,
                                                                 quality: quality, aspect: Double(width) / Double(height)))
                let audio = DemoAudio(seed: 3)
                audio.program = .music
                var warm = 0
                while warm < 180 { renderer.advance(frame: audio.next(dt: dt), dt: dt); warm += 1 }
                var update: [Double] = [], encode: [Double] = [], total: [Double] = [], gpu: [Double] = []
                let frames = quick ? 60 : 240
                var i = 0
                while i < frames {
                    if let image = renderer.renderOffscreen(frame: audio.next(dt: dt), dt: dt, width: width, height: height) {
                        update.append(image.timing.cpuUpdateMs)
                        encode.append(image.timing.cpuEncodeMs)
                        total.append(image.timing.cpuMs)
                        gpu.append(image.timing.gpuMs)
                    }
                    i += 1
                }
                audio.program = .silence
                var s = 0
                while s < 300 { renderer.advance(frame: audio.next(dt: dt), dt: dt); s += 1 }
                var silent: [Double] = []
                s = 0
                while s < 60 { renderer.advance(frame: audio.next(dt: dt), dt: dt); silent.append(renderer.timing.cpuUpdateMs); s += 1 }
                let (u50, u95) = stats(update), (e50, e95) = stats(encode), (t50, t95) = stats(total), (g50, g95) = stats(gpu), (s50, _) = stats(silent)
                func f(_ v: Double) -> String { String(format: "%.2f", v) }
                report.append("| \(theme.rawValue) | \(quality.rawValue) | \(presentation.rawValue) | \(f(u50)) / \(f(u95)) | \(f(e50)) / \(f(e95)) | \(f(t50)) / \(f(t95)) | \(f(g50)) / \(f(g95)) | \(f(s50)) |")
                json.append(["theme": theme.rawValue, "quality": quality.rawValue, "presentation": presentation.rawValue,
                             "cpuUpdateMedian": u50, "cpuUpdateP95": u95, "cpuEncodeMedian": e50, "cpuEncodeP95": e95,
                             "cpuTotalMedian": t50, "cpuTotalP95": t95, "gpuMedian": g50, "gpuP95": g95, "silentCpuMedian": s50])
                print("perf \(theme.rawValue) \(quality.rawValue) \(presentation.rawValue): cpu \(f(t50)) ms, gpu \(f(g50)) ms")
            }
        }
    }
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: outDir.appendingPathComponent("perf.json"))
    }
}

try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
print(report.joined(separator: "\n"))
