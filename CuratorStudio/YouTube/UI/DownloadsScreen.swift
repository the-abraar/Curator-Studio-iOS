import SwiftUI

/// The queue, on the phone. This is what used to be the Inbox — minus the Mac, the pairing token,
/// the Wi-Fi dependency and the "pull" step, because the file is already here when it's finished.
struct DownloadsScreen: View {

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore

    @State private var showingAddLink = false
    @State private var showingSettings = false

    var body: some View {
        List {
            if !downloads.activeJobs.isEmpty {
                Section {
                    ForEach(downloads.activeJobs) { job in
                        DownloadRow(job: job)
                    }
                } header: {
                    Text("In progress")
                } footer: {
                    Text("Transfers keep going when you leave the app or lock the phone. Merging and filing finish the next time Curator Studio is open.")
                }
            }

            if !downloads.failedJobs.isEmpty {
                Section("Failed") {
                    ForEach(downloads.failedJobs) { job in
                        DownloadRow(job: job)
                    }
                }
            }

            if !downloads.finishedJobs.isEmpty {
                Section {
                    ForEach(downloads.finishedJobs.prefix(30)) { job in
                        DownloadRow(job: job)
                    }
                } header: {
                    HStack {
                        Text("Finished")
                        Spacer()
                        Button("Clear") { downloads.clearFinished() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            if downloads.jobs.isEmpty {
                EmptyStateView(
                    symbol: "arrow.down.circle",
                    title: "Nothing downloading",
                    message: "Search YouTube, or paste a link. The phone does the whole job — download, merge, sponsor-trim, tag, file — and the video lands in your library folder.",
                    actionTitle: "Add a link",
                    action: { showingAddLink = true }
                )
                .listRowBackground(Color.clear)
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddLink = true } label: { Image(systemName: "plus.circle.fill") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showingAddLink) { AddLinkSheet() }
        .sheet(isPresented: $showingSettings) { DownloadSettingsSheet() }
        .alert("Curator Studio", isPresented: Binding(
            get: { downloads.lastMessage != nil },
            set: { if !$0 { downloads.lastMessage = nil } }
        )) {
            Button("OK") { downloads.lastMessage = nil }
        } message: {
            Text(downloads.lastMessage ?? "")
        }
    }
}

struct DownloadRow: View {

    let job: DownloadJob
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: job.stage.symbol)
                    .foregroundStyle(job.stage == .failed ? .orange
                                     : job.stage == .done ? .green : Theme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(job.quality.label)
                        Text("→ \(job.destinationDescription)")
                        if job.trimmedSeconds > 1 {
                            Text("· −\(Int(job.trimmedSeconds))s sponsor")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if job.stage.isActive {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressPill(fraction: job.fraction)
                    HStack(spacing: 6) {
                        Text(job.stage.label)
                        if job.totalBytes > 0 && job.stage == .downloading {
                            Text("· \(Fmt.fileSize(job.receivedBytes)) of \(Fmt.fileSize(job.totalBytes))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else if job.stage == .failed, let error = job.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                downloads.remove(job)
            } label: { Label("Remove", systemImage: "trash") }

            if job.stage == .failed || job.stage == .cancelled {
                Button {
                    downloads.retry(job)
                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .tint(Theme.accentDeep)
            } else if job.stage.isActive {
                Button {
                    downloads.cancel(job)
                } label: { Label("Cancel", systemImage: "xmark") }
                .tint(.gray)
            }
        }
    }
}

/// The old `config.json`, now a sheet. Same knobs, no SSH.
struct DownloadSettingsSheet: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default quality", selection: $downloads.defaultQuality) {
                        ForEach(DownloadQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("At once: \(downloads.maxConcurrent)",
                            value: $downloads.maxConcurrent, in: 1...4)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Two at a time is plenty on a phone — more just splits the same Wi-Fi.")
                }

                Section {
                    Toggle("Skip sponsor segments", isOn: $downloads.sponsorBlockEnabled)
                    if downloads.sponsorBlockEnabled {
                        ForEach(SponsorBlock.allCategories, id: \.self) { category in
                            Toggle(SponsorBlock.label(for: category), isOn: Binding(
                                get: { downloads.sponsorBlockCategories.contains(category) },
                                set: { isOn in
                                    if isOn {
                                        downloads.sponsorBlockCategories.append(category)
                                    } else {
                                        downloads.sponsorBlockCategories.removeAll { $0 == category }
                                    }
                                }
                            ))
                            .font(.subheadline)
                        }
                    }
                } header: {
                    Text("SponsorBlock")
                } footer: {
                    Text("Community-marked segments are cut out of the file itself while it's being merged. The lookup asks sponsor.ajay.app for the video id and nothing else.")
                }

                Section {
                    Toggle("Embed title, channel and artwork", isOn: $downloads.embedMetadata)
                    Toggle("Write .curator.json sidecar", isOn: $downloads.writeSidecar)
                } header: {
                    Text("Tagging")
                } footer: {
                    Text("The sidecar keeps the source link, channel and chapter list beside each file.")
                }
            }
            .navigationTitle("Download settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
