import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var ingest: IngestStore

    @State private var showingPicker = false
    @State private var showingPair = false
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
                    Text("Curator Studio only reads the folder you pick. Your Mac drops finished downloads straight into it over Wi-Fi, and you can add files by hand too.")
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
                        showingPair = true
                    } label: {
                        HStack {
                            Label("Mac downloader", systemImage: "desktopcomputer")
                            Spacer()
                            Text(ingest.connection.isOnline ? "Connected" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(ingest.connection.isOnline ? .green : .secondary)
                        }
                    }
                    Toggle("Pull finished downloads automatically", isOn: $ingest.autoPull)
                } header: {
                    Text("Ingest")
                } footer: {
                    Text("Send a YouTube link from the app, from Telegram, or from the YouTube share sheet. Your Mac downloads it in the right quality and Curator Studio picks it up over Wi-Fi.")
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
                        Label("How the Mac pipeline works", systemImage: "arrow.triangle.branch")
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
            .sheet(isPresented: $showingPair) { PairMacSheet() }
            .alert("Reset everything?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) { states.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resume positions, stars, watched marks and bookmarks will all be cleared. Your files are not touched.")
            }
        }
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
                Text("iOS has no decoder for those containers. On your Mac, the quickest fix is:")
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
                step(1, "You send a link", "From the Inbox tab, from Telegram, or from the YouTube share sheet — wherever you happen to be.")
                step(2, "Your Mac downloads it", "A small daemon runs yt-dlp with the quality you picked, strips sponsor segments, embeds the thumbnail and chapters, and converts anything iOS can't decode into H.264/AAC MP4.")
                step(3, "It lands in the right folder", "The Mac keeps the same folder names as your library, so a lesson filed under Learn Stuff/German goes there on both machines.")
                step(4, "Curator Studio picks it up", "Next time you're on your home Wi-Fi with the app open, finished files transfer straight across and appear in your library.")
                step(5, "The Mac deletes its copy", "Once a file is safely on your phone, the Mac removes it — it's a relay, not an archive. The link, title, channel and filename stay logged on the Mac either way.")
            }

            Section("Sending from Telegram") {
                Text("Message your own bot:")
                    .font(.footnote)
                Text("<link> mid Learn Stuff/AI")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Quality words: best · high · mid · low · audio. Anything else becomes the folder. Add “playlist” to take a whole playlist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Everything runs on your own machines. The Mac never opens a port to the internet — the phone reaches it over your local Wi-Fi, and Telegram is only used as a message inbox if you switch it on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Mac pipeline")
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
