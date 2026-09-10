import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Runs a block on the main actor, immediately when already there.
/// Used from AVFoundation / MediaPlayer callbacks, which are not isolated.
@inline(__always)
func runOnMain(_ block: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { block() }
    } else {
        Task { @MainActor in block() }
    }
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat queue"
        case .one: return "Repeat one"
        }
    }
}

enum SleepTimerOption: String, CaseIterable, Identifiable {
    case off, m5, m15, m30, m45, m60, endOfItem
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .m5: return "5 minutes"
        case .m15: return "15 minutes"
        case .m30: return "30 minutes"
        case .m45: return "45 minutes"
        case .m60: return "1 hour"
        case .endOfItem: return "End of this item"
        }
    }
    var minutes: Double? {
        switch self {
        case .m5: return 5
        case .m15: return 15
        case .m30: return 30
        case .m45: return 45
        case .m60: return 60
        default: return nil
        }
    }
}

/// The one player for the whole app. Owns the AVPlayer, the queue, the
/// transposition engine, resume bookkeeping and the lock-screen surface.
@MainActor
final class PlayerModel: NSObject, ObservableObject {

    static let shared = PlayerModel()

    // MARK: Published state

    @Published private(set) var current: MediaItem?
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var queueIndex: Int = 0
    @Published private(set) var queueTitle: String = ""

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var loadError: String?

    @Published var speed: Double = 1.0 { didSet { applySpeed() } }
    @Published var preservePitchWhenChangingSpeed = true { didSet { applyPitchAlgorithm() } }
    @Published var semitones: Int = 0 { didSet { pitch.semitones = semitones; persistOverrides() } }
    @Published var fineCents: Double = 0 { didSet { pitch.fineCents = Float(fineCents) } }
    @Published var transpositionEnabled = true

    @Published var loopStart: Double?
    @Published var loopEnd: Double?
    @Published var repeatMode: RepeatMode = .off
    @Published var autoplayNext = true
    @Published var shuffleEnabled = false

    @Published private(set) var sleepTimerOption: SleepTimerOption = .off
    @Published private(set) var sleepTimerFires: Date?

    @Published var isPresentingPlayer = false
    @Published private(set) var hasVideoTrack = false
    @Published private(set) var artwork: UIImage?

    // MARK: Internals

    let player = AVPlayer()
    let pitch = PitchProcessor()

    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var sleepTimer: Timer?
    private var shuffledOrder: [Int] = []
    private var lastProgressWrite: Double = -100

    private weak var library: LibraryStore?
    private let states = PlaybackStateStore.shared

