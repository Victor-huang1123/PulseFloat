import AppKit
import Darwin
import Foundation
import PulseFloatCore

/// 正在出聲的 App（helper 已換成它所屬的最外層 .app）。
struct NowPlayingApp: Equatable, Sendable {
    let bundleID: String
    /// 選單顯示用的名稱（例如「Spotify」）。
    let name: String
    /// .app 的絕對路徑，用來取得 App 圖示。
    let path: String

    var kind: NowPlayingParsing.SourceKind { NowPlayingParsing.sourceKind(appBundleID: bundleID) }
}

/// 把出聲的程序對應到它所屬的 App；以 pid 快取結果。只在主執行緒使用。
@MainActor
final class AudioOwnerResolver {
    private struct Entry {
        let app: NowPlayingApp?
    }

    private var cache: [pid_t: Entry] = [:]
    private let ownBundleID = Bundle.main.bundleIdentifier

    /// 回傳程序所屬的 App；PulseFloat 自己、系統服務或找不到 .app 時回傳 nil。
    func app(for process: AudioProcessList.Process) -> NowPlayingApp? {
        switch NowPlayingParsing.audioProcessRole(bundleID: process.bundleID, ownBundleID: ownBundleID) {
        case .ignored:
            return nil
        case .webKitMedia:
            // Safari 的影片由 /System/Library/Frameworks 裡的 WebKit GPU 程序出聲；只有 Safari 在執行時才算它的。
            guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { return nil }
            return NowPlayingApp(
                bundleID: "com.apple.Safari",
                name: safari.localizedName ?? "Safari",
                path: safari.bundleURL?.path ?? "/Applications/Safari.app"
            )
        case .candidate:
            if let entry = cache[process.pid] { return entry.app }
            let app = resolveOwner(pid: process.pid)
            cache[process.pid] = Entry(app: app)
            return app
        }
    }

    /// 丟掉已經不在出聲清單裡的 pid（pid 可能被重複使用）。
    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    private func resolveOwner(pid: pid_t) -> NowPlayingApp? {
        let running = NSRunningApplication(processIdentifier: pid)
        guard let ownPath = running?.bundleURL?.path ?? Self.executablePath(pid: pid),
              let appPath = NowPlayingParsing.outermostAppPath(ownPath),
              NowPlayingParsing.isUserFacingAppPath(appPath) else { return nil }
        let owner = appPath == running?.bundleURL?.path
            ? running
            : NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == appPath }
        let bundle = Bundle(path: appPath)
        guard let bundleID = owner?.bundleIdentifier ?? bundle?.bundleIdentifier,
              NowPlayingParsing.audioProcessRole(bundleID: bundleID, ownBundleID: ownBundleID) != .ignored else { return nil }
        let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let fileName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return NowPlayingApp(bundleID: bundleID, name: owner?.localizedName ?? bundleName ?? fileName, path: appPath)
    }

    /// 沒有註冊成 App 的 helper（例如瀏覽器的音訊 helper）改用執行檔路徑判斷。
    /// 用公開的 BSD sysctl（KERN_PROCARGS2：開頭 4 bytes 是 argc，接著是以 NUL 結尾的執行檔路徑），只讀得到同一使用者的程序。
    private static func executablePath(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }
}

/// 讀取歌曲／影片資訊（AppleScript）與下載、解碼封面。
/// 所有 AppleScript 都在同一條專用序列 queue 上編譯與執行（Apple event 會阻塞，絕不在主執行緒跑）；結果送回主執行緒。
/// 每個腳本都先確認 App 已在執行（`if application id … is running`），不會把 App 開起來。
final class NowPlayingSources: @unchecked Sendable {
    // @unchecked：scripts 與 failedScripts 只在 scriptQueue 上讀寫；其他成員建立後不再改變。

    /// AppleScript 讀到的內容。
    enum TrackInfo: Equatable, Sendable {
        /// 正在播放的歌曲；Spotify 另外附上已驗證的封面網址（Apple Music 的封面另外讀）。
        case track(title: String, artist: String, artworkURL: URL?)
        /// 瀏覽器分頁裡的 YouTube 影片。
        case video(title: String, videoID: String)
        /// 沒有在播放、讀不到，或不是支援的內容。
        case nothing
        /// 使用者拒絕讓 PulseFloat 讀取這個 App（自動化權限）。
        case notPermitted
    }

    private let scriptQueue = DispatchQueue(label: "com.victorhuang.PulseFloat.nowplaying.scripts", qos: .utility)
    private var scripts: [String: NSAppleScript] = [:]
    private var failedScripts: Set<String> = []
    private let session: URLSession

