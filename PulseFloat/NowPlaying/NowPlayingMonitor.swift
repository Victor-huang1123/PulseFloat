import AppKit
import PulseFloatCore

/// 找出「現在是哪個 App 在出聲、播的是什麼」，產生圓環中央要顯示的封面或 App 圖示。只在主執行緒使用。
///
/// - 啟用（setActive(true)）時每 1.5 秒看一次 Core Audio 的出聲程序清單；同一個 App 每 3 秒才再讀一次歌曲資訊，
///   換 App 或收到 Music／Spotify 的播放通知時立刻讀；歌曲（App＋歌名＋歌手／影片 id）改變才重新下載封面。
/// - 連續 3 秒沒有任何 App 出聲就清掉圖片。
/// - 停用時停掉計時器與通知，不送任何 Apple event，並立刻清掉圖片。
@MainActor
final class NowPlayingMonitor {
    /// 中央圖片改變時呼叫（nil 表示不顯示）。
    var onArtworkChange: ((CenterArtwork?) -> Void)?
    /// 選單用的說明（「Spotify — 歌名 · 歌手」）；不知道正在播什麼時為 nil。
    private(set) var summary: String?

    private let sources = NowPlayingSources()
    private let resolver = AudioOwnerResolver()
    private var isActive = false
    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []

    private var currentApp: NowPlayingApp?
    private var lastOutputTime: TimeInterval = 0
    private var lastQueryTime: TimeInterval = 0
    private var queryInFlight = false
    private var queryPending = false
    /// 目前顯示內容的識別（App＋歌名＋歌手、影片 id 或 App 圖示）；nil 表示這個 App 還沒顯示任何東西。
    private var trackIdentity: String?
    /// 換 App、換歌或停用時遞增；過期的非同步結果直接丟掉。
    private var generation = 0
    private var published: CenterArtwork?
    /// 最近載入的封面；暫停超過 3 秒後再播同一首歌時直接沿用，不重新讀取或下載。
    private var lastCover: CenterArtwork?
    private var iconCache: [String: CGImage] = [:]
    /// 使用者拒絕自動化權限的 App：本次執行只顯示圖示，不再送 Apple event。
    private var deniedBundleIDs: Set<String> = []

    private static let pollInterval: TimeInterval = 1.5
    private static let requeryInterval: TimeInterval = 3
    private static let silenceTimeout: TimeInterval = 3
    private static let playerNotifications = ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"]

