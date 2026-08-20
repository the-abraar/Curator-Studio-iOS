import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showingPicker = false
    @State private var showingDownloadSettings = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.rootDisplayName.isEmpty ? "No folder" : library.rootDisplayName)
                                .font(.body.weight(.medium))
                            Text("\(library.allItems.count) playable file\(library.allItems.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Change folder", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        Label("Rescan now", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Curator Studio only reads the folder you pick. Downloads from the YouTube tab land straight in it, and you can add files by hand too.")
                }

                Section {
                    Toggle("Keep pitch when changing speed", isOn: $player.preservePitchWhenChangingSpeed)
                    Toggle("Transposition engine", isOn: $player.transpositionEnabled)
                    Toggle("Autoplay next item", isOn: $player.autoplayNext)
                } header: {
                    Text("Playback defaults")
                } footer: {
                    Text("The transposition engine adds a small amount of audio processing. Turn it off if you never re-key anything and want the shortest possible path to your speakers.")
                }

                Section {
                    Button {
                        showingDownloadSettings = true
                    } label: {
                        HStack {
                            Label("Download settings", systemImage: "arrow.down.circle")
                            Spacer()
                            Text(downloads.defaultQuality.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(downloads.activeJobs.prefix(Self.maxQueueRows)) { job in
                        QueueProgressRow(job: job)
                    }
                    if downloads.activeJobs.count > Self.maxQueueRows {
                        Text("+ \(downloads.activeJobs.count - Self.maxQueueRows) more in the queue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        DownloadsScreen()
                    } label: {
                        HStack {
                            Label("All downloads", systemImage: "arrow.down.circle.dotted")
                            Spacer()
                            Text(queueSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Quality, SponsorBlock and tagging for videos you pull down from the YouTube tab. Everything happens on this iPhone. Transfers keep running while you're on another tab — merging and filing finish whenever the app is open.")
                }

                Section {
                    NavigationLink {
                        FormatHelpScreen()
                    } label: {
                        Label("Which formats play?", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        GestureHelpScreen()
                    } label: {
                        Label("Gestures & shortcuts", systemImage: "hand.tap")
                    }
                    NavigationLink {
                        IngestHelpScreen()
                    } label: {
                        Label("How downloading works", systemImage: "arrow.triangle.branch")
                    }
                } header: {
                    Text("Help")
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset all progress & bookmarks", systemImage: "trash")
                    }
                    Button {
                        Task { await ThumbnailCache.shared.purge() }
                    } label: {
                        Label("Clear thumbnail cache", systemImage: "photo.badge.arrow.down")
                    }
                } header: {
                    Text("Maintenance")
                }

                Section {
                    Text("Curator Studio 1.0")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPicker) {
                FolderPicker { url in
                    Task { await library.chooseRoot(url: url) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingDownloadSettings) { DownloadSettingsSheet() }
            .alert("Reset everything?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) { states.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resume positions, stars, watched marks and bookmarks will all be cleared. Your files are not touched.")
            }
        }
    }

    /// How many of the queue to show inline before it stops being a settings screen.
    private static let maxQueueRows = 4

    /// "2 running · 5 waiting" — the state of the queue without having to open it.
    private var queueSummary: String {
        let active = downloads.activeJobs
        guard !active.isEmpty else { return "Nothing queued" }
        let waiting = active.filter { $0.stage == .queued }.count
        let running = active.count - waiting
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }
}

/// One line of the queue as it looks in Settings: what it is and how far along, and nothing more.
/// The full row — destination folder, swipe to cancel or retry — stays on `DownloadsScreen`.
private struct QueueProgressRow: View {

    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: job.stage.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)

                Text(job.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // A queued job has no progress to report yet, and "0%" reads like a stall.
                if job.stage != .queued {
                    Text("\(Int(job.fraction * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressPill(fraction: job.fraction)

            HStack(spacing: 5) {
                Text(job.stage.label)
                if job.stage == .downloading, job.totalBytes > 0 {
                    Text("· \(Fmt.fileSize(job.receivedBytes)) of \(Fmt.fileSize(job.totalBytes))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct FormatHelpScreen: View {
    var body: some View {
        List {
            Section("Plays natively") {
                Text("Video: MP4, M4V, MOV, MPEG-1/2, 3GP")
                Text("Audio: MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC")
            }
            Section("Won't play") {
                Text("MKV, AVI, WEBM, WMV, FLV, OGG/Opus")
            }
            Section {
                Text("iOS has no decoder for those containers. Downloads from the YouTube tab are always H.264/AAC MP4, so this only affects files you copy in yourself. To convert one, on any desktop:")
                    .font(.footnote)
                Text("ffmpeg -i input.mkv -c copy output.mp4")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("If the copy fails, the codecs inside also need converting:")
                    .font(.footnote)
                Text("ffmpeg -i input.mkv -c:v libx264 -c:a aac output.mp4")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Converting")
            }
        }
        .navigationTitle("Formats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct IngestHelpScreen: View {
    var body: some View {
        List {
            Section("The shape of it") {
                step(1, "You find something", "Search the YouTube tab, open a channel or playlist you follow, or paste a link — a video, a Short, or a whole playlist.")
                step(2, "The phone downloads it", "Straight from YouTube over your normal connection. Anything above 720p only exists as separate video and audio streams, so both come down at once.")
                step(3, "It gets merged and trimmed", "The two streams are muxed into one MP4 with AVFoundation, sponsor segments are cut out, and the title, channel and artwork are written in as tags.")
                step(4, "It lands in the right folder", "Into the library folder you picked — nested paths like Learn Stuff/German included — with a .curator.json sidecar holding the source link and chapters.")
                step(5, "It's just a file", "Play it with the full player: speed, transposition, A-B loop, screen off, background audio. No connection needed ever again.")
            }

            Section("While you're elsewhere") {
                Text("Transfers run in a background session, so they keep going when you leave the app or lock the phone. Merging and filing need the app open — reopen it and anything that finished in the meantime completes itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Quality") {
                Text("YouTube only serves H.264 up to 1080p; 4K exists only as VP9 and AV1, which iOS won't put in a playable MP4. Best therefore means the best this phone can actually decode — usually 1080p.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("No account, no API key, no server. The app talks to YouTube's own internal endpoints the way NewPipe does on Android, and to SponsorBlock for segment lists. Nothing else leaves the phone, and nothing is logged anywhere but here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Downloading")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.25)))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

struct GestureHelpScreen: View {
    var body: some View {
        List {
            Section("On the video") {
                help("hand.tap", "Single tap", "Show or hide the controls")
                help("hand.tap.fill", "Double tap left / right", "Back or forward 10 seconds — tap again to stack 20s, 30s…")
                help("playpause", "Double tap centre", "Play / pause")
                help("hand.point.up.left", "Press and hold", "Temporary 2× speed; release to return")
                help("arrow.left.and.right", "Drag sideways", "Scrub with a live preview")
            }
            Section("Elsewhere") {
                help("star", "Swipe a row right", "Star an item")
                help("checkmark.circle", "Swipe a row left", "Mark watched / unwatched")
                help("hand.tap", "Long-press a row", "Queue, playlist and progress actions")
                help("lock.iphone", "Lock the phone", "Audio keeps playing; use the Lock Screen controls")
                help("moon.stars", "Screen off", "In the player's ⋯ menu — blacks out the display, keeps audio")
            }
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func help(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
