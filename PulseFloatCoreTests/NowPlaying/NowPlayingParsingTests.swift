import CoreGraphics
import PulseFloatCore
import XCTest

final class NowPlayingParsingTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    // MARK: - YouTube

    func testYouTubeVideoIDFromEverySupportedURLShape() {
        let urls = [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)&t=42s&list=PL0123456789",
            "https://youtube.com/watch?feature=share&v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)&list=RDAMVM\(id)",
            "https://youtu.be/\(id)",
            "https://youtu.be/\(id)?t=10",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)?autoplay=1",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "https://www.youtube.com/live/\(id)?feature=share",
            "http://www.youtube.com/watch?v=\(id)",
            "https://WWW.YouTube.com/watch?v=\(id)",
            "  https://youtu.be/\(id)  ",
        ]
        for url in urls {
            XCTAssertEqual(NowPlayingParsing.youTubeVideoID(from: url), id, url)
        }
        XCTAssertEqual(NowPlayingParsing.youTubeVideoID(from: "https://www.youtube.com/shorts/aBcDeFgHi_-"), "aBcDeFgHi_-")
    }

    func testYouTubeVideoIDRejectsEverythingElse() {
        let urls = [
            "",
            "not a url",
            "https://www.youtube.com/",
            "https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw",
            "https://www.youtube.com/@someone",
            "https://www.youtube.com/results?search_query=\(id)",
            "https://www.youtube.com/playlist?list=PL0123456789",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=",
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=\(id)X",
            "https://www.youtube.com/watch?v=dQw4w9WgXc!",
            "https://www.youtube.com/watch?v=dQw4w9WgXc%20",
            "https://www.youtube.com/watch/\(id)",
            "https://www.youtube.com/shorts/",
            "https://youtu.be/",
            "https://youtu.be/\(id)/extra/abc12345678",
            "https://evil.com/watch?v=\(id)",
            "https://youtube.com.evil.com/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)",
            "javascript:alert('https://youtu.be/\(id)')",
            "javascript://youtu.be/\(id)",
            "file:///youtu.be/\(id)",
            "ftp://youtu.be/\(id)",
        ]
        for url in urls {
            XCTAssertNil(NowPlayingParsing.youTubeVideoID(from: url), url)
        }
    }

    func testYouTubeIDValidationAndThumbnailURLs() {
        XCTAssertTrue(NowPlayingParsing.isYouTubeVideoID(id))
        XCTAssertTrue(NowPlayingParsing.isYouTubeVideoID("A-_0zZ9aaaa"))
        XCTAssertFalse(NowPlayingParsing.isYouTubeVideoID("dQw4w9WgXc"))
        XCTAssertFalse(NowPlayingParsing.isYouTubeVideoID("dQw4w9WgXcQQ"))
        XCTAssertFalse(NowPlayingParsing.isYouTubeVideoID("dQw4w9WgXc/"))
        XCTAssertFalse(NowPlayingParsing.isYouTubeVideoID("dQw4w9WgXcé"))
        XCTAssertEqual(NowPlayingParsing.youTubeThumbnailURLs(videoID: id).map(\.absoluteString), [
            "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg",
            "https://i.ytimg.com/vi/\(id)/mqdefault.jpg",
        ])
        XCTAssertEqual(NowPlayingParsing.youTubeThumbnailURLs(videoID: "../../etc"), [])
    }

    func testYouTubeTitleCleanup() {
        XCTAssertEqual(NowPlayingParsing.cleanYouTubeTitle("(3) Never Gonna Give You Up - YouTube"), "Never Gonna Give You Up")
        XCTAssertEqual(NowPlayingParsing.cleanYouTubeTitle("Song Name - YouTube Music"), "Song Name")
        XCTAssertEqual(NowPlayingParsing.cleanYouTubeTitle("(Live) Song - YouTube"), "(Live) Song")
        XCTAssertEqual(NowPlayingParsing.cleanYouTubeTitle("() Odd"), "() Odd")
        XCTAssertEqual(NowPlayingParsing.cleanYouTubeTitle("  Plain title  "), "Plain title")
    }

    // MARK: - Spotify

    func testSpotifyArtworkURLAcceptsOnlyHTTPSSpotifyCDN() {
        let accepted = [
            "https://i.scdn.co/image/ab67616d0000b273e8b066f70c206551210d902b",
            "https://mosaic.scdn.co/640/ab67616d0000b273",
            "https://image-cdn-ak.spotifycdn.com/image/ab67616d0000b273",
            "https://scdn.co/image/abc",
            "https://I.SCDN.CO/image/abc",
            "https://i.scdn.co:443/image/abc",
        ]
        for url in accepted {
            XCTAssertNotNil(NowPlayingParsing.validatedSpotifyArtworkURL(url), url)
        }
        let rejected = [
            "",
            "http://i.scdn.co/image/abc",
            "https://scdn.co.evil.com/image/abc",
            "https://evilscdn.co/image/abc",
            "https://i.scdn.com/image/abc",
            "https://spotifycdn.com.evil.com/image/abc",
            "https://i.scdn.co:8443/image/abc",
            "https://user:pass@i.scdn.co/image/abc",
            "https://example.com/image.jpg",
            "ftp://i.scdn.co/image/abc",
            "javascript:alert(1)",
            "file:///i.scdn.co/image/abc",
        ]
        for url in rejected {
            XCTAssertNil(NowPlayingParsing.validatedSpotifyArtworkURL(url), url)
        }
    }

    // MARK: - App 與程序

    func testOutermostAppPath() {
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0.6778.86/Helpers/Google Chrome Helper.app"
        XCTAssertEqual(NowPlayingParsing.outermostAppPath(chromeHelper), "/Applications/Google Chrome.app")
        XCTAssertEqual(NowPlayingParsing.outermostAppPath(chromeHelper + "/Contents/MacOS/Google Chrome Helper"), "/Applications/Google Chrome.app")
        XCTAssertEqual(NowPlayingParsing.outermostAppPath("/Applications/Spotify.app"), "/Applications/Spotify.app")
        XCTAssertEqual(NowPlayingParsing.outermostAppPath("/Applications/Spotify.app/"), "/Applications/Spotify.app")
        XCTAssertEqual(NowPlayingParsing.outermostAppPath("/System/Applications/Music.app/Contents/MacOS/Music"), "/System/Applications/Music.app")
        XCTAssertEqual(
            NowPlayingParsing.outermostAppPath("/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"),
            "/Applications/Discord.app"
        )
        XCTAssertEqual(NowPlayingParsing.outermostAppPath("/Users/me/Applications/Foo.APP/Contents"), "/Users/me/Applications/Foo.APP")
        XCTAssertNil(NowPlayingParsing.outermostAppPath(
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        ))
        XCTAssertNil(NowPlayingParsing.outermostAppPath("/usr/bin/afplay"))
        XCTAssertNil(NowPlayingParsing.outermostAppPath("Applications/Foo.app"))
        XCTAssertNil(NowPlayingParsing.outermostAppPath("/Applications/.app/Contents"))
        XCTAssertNil(NowPlayingParsing.outermostAppPath(""))
    }

    func testUserFacingAppPath() {
        XCTAssertTrue(NowPlayingParsing.isUserFacingAppPath("/Applications/Spotify.app"))
        XCTAssertTrue(NowPlayingParsing.isUserFacingAppPath("/System/Applications/Music.app"))
        XCTAssertTrue(NowPlayingParsing.isUserFacingAppPath("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
        XCTAssertTrue(NowPlayingParsing.isUserFacingAppPath("/Users/me/Applications/Foo.app"))
        XCTAssertFalse(NowPlayingParsing.isUserFacingAppPath("/System/Library/CoreServices/ContinuityCaptureAgent.app"))
        XCTAssertFalse(NowPlayingParsing.isUserFacingAppPath(""))
    }

    func testAudioProcessClassification() {
        let own = "com.victorhuang.PulseFloat"
        let cases: [(String, NowPlayingParsing.AudioProcessRole)] = [
            ("com.apple.Music", .candidate),
            ("com.spotify.client", .candidate),
            ("com.google.Chrome.helper", .candidate),
            ("com.hnc.Discord.helper", .candidate),
            ("com.apple.Safari", .candidate),
            ("com.apple.podcasts", .candidate),
            ("com.apple.QuickTimePlayerX", .candidate),
            ("com.apple.WebKit.GPU", .webKitMedia),
            ("com.apple.WebKit.WebContent", .webKitMedia),
            ("systemsoundserverd", .ignored),
            ("com.apple.coreaudiod", .ignored),
            ("com.apple.avconferenced", .ignored),
            ("com.apple.corespeechd", .ignored),
            ("com.apple.PowerChime", .ignored),
            ("com.apple.CoreSpeech", .ignored),
            ("com.apple.audio.AudioComponentRegistrar", .ignored),
            ("com.apple.accessibility.heard", .ignored),
            (own, .ignored),
            (own + ".helper", .ignored),
            ("", .ignored),
            ("   ", .ignored),
        ]
        for (bundleID, role) in cases {
            XCTAssertEqual(NowPlayingParsing.audioProcessRole(bundleID: bundleID, ownBundleID: own), role, bundleID)
        }
        XCTAssertEqual(NowPlayingParsing.audioProcessRole(bundleID: own, ownBundleID: nil), .candidate)
    }

    func testSourceKindAndPreference() {
        XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: "com.apple.Music"), .music)
        XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: "com.spotify.client"), .spotify)
        XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: "com.apple.Safari"), .safari)
        for browser in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"] {
            XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: browser), .chromium, browser)
        }
        XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: "com.google.Chrome.helper"), .other)
        XCTAssertEqual(NowPlayingParsing.sourceKind(appBundleID: "com.hnc.Discord"), .other)

        XCTAssertNil(NowPlayingParsing.preferredSource(among: [], current: nil))
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["com.hnc.Discord", "com.spotify.client"], current: nil), "com.spotify.client")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["com.hnc.Discord", "com.spotify.client"], current: "com.hnc.Discord"), "com.spotify.client")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["com.hnc.Discord", "com.google.Chrome"], current: nil), "com.google.Chrome")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["com.google.Chrome", "com.apple.Safari"], current: nil), "com.google.Chrome")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["com.google.Chrome", "com.apple.Safari"], current: "com.apple.Safari"), "com.apple.Safari")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["a.one", "b.two"], current: "b.two"), "b.two")
        XCTAssertEqual(NowPlayingParsing.preferredSource(among: ["a.one", "b.two"], current: "gone.app"), "a.one")
    }

    // MARK: - 顯示與影像

    func testMenuSummary() {
        XCTAssertEqual(NowPlayingParsing.menuSummary(appName: "Spotify", title: "Title", artist: "Artist"), "Spotify — Title · Artist")
        XCTAssertEqual(NowPlayingParsing.menuSummary(appName: "Google Chrome", title: "Video", artist: nil), "Google Chrome — Video")
        XCTAssertEqual(NowPlayingParsing.menuSummary(appName: "Discord", title: nil, artist: " "), "Discord")
        XCTAssertEqual(NowPlayingParsing.menuSummary(appName: "", title: "Only", artist: "Me"), "Only · Me")
        let long = NowPlayingParsing.menuSummary(appName: "Spotify", title: String(repeating: "很長的歌名", count: 20), artist: "Artist")
        XCTAssertEqual(long.count, 40)
        XCTAssertTrue(long.hasPrefix("Spotify — 很長的歌名"))
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(NowPlayingParsing.menuSummary(appName: "Music", title: "A", artist: "B", limit: 40), "Music — A · B")
    }

    func testCenterSquareCrop() {
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 1280, height: 720), CGRect(x: 280, y: 0, width: 720, height: 720))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 320, height: 180), CGRect(x: 70, y: 0, width: 180, height: 180))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 640, height: 480), CGRect(x: 80, y: 0, width: 480, height: 480))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 720, height: 1280), CGRect(x: 0, y: 280, width: 720, height: 720))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 640, height: 640), CGRect(x: 0, y: 0, width: 640, height: 640))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 321, height: 180), CGRect(x: 70, y: 0, width: 180, height: 180))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 1, height: 1), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 0, height: 0), .zero)
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 0, height: 100), .zero)
        XCTAssertEqual(NowPlayingParsing.centerSquareCrop(width: 100, height: -5), .zero)
    }
}
