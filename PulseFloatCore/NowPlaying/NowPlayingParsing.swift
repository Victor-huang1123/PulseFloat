import CoreGraphics
import Foundation

/// 「圓環中央顯示正在播放的封面」用到的純函式：網址解析、白名單驗證、路徑與 bundle id 分類、裁切幾何。
/// 不呼叫任何系統服務，可在任意執行緒使用。
public enum NowPlayingParsing {
    // MARK: - YouTube

    /// 從 YouTube 網址取出 11 碼影片 id（[A-Za-z0-9_-]）；不是影片網址時回傳 nil。
    /// 支援 youtube.com/watch?v=、m.／music.youtube.com、youtu.be/ID、/shorts/ID、/embed/ID、/live/ID；只接受 http(s)。
    public static func youTubeVideoID(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = parts.count == 1 ? parts[0] : nil
        } else if youTubeHosts.contains(host) {
            if parts.first == "watch", parts.count == 1 {
                candidate = components.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) {
                candidate = parts[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let candidate, isYouTubeVideoID(candidate) else { return nil }
        return candidate
    }

    /// 是否為合法的 YouTube 影片 id：剛好 11 個 [A-Za-z0-9_-] 字元。
    public static func isYouTubeVideoID(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard scalars.count == 11 else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
            default: false
            }
        }
    }

    /// 影片縮圖網址（先試 maxresdefault，失敗再用 mqdefault）；只有影片 id 會送到 i.ytimg.com。id 不合法時回傳空陣列。
    public static func youTubeThumbnailURLs(videoID: String) -> [URL] {
        guard isYouTubeVideoID(videoID) else { return [] }
        return ["maxresdefault.jpg", "mqdefault.jpg"].compactMap { URL(string: "https://i.ytimg.com/vi/\(videoID)/\($0)") }
    }

    /// 整理 YouTube 分頁標題：去掉開頭的通知數「(3) 」與結尾的「 - YouTube」「 - YouTube Music」。
    public static func cleanYouTubeTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
           text[text.index(after: text.startIndex)..<close].allSatisfy(\.isNumber),
           close > text.index(after: text.startIndex) {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for suffix in [" - YouTube Music", " - YouTube"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    // MARK: - Spotify

    /// 驗證 Spotify 給的封面網址：必須是 https、沒有帳密、預設埠，host 是 scdn.co 或 spotifycdn.com（或其子網域）。
    /// 合格時回傳 URL，否則 nil。
    public static func validatedSpotifyArtworkURL(_ urlString: String) -> URL? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), !host.isEmpty,
              spotifyArtworkDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let url = components.url else { return nil }
        return url
    }

    private static let spotifyArtworkDomains = ["scdn.co", "spotifycdn.com"]

    // MARK: - App 與程序