    /// 下載的圖片上限（位元組）；正常的封面與縮圖都遠小於這個值。
    private static let maxDownloadBytes = 8 * 1024 * 1024
    /// errAEEventNotPermitted：使用者在「自動化」權限中拒絕。
    private static let notPermittedError = -1743

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    // MARK: - 歌曲資訊

    /// 在腳本 queue 上讀取 app 目前播放的內容，完成後在主執行緒呼叫 completion。
    func queryTrack(app: NowPlayingApp, completion: @escaping @MainActor @Sendable (TrackInfo) -> Void) {
        scriptQueue.async { [self] in
            let info = runTrackQuery(app: app)
            Task { @MainActor in completion(info) }
        }
    }

    /// 讀取 Apple Music 目前歌曲的內嵌封面並解碼；沒有封面時 completion 收到 nil。
    func loadMusicArtwork(id: String, completion: @escaping @MainActor @Sendable (CenterArtwork?) -> Void) {
        scriptQueue.async { [self] in
            let data: Data?
            if case let .success(descriptor) = run(key: "music.artwork", source: Self.musicArtworkScript),
               !Self.isMissing(descriptor), !descriptor.data.isEmpty {
                data = descriptor.data
            } else {
                data = nil
            }
            guard let data else {
                Task { @MainActor in completion(nil) }
                return
            }
            // 解碼不佔用腳本 queue。
            DispatchQueue.global(qos: .utility).async {
                let artwork = ArtworkImage.cover(from: data).map { CenterArtwork(id: id, image: $0, kind: .cover) }
                Task { @MainActor in completion(artwork) }
            }
        }
    }

    // MARK: - 下載封面

    /// 依序嘗試下載 urls（HTTP 錯誤或無法解碼就換下一個），解碼成封面後在主執行緒呼叫 completion。
    /// 呼叫端必須先用 NowPlayingParsing 驗證網址（Spotify CDN、i.ytimg.com）。
    func loadArtwork(urls: [URL], id: String, completion: @escaping @MainActor @Sendable (CenterArtwork?) -> Void) {
        fetch(urls[...], id: id, completion: completion)
    }

    private func fetch(_ urls: ArraySlice<URL>, id: String, completion: @escaping @MainActor @Sendable (CenterArtwork?) -> Void) {
        guard let url = urls.first else {
            Task { @MainActor in completion(nil) }
            return
        }
        let remaining = urls.dropFirst()
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request) { [self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, (200..<300).contains(status), let data, data.count <= Self.maxDownloadBytes,
               let image = ArtworkImage.cover(from: data) {
                let artwork = CenterArtwork(id: id, image: image, kind: .cover)
                Task { @MainActor in completion(artwork) }
            } else {
                fetch(remaining, id: id, completion: completion)
            }
        }
        task.resume()
    }

    // MARK: - AppleScript（只在 scriptQueue 上）

    private enum ScriptResult {
        case success(NSAppleEventDescriptor)
        case notPermitted
        case failed
    }

    private func runTrackQuery(app: NowPlayingApp) -> TrackInfo {
        switch app.kind {
        case .music:
            return trackInfo(from: run(key: "music.info", source: Self.musicInfoScript), hasArtworkURL: false)
        case .spotify:
            return trackInfo(from: run(key: "spotify.info", source: Self.spotifyInfoScript), hasArtworkURL: true)
        case .chromium:
            return videoInfo(from: run(key: "chromium." + app.bundleID, source: Self.browserScript(bundleID: app.bundleID, titleProperty: "title", activeTab: "active tab")))
        case .safari:
            return videoInfo(from: run(key: "safari", source: Self.browserScript(bundleID: "com.apple.Safari", titleProperty: "name", activeTab: "current tab")))
        case .other:
            return .nothing
        }
    }

    /// 編譯一次後快取；編譯失敗（例如 App 的字典不支援）就記下來，之後不再嘗試。
    private func run(key: String, source: String) -> ScriptResult {
        guard !failedScripts.contains(key) else { return .failed }
        let script: NSAppleScript
        if let cached = scripts[key] {
            script = cached
        } else {
            var compileError: NSDictionary?
            guard let compiled = NSAppleScript(source: source), compiled.compileAndReturnError(&compileError) else {
                failedScripts.insert(key)
                return .failed
            }
            scripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            return number == Self.notPermittedError ? .notPermitted : .failed
        }
        return .success(descriptor)
    }

