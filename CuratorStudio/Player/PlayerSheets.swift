import SwiftUI

// MARK: - Speed

struct SpeedSheet: View {

    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { player.nudgeSpeed(-0.05) } label: {
                            Image(systemName: "minus.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                        Text(Fmt.speed(player.speed))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Spacer()

                        Button { player.nudgeSpeed(0.05) } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)

                    Slider(
                        value: Binding(get: { player.speed }, set: { player.setSpeed($0) }),
                        in: 0.25...3.0, step: 0.05
                    )
                } header: {
                    Text("Playback speed")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                        ForEach(PlayerModel.speedPresets, id: \.self) { value in
                            Button {
                                player.setSpeed(value)
                            } label: {
                                Text(Fmt.speed(value))
                                    .font(.footnote.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(abs(player.speed - value) < 0.001
                                                  ? Theme.accent.opacity(0.9)
                                                  : Color.white.opacity(0.1))
                                    )
                                    .foregroundStyle(abs(player.speed - value) < 0.001 ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Presets")
                }

                Section {
                    Toggle(isOn: $player.preservePitchWhenChangingSpeed) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep the pitch")
                            Text(player.preservePitchWhenChangingSpeed
                                 ? "Voices stay natural at any speed (spectral time-stretch)."
                                 : "Tape mode — faster means higher, like a record spun up.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Reset to 1×") { player.setSpeed(1.0) }
                }
            }
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Key / transposition

struct KeySheet: View {

    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Text(Fmt.semitones(player.semitones))
                            .font(.system(size: 26, weight: .bold, design: .rounded))

                        HStack(spacing: 18) {
                            Button { player.transpose(by: -1) } label: {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 42))
                            }
                            .buttonStyle(.plain)

                            Text(player.semitones == 0 ? "0" : Fmt.semitonesShort(player.semitones))
                                .font(.system(size: 44, weight: .heavy, design: .rounded))
                                .frame(minWidth: 90)
                                .monospacedDigit()

                            Button { player.transpose(by: 1) } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 42))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Theme.accent)

                        Text("A song in C would now sound in \(Fmt.transposedFrom("C", by: player.semitones))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text("Transpose")
                } footer: {
                    Text("Speed is untouched — only the key moves. Handy for playing along with a lesson recorded in a key that doesn't suit your guitar or voice.")
                }

                Section("Quick jumps") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                        ForEach(-6...6, id: \.self) { value in
                            Button {
                                player.semitones = value
                            } label: {
                                Text(Fmt.semitonesShort(value))
                                    .font(.footnote.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(player.semitones == value
                                                  ? Theme.accent.opacity(0.9)
                                                  : Color.white.opacity(0.1))
                                    )
                                    .foregroundStyle(player.semitones == value ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Fine tune")
                            Spacer()
                            Text("\(Int(player.fineCents)) cents")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $player.fineCents, in: -50...50, step: 1)
                    }
                } footer: {
                    Text("For recordings that sit slightly off concert pitch.")
                }

                Section {
                    Button("Back to original key") { player.resetKey() }
                    Toggle("Transposition engine", isOn: $player.transpositionEnabled)
                } footer: {
                    Text("Turning the engine off skips the audio processing entirely for the next file you open — use it if a particular file misbehaves.")
                }
            }
            .navigationTitle("Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Loop and bookmarks

struct LoopAndBookmarksSheet: View {

    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var states: PlaybackStateStore
    @Environment(\.dismiss) private var dismiss

    @State private var newLabel = ""
    @State private var addingBookmark = false

    private var path: String { player.current?.relativePath ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Button {
                            player.setLoopStart()
                        } label: {
                            loopChip(title: "Set A",
                                     value: player.loopStart.map(Fmt.time) ?? "—",
                                     active: player.loopStart != nil)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.setLoopEnd()
                        } label: {
                            loopChip(title: "Set B",
                                     value: player.loopEnd.map(Fmt.time) ?? "—",
                                     active: player.loopEnd != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(player.loopStart == nil)
                    }

                    if player.isLooping {
                        Button(role: .destructive) { player.clearLoop() } label: {
                            Label("Clear loop", systemImage: "xmark.circle")
                        }
                    }
                } header: {
                    Text("A–B loop")
                } footer: {
                    Text("Tap Set A where the lick starts, Set B where it ends. It repeats until you clear it — the loop region is shaded on the scrub bar.")
                }

                Section("Repeat & queue") {
                    Picker("Repeat", selection: $player.repeatMode) {
                        ForEach(RepeatMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("Shuffle", isOn: Binding(
                        get: { player.shuffleEnabled },
                        set: { _ in player.toggleShuffle() }
                    ))
                    Toggle("Autoplay next", isOn: $player.autoplayNext)
                }

                Section {
                    Button {
                        newLabel = ""
                        addingBookmark = true
                    } label: {
                        Label("Bookmark this moment (\(Fmt.time(player.currentTime)))",
                              systemImage: "bookmark")
                    }

                    ForEach(states.state(for: path).bookmarks) { mark in
                        Button {
                            player.seek(to: mark.time)
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mark.label.isEmpty ? "Bookmark" : mark.label)
                                    Text(Fmt.time(mark.time))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                states.removeBookmark(path, id: mark.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Bookmarks")
                }
            }
            .navigationTitle("Loop & marks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert("Name this bookmark", isPresented: $addingBookmark) {
                TextField("e.g. chorus riff", text: $newLabel)
                Button("Save") {
                    states.addBookmark(path, time: player.currentTime, label: newLabel)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func loopChip(title: String, value: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text(value).font(.footnote.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(active ? Theme.accent.opacity(0.85) : Color.white.opacity(0.12)))
        .foregroundStyle(active ? .black : .white)
    }
}

// MARK: - Queue

struct QueueSheet: View {

    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(player.queueTitle.isEmpty ? "Up next" : player.queueTitle) {
                    ForEach(Array(player.queue.enumerated()), id: \.element.relativePath) { index, item in
                        Button {
                            player.playQueue(player.queue, startAt: index, title: player.queueTitle)
                        } label: {
                            HStack(spacing: 10) {
                                if index == player.queueIndex {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName).lineLimit(1)
                                    Text(item.breadcrumb)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(index == player.queueIndex ? Theme.accent : .white)
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Sleep timer

struct SleepSheet: View {

    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SleepTimerOption.allCases) { option in
                        Button {
                            player.setSleepTimer(option)
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.label)
                                Spacer()
                                if player.sleepTimerOption == option {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Sleep timer")
                } footer: {
                    if let fires = player.sleepTimerFires {
                        Text("Fades out at \(fires.formatted(date: .omitted, time: .shortened)).")
                    } else {
                        Text("Playback fades out gently rather than cutting off.")
                    }
                }
            }
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - File info

struct FileInfoSheet: View {

    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var states: PlaybackStateStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let item = player.current {
                    Section("File") {
                        row("Name", item.fileName)
                        row("Folder", item.breadcrumb)
                        row("Kind", item.kind == .video ? "Video" : "Audio")
                        row("Size", Fmt.fileSize(item.fileSize))
                        row("Duration", Fmt.time(player.duration))
                        row("Modified", item.modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    Section("Playback") {
                        row("Speed", Fmt.speed(player.speed))
                        row("Key", Fmt.semitones(player.semitones))
                        row("Pitch preserved", player.preservePitchWhenChangingSpeed ? "Yes" : "No")
                        row("Output", AudioSessionManager.routeName)
                        row("Progress", "\(Int(states.state(for: item.relativePath).progressFraction * 100))%")
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