    /// 只在「功能開啟、浮動視窗可見、主題是圓環放射」時啟用；重複設定同一個值不做事。
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // 計時器加在主執行緒的 run loop，可同步進入 MainActor。
            MainActor.assumeIsolated { self?.poll(forceQuery: false) }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = DistributedNotificationCenter.default()
        for name in Self.playerNotifications {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll(forceQuery: true) }
            })
        }
        poll(forceQuery: true)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        queryPending = false
        clear()
    }

    private func clear() {
        generation += 1
        currentApp = nil
        trackIdentity = nil
        summary = nil
        publish(nil)
    }

    // MARK: - 出聲的 App

    private func poll(forceQuery: Bool) {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let processes = AudioProcessList.outputtingProcesses()
        resolver.prune(keeping: Set(processes.map(\.pid)))
        var apps: [NowPlayingApp] = []
        for process in processes {
            if let app = resolver.app(for: process), !apps.contains(where: { $0.bundleID == app.bundleID }) {
                apps.append(app)
            }
        }
        guard !apps.isEmpty else {
            if currentApp != nil, now - lastOutputTime >= Self.silenceTimeout { clear() }
            return
        }
        lastOutputTime = now
        guard let chosenID = NowPlayingParsing.preferredSource(among: apps.map(\.bundleID), current: currentApp?.bundleID),
              let chosen = apps.first(where: { $0.bundleID == chosenID }) else { return }
        // 只比 bundle id：同一個 App 的主程序與 helper 解析出的名稱可能略有不同，不應當成換 App。
        if chosen.bundleID != currentApp?.bundleID {
            generation += 1
            currentApp = chosen
            trackIdentity = nil
            summary = NowPlayingParsing.menuSummary(appName: chosen.name, title: nil, artist: nil)
            if canQuery(chosen) {
                // 已知的音樂／瀏覽器 App 先讀歌曲資訊，避免先閃一下 App 圖示再換成封面。
                queryTrack()
            } else {
                showIcon(for: chosen)
            }
        } else if forceQuery || now - lastQueryTime >= Self.requeryInterval {
            queryTrack()
        }
    }

    private func canQuery(_ app: NowPlayingApp) -> Bool {
        app.kind != .other && !deniedBundleIDs.contains(app.bundleID)
    }

    // MARK: - 歌曲資訊

    private func queryTrack() {
        guard isActive, let app = currentApp, canQuery(app) else { return }
        // 先用 NSRunningApplication 確認 App 已在執行才送 Apple event（腳本內也會再檢查），絕不把 App 開起來。
        // 例如主程式已結束、只剩 helper 還在出聲：不讀歌曲資訊，改顯示圖示。
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else {
            if trackIdentity == nil { showIcon(for: app) }
            return
        }
        guard !queryInFlight else {
            queryPending = true
            return
        }
        queryInFlight = true
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        let generation = generation
        sources.queryTrack(app: app) { [weak self] info in
            self?.handle(info, app: app, generation: generation)
        }
    }

    private func handle(_ info: NowPlayingSources.TrackInfo, app: NowPlayingApp, generation: Int) {
        queryInFlight = false
        defer {
            if queryPending {
                queryPending = false
                queryTrack()
            }
        }
        guard isActive, generation == self.generation, app.bundleID == currentApp?.bundleID else { return }
        switch info {
        case .notPermitted:
            deniedBundleIDs.insert(app.bundleID)
            if app.viaWebKit { clearArtwork() } else { showIcon(for: app) }
        case .nothing where app.viaWebKit:
            // WebKit 的聲音不一定來自 Safari（例如 Safari 網頁 App「YT Music」）：Safari 沒有 YouTube 分頁時不要亂掛 Safari 圖示。
            summary = nil
            clearArtwork()
        case .nothing:
            summary = NowPlayingParsing.menuSummary(appName: app.name, title: nil, artist: nil)
            // 音樂 App 暫停時保留目前的封面，等 3 秒沒聲音再清掉；瀏覽器則代表不是 YouTube，改顯示圖示。
            let isPlayer = app.kind == .music || app.kind == .spotify
            if !isPlayer || trackIdentity == nil { showIcon(for: app) }
        case let .track(title, artist, artworkURL):
            summary = NowPlayingParsing.menuSummary(appName: app.name, title: title, artist: artist)
            let identity = "\(app.bundleID)|\(title)|\(artist)"
            guard identity != trackIdentity else { return }
            beginArtworkLoad(identity: identity, app: app) { sources, id, completion in
                if app.kind == .music {
                    sources.loadMusicArtwork(id: id, completion: completion)
                } else if let artworkURL {
                    sources.loadArtwork(urls: [artworkURL], id: id, completion: completion)
                } else {
                    completion(nil)
                }
            }
        case let .video(title, videoID):
            summary = NowPlayingParsing.menuSummary(appName: app.name, title: title, artist: nil)
            let identity = "\(app.bundleID)|yt:\(videoID)"
            guard identity != trackIdentity else { return }
            let urls = NowPlayingParsing.youTubeThumbnailURLs(videoID: videoID)
            beginArtworkLoad(identity: identity, app: app) { sources, id, completion in
                sources.loadArtwork(urls: urls, id: id, completion: completion)
            }
        }
    }

    /// 換歌時開始載入封面；舊封面保留到新的載入完成（繪圖器再交叉淡入）。失敗時改顯示 App 圖示。
    private func beginArtworkLoad(
        identity: String,
        app: NowPlayingApp,
        load: (NowPlayingSources, String, @escaping @MainActor @Sendable (CenterArtwork?) -> Void) -> Void
    ) {
        generation += 1
        trackIdentity = identity
        if let lastCover, lastCover.id == identity {
            publish(lastCover)
            return
        }
        let generation = generation
        load(sources, identity) { [weak self] artwork in
            guard let self, self.isActive, generation == self.generation, identity == self.trackIdentity else { return }
            if let artwork {
                self.lastCover = artwork
                self.publish(artwork)
            } else {
                self.showIcon(for: app, keepingIdentity: true)
            }
        }
    }

    // MARK: - 輸出

    private func showIcon(for app: NowPlayingApp, keepingIdentity: Bool = false) {
        if !keepingIdentity { trackIdentity = "\(app.bundleID)|icon" }
        let image: CGImage
        if let cached = iconCache[app.path] {
            image = cached
        } else {
            guard let rendered = ArtworkImage.appIcon(atPath: app.path) else { return }
            iconCache[app.path] = rendered
            image = rendered
        }
        publish(CenterArtwork(id: "icon:\(app.bundleID)", image: image, kind: .appIcon))
    }

    private func clearArtwork() {
        trackIdentity = nil
        publish(nil)
    }

    private func publish(_ artwork: CenterArtwork?) {
        guard artwork != published else { return }
        published = artwork
        onArtworkChange?(artwork)
    }
}