    private func trackInfo(from result: ScriptResult, hasArtworkURL: Bool) -> TrackInfo {
        switch result {
        case .notPermitted:
            return .notPermitted
        case .failed:
            return .nothing
        case let .success(list):
            guard list.numberOfItems >= (hasArtworkURL ? 3 : 2) else { return .nothing }
            let title = Self.string(list.atIndex(1))
            let artist = Self.string(list.atIndex(2))
            guard !title.isEmpty || !artist.isEmpty else { return .nothing }
            let artworkURL = hasArtworkURL ? NowPlayingParsing.validatedSpotifyArtworkURL(Self.string(list.atIndex(3))) : nil
            return .track(title: title, artist: artist, artworkURL: artworkURL)
        }
    }

    /// 結果是 {作用中分頁網址, 標題, {{網址, 標題}, …}}；優先用作用中分頁，否則取第一個 YouTube 影片分頁。
    private func videoInfo(from result: ScriptResult) -> TrackInfo {
        switch result {
        case .notPermitted:
            return .notPermitted
        case .failed:
            return .nothing
        case let .success(list):
            guard list.numberOfItems >= 3 else { return .nothing }
            if let id = NowPlayingParsing.youTubeVideoID(from: Self.string(list.atIndex(1))) {
                return .video(title: NowPlayingParsing.cleanYouTubeTitle(Self.string(list.atIndex(2))), videoID: id)
            }
            guard let tabs = list.atIndex(3) else { return .nothing }
            var index = 1
            while index <= tabs.numberOfItems {
                if let tab = tabs.atIndex(index), tab.numberOfItems >= 2,
                   let id = NowPlayingParsing.youTubeVideoID(from: Self.string(tab.atIndex(1))) {
                    return .video(title: NowPlayingParsing.cleanYouTubeTitle(Self.string(tab.atIndex(2))), videoID: id)
                }
                index += 1
            }
            return .nothing
        }
    }

    /// missing value 與 null 都當成空字串（避免把 "msng" 之類的類型碼當成文字）。
    private static func string(_ descriptor: NSAppleEventDescriptor?) -> String {
        guard let descriptor, !isMissing(descriptor) else { return "" }
        return descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isMissing(_ descriptor: NSAppleEventDescriptor) -> Bool {
        let typeNull: DescType = 0x6E75_6C6C      // 'null'
        let typeType: DescType = 0x7479_7065      // 'type'
        let missingValue: OSType = 0x6D73_6E67    // 'msng'
        return descriptor.descriptorType == typeNull
            || (descriptor.descriptorType == typeType && descriptor.typeCodeValue == missingValue)
    }

    private static let musicInfoScript = """
    if application id "com.apple.Music" is running then
        with timeout of 2 seconds
            tell application id "com.apple.Music"
                if player state is playing then
                    set t to current track
                    return {name of t, artist of t}
                end if
            end tell
        end timeout
    end if
    return {}
    """

    private static let musicArtworkScript = """
    if application id "com.apple.Music" is running then
        with timeout of 2 seconds
            tell application id "com.apple.Music"
                try
                    if player state is playing then
                        tell current track
                            if (count of artworks) > 0 then return raw data of artwork 1
                        end tell
                    end if
                end try
            end tell
        end timeout
    end if
    return missing value
    """

    private static let spotifyInfoScript = """
    if application id "com.spotify.client" is running then
        with timeout of 2 seconds
            tell application id "com.spotify.client"
                if player state is playing then
                    set t to current track
                    return {name of t, artist of t, artwork url of t}
                end if
            end tell
        end timeout
    end if
    return {}
    """

    /// Chromium 系與 Safari 共用：讀作用中分頁，並在本機篩出網址含 "youtu" 的分頁（不執行網頁 JavaScript）。
    private static func browserScript(bundleID: String, titleProperty: String, activeTab: String) -> String {
        """
        if application id "\(bundleID)" is running then
            with timeout of 2 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return {}
                    set activeURL to ""
                    set activeTitle to ""
                    try
                        set activeURL to URL of \(activeTab) of front window
                        set activeTitle to \(titleProperty) of \(activeTab) of front window
                    end try
                    set found to {}
                    try
                        set allURLs to URL of every tab of every window
                        set allTitles to \(titleProperty) of every tab of every window
                        repeat with w from 1 to count of allURLs
                            set windowURLs to item w of allURLs
                            set windowTitles to item w of allTitles
                            repeat with i from 1 to count of windowURLs
                                try
                                    set u to item i of windowURLs
                                    if u contains "youtu" then set end of found to {u, item i of windowTitles}
                                end try
                            end repeat
                        end repeat
                    end try
                    return {activeURL, activeTitle, found}
                end tell
            end timeout
        end if
        return {}
        """
    }
}