    /// Speeds offered in the UI.
    static let speedPresets: [Double] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        installObservers()
        configureRemoteCommands()
    }

    func attach(library: LibraryStore) {
        self.library = library
    }

    // MARK: Queue control

    func play(item: MediaItem, in items: [MediaItem], title: String) {
        queue = items.isEmpty ? [item] : items
        queueTitle = title
        queueIndex = queue.firstIndex(of: item) ?? 0
        rebuildShuffle()
        // A deliberate open of one item (Continue Listening, a library tap, a
        // search result) — pick up where that specific file left off.
        load(at: queueIndex, autoplay: true, resume: true)
        isPresentingPlayer = true
    }

    func playQueue(_ items: [MediaItem], startAt index: Int, title: String) {
        guard !items.isEmpty else { return }
        queue = items
        queueTitle = title
        queueIndex = min(max(index, 0), items.count - 1)
        rebuildShuffle()
        // Playlist/queue playback: every item starts from the top, even if
        // it was partway through from some earlier, unrelated listen.
        load(at: queueIndex, autoplay: true, resume: false)
        isPresentingPlayer = true
    }

    func appendToQueue(_ items: [MediaItem]) {
        queue.append(contentsOf: items.filter { !queue.contains($0) })
        rebuildShuffle()
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            seek(to: 0); play(); return
        }
        let next = nextIndex()
        guard let next else {
            pause()
            return
        }
        queueIndex = next
        // Advancing through a queue always starts the next item fresh —
        // never resumes wherever that file happened to stop last time.
        load(at: next, autoplay: true, resume: false)
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        // Standard behaviour: restart the item unless we're near the beginning.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let previous = previousIndex()
        guard let previous else {
            seek(to: 0)
            return
        }
        queueIndex = previous
        load(at: previous, autoplay: true, resume: false)
    }

    private func nextIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if shuffleEnabled {
            guard let pos = shuffledOrder.firstIndex(of: queueIndex) else { return nil }
            if pos + 1 < shuffledOrder.count { return shuffledOrder[pos + 1] }
            return repeatMode == .all ? shuffledOrder.first : nil
        }
        if queueIndex + 1 < queue.count { return queueIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func previousIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if shuffleEnabled {
            guard let pos = shuffledOrder.firstIndex(of: queueIndex) else { return nil }
            if pos - 1 >= 0 { return shuffledOrder[pos - 1] }
            return repeatMode == .all ? shuffledOrder.last : nil
        }
        if queueIndex - 1 >= 0 { return queueIndex - 1 }
        return repeatMode == .all ? queue.count - 1 : nil
    }

    private func rebuildShuffle() {
        shuffledOrder = Array(queue.indices).shuffled()
        if let pos = shuffledOrder.firstIndex(of: queueIndex), pos != 0 {
            shuffledOrder.swapAt(0, pos)
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled { rebuildShuffle() }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: Loading

    private func load(at index: Int, autoplay: Bool, resume: Bool) {
        guard queue.indices.contains(index), let library else { return }
        let item = queue[index]
        guard let url = library.url(for: item) else {
            loadError = "That file is no longer where it used to be. Pull to refresh the library."
            return
        }

        savePosition()
        loadError = nil
        lastProgressWrite = -100
        current = item
        duration = 0
        currentTime = 0
        artwork = nil
        clearLoop()

        // Restore per-item speed / key if this file was tuned before.
        let saved = states.state(for: item.relativePath)
        if let s = saved.speed { speed = s }
        if let st = saved.semitones { semitones = st }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = preservePitchWhenChangingSpeed ? .spectral : .varispeed

        replace(with: playerItem, item: item, asset: asset, autoplay: autoplay, resume: resume)
    }

    private func replace(with playerItem: AVPlayerItem, item: MediaItem, asset: AVURLAsset, autoplay: Bool, resume: Bool) {
        isBuffering = true
        player.replaceCurrentItem(with: playerItem)
        observe(playerItem)

        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedDuration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(loadedDuration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                await MainActor.run {
                    self.duration = seconds.isFinite ? seconds : 0
                    self.hasVideoTrack = !videoTracks.isEmpty
                }

                if self.transpositionEnabled, let audioTrack = audioTracks.first {
                    if let mix = self.pitch.makeAudioMix(for: audioTrack) {
                        await MainActor.run { playerItem.audioMix = mix }
                    }
                }
                self.pitch.semitones = self.semitones
                self.pitch.fineCents = Float(self.fineCents)

                await MainActor.run {
                    if resume {
                        let resumeAt = self.states.resumePosition(for: item.relativePath)
                        if resumeAt > 1 {
                            self.seek(to: resumeAt)
                        }
                    }
                    self.applySpeed()
                    if autoplay { self.play() }
                    self.isBuffering = false
                    self.updateNowPlaying()
                }

                if !videoTracks.isEmpty, let url = self.library?.url(for: item) {
                    let image = await ThumbnailCache.shared.thumbnail(for: url, key: item.relativePath, maxSize: 800)
                    await MainActor.run {
                        self.artwork = image
                        self.updateNowPlaying()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBuffering = false
                    self.loadError = "Couldn't open “\(item.fileName)”. iOS may not support this container — try MP4/M4V/MOV or M4A/MP3."
                }
            }
        }
    }

    private func observe(_ playerItem: AVPlayerItem) {
        itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.status == .failed {
                    self.loadError = item.error?.localizedDescription
                        ?? "This file could not be played."
                    self.isBuffering = false
                }
            }
        }
        bufferObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isBuffering = !item.isPlaybackLikelyToKeepUp && self.isPlaying
            }
        }
    }

    private func installObservers() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            runOnMain { self?.tick(time: seconds) }
        }

        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = player.rate != 0
                self.updateNowPlayingPlaybackState()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            runOnMain { self?.handleItemEnded() }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            runOnMain { self?.handleInterruption(note) }
        }
    }

    // MARK: Ticking

    private func tick(time: Double) {
        guard time.isFinite else { return }
        currentTime = time

        if let a = loopStart, let b = loopEnd, b > a, time >= b - 0.05 {
            seek(to: a)
            return
        }

        if let path = current?.relativePath, duration > 0, isPlaying,
           abs(time - lastProgressWrite) > 4 {
            lastProgressWrite = time
            states.recordProgress(path: path, position: time, duration: duration)
        }
        updateNowPlayingElapsed()
    }

    private func handleItemEnded() {
        if let a = loopStart, loopEnd != nil {
            seek(to: a)
            play()
            return
        }
        if let path = current?.relativePath {
            states.markFinished(path, true)
        }
        if sleepTimerOption == .endOfItem {
            pause()
            setSleepTimer(.off)
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }
        if autoplayNext {
            playNext()
        } else {
            pause()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                AudioSessionManager.activate()
                play()
            }
        @unknown default:
            break
        }
    }

    // MARK: Transport

    func play() {
        guard current != nil else { return }
        AudioSessionManager.activate()
        player.play()
        applySpeed()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlayingPlaybackState()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        updateNowPlayingElapsed()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pitch.releaseTap()
        current = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func savePosition() {
        guard let path = current?.relativePath, duration > 0 else { return }
        states.recordProgress(path: path, position: currentTime, duration: duration)
        states.saveNow()
    }

    private func persistOverrides() {
        guard let path = current?.relativePath else { return }
        states.update(path) { s in
            s.speed = self.speed
            s.semitones = self.semitones
        }
    }

    // MARK: Speed & pitch

    private func applySpeed() {
        applyPitchAlgorithm()
        if isPlaying || player.rate != 0 {
            player.rate = Float(speed)
        }
        persistOverrides()
        updateNowPlayingPlaybackState()
    }

    private func applyPitchAlgorithm() {
        player.currentItem?.audioTimePitchAlgorithm =
            preservePitchWhenChangingSpeed ? .spectral : .varispeed
    }

    func nudgeSpeed(_ delta: Double) {
        speed = min(3.0, max(0.25, ((speed + delta) * 100).rounded() / 100))
    }

    func setSpeed(_ value: Double) {
        speed = min(3.0, max(0.25, value))
    }

    func transpose(by delta: Int) {
        semitones = min(12, max(-12, semitones + delta))
    }

    func resetKey() {
        semitones = 0
        fineCents = 0
    }

    // MARK: A–B loop

    func setLoopStart() {
        loopStart = currentTime
        if let end = loopEnd, end <= currentTime { loopEnd = nil }
    }

    func setLoopEnd() {
        guard let start = loopStart, currentTime > start + 0.3 else { return }
        loopEnd = currentTime
        seek(to: start)
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
    }

    var isLooping: Bool { loopStart != nil && loopEnd != nil }

    // MARK: Sleep timer

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerOption = option
        sleepTimerFires = nil

        guard let minutes = option.minutes else { return }
        let fireDate = Date().addingTimeInterval(minutes * 60)
        sleepTimerFires = fireDate
        sleepTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fadeOutAndPause()
                self.setSleepTimer(.off)
            }
        }
    }

    private func fadeOutAndPause() {
        // Short volume ramp so it does not cut off abruptly.
        let steps = 12
        let startVolume = player.volume
        for step in 0...steps {
            let delay = Double(step) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                runOnMain {
                    guard let self else { return }
                    let progress = Float(step) / Float(steps)
                    self.player.volume = startVolume * (1 - progress)
                    if step == steps {
                        self.pause()
                        self.player.volume = startVolume
                    }
                }
            }
        }
    }

    // MARK: Now Playing / remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            runOnMain { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            runOnMain { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            runOnMain { self?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            runOnMain { self?.skip(by: interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            runOnMain { self?.skip(by: -interval) }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            runOnMain { self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            runOnMain { self?.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = e.positionTime
            runOnMain { self?.seek(to: target) }
            return .success
        }

        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 2.0]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = Double(e.playbackRate)
            runOnMain { self?.setSpeed(rate) }
            return .success
        }
    }

    func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = current.displayName
        info[MPMediaItemPropertyAlbumTitle] = current.breadcrumb
        info[MPMediaItemPropertyArtist] = queueTitle.isEmpty ? "Curator Studio" : queueTitle
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = speed
        info[MPNowPlayingInfoPropertyMediaType] = current.kind == .video
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex

        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        updateNowPlayingElapsed()
    }

    // MARK: Convenience

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var canGoNext: Bool { nextIndex() != nil }
    var canGoPrevious: Bool { !queue.isEmpty }

    func handleEnteredBackground() {
        savePosition()
    }
}