    /// 取路徑中最外層的 `.app`（例如 Chrome helper 的路徑回傳 `/Applications/Google Chrome.app`）；
    /// 只接受絕對路徑，沒有 `.app` 時回傳 nil。
    public static func outermostAppPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        var index = 0
        while index < parts.count {
            let part = parts[index]
            if part.count > 4, part.lowercased().hasSuffix(".app") {
                return "/" + parts[0...index].joined(separator: "/")
            }
            index += 1
        }
        return nil
    }

    /// 是否是使用者會認得的 App：`/System/Library/` 底下的是系統代理程式（例如接續互通相機），不顯示它們的圖示；
    /// `/System/Applications/`（音樂、QuickTime 等）與其他位置都算。
    public static func isUserFacingAppPath(_ appPath: String) -> Bool {
        !appPath.isEmpty && !appPath.hasPrefix("/System/Library/")
    }

    /// Core Audio 程序物件的分類（依它回報的 bundle id）。
    public enum AudioProcessRole: Equatable, Sendable {
        /// PulseFloat 自己、系統音效與語音服務等，不當作「正在播放」的來源。
        case ignored
        /// WebKit 的媒體程序（Safari 的影片從這裡出聲）；需要另外判斷屬於哪個 App。
        case webKitMedia
        /// 一般 App 或它的 helper；用程序路徑找出所屬的 `.app`。
        case candidate
    }

    /// 依 bundle id 分類出聲的程序；ownBundleID 是 PulseFloat 自己的 bundle id（一律忽略）。
    public static func audioProcessRole(bundleID: String, ownBundleID: String?) -> AudioProcessRole {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .ignored }
        if let ownBundleID, !ownBundleID.isEmpty, id == ownBundleID || id.hasPrefix(ownBundleID + ".") { return .ignored }
        if ignoredBundleIDs.contains(id) || ignoredPrefixes.contains(where: { id.hasPrefix($0) }) { return .ignored }
        if id.hasPrefix("com.apple.WebKit.") { return .webKitMedia }
        if id.hasPrefix("com.apple."), let last = id.split(separator: ".").last, isDaemonName(last) { return .ignored }
        return .candidate
    }

    /// 全小寫英文字母且以 d 結尾的名稱（coreaudiod、avconferenced 這類系統 daemon）。
    private static func isDaemonName(_ name: Substring) -> Bool {
        name.count >= 3 && name.hasSuffix("d") && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }

    private static let ignoredBundleIDs: Set<String> = [
        "systemsoundserverd",
        "com.apple.PowerChime",
        "com.apple.CoreSpeech",
        "com.apple.Siri",
        "com.apple.VoiceOver",
        "com.apple.ScreenReaderUIServer",
        "com.apple.SpeechSynthesisServer",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.finder",
    ]

    private static let ignoredPrefixes = [
        "com.apple.audio.",
        "com.apple.coreaudio",
        "com.apple.CoreAudio",
        "com.apple.siri",
        "com.apple.speech.",
        "com.apple.SpeechRecognitionCore",
        "com.apple.accessibility.",
    ]

    /// 已知能讀到歌曲／影片資訊的來源。
    public enum SourceKind: Equatable, Sendable {
        /// Apple Music（AppleScript 讀歌名、歌手、內嵌封面）。
        case music
        /// Spotify（AppleScript 讀歌名、歌手、封面網址）。
        case spotify
        /// Chromium 系瀏覽器（Chrome、Edge、Brave、Arc），從分頁網址找 YouTube。
        case chromium
        /// Safari，從分頁網址找 YouTube。
        case safari
        /// 其他 App：只顯示 App 圖示。
        case other
    }

    /// 依「所屬 App」的 bundle id 判斷來源種類。
    public static func sourceKind(appBundleID: String) -> SourceKind {
        switch appBundleID {
        case "com.apple.Music": .music
        case "com.spotify.client": .spotify
        case "com.apple.Safari": .safari
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser": .chromium
        default: .other
        }
    }

    /// 同時有多個 App 出聲時挑一個：音樂 App 優先，其次瀏覽器，再來其他 App；
    /// 同一級裡優先保留目前顯示的 current，避免畫面來回跳。都沒有時回傳 nil。
    public static func preferredSource(among appBundleIDs: [String], current: String?) -> String? {
        var best: String?
        var bestRank = Int.max
        var index = 0
        while index < appBundleIDs.count {
            let id = appBundleIDs[index]
            let rank = sourceRank(sourceKind(appBundleID: id))
            if rank < bestRank || (rank == bestRank && id == current && best != current) {
                best = id
                bestRank = rank
            }
            index += 1
        }
        return best
    }

    private static func sourceRank(_ kind: SourceKind) -> Int {
        switch kind {
        case .music, .spotify: 0
        case .chromium, .safari: 1
        case .other: 2
        }
    }

    // MARK: - 顯示

    /// 選單用的「App — 歌名 · 歌手」說明，超過 limit 個字元時截斷並加「…」；空白欄位會省略。
    public static func menuSummary(appName: String, title: String?, artist: String?, limit: Int = 40) -> String {
        let clean: (String?) -> String? = { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        var text = clean(appName) ?? ""
        let detail = [clean(title), clean(artist)].compactMap { $0 }.joined(separator: " · ")
        if !detail.isEmpty { text = text.isEmpty ? detail : text + " — " + detail }
        let limit = max(1, limit)
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    // MARK: - 影像

    /// 置中正方形裁切範圍（像素；邊長為短邊）。寬或高不是正數時回傳 `.zero`。
    public static func centerSquareCrop(width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0 else { return .zero }
        let side = min(width, height)
        return CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }
}
