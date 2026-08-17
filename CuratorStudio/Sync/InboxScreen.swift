import SwiftUI
import UIKit

struct InboxScreen: View {

    @EnvironmentObject private var ingest: IngestStore
    @EnvironmentObject private var library: LibraryStore

    @State private var showingAdd = false
    @State private var showingPair = false
    @State private var showingShelf = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection

                if !ingest.pendingRequests.isEmpty {
                    pendingSection
                }

                if !ingest.activeJobs.isEmpty {
                    Section("Downloading on your Mac") {
                        ForEach(ingest.activeJobs) { job in
                            JobRow(job: job)
                        }
                    }
                }

                if !ingest.readyJobs.isEmpty {
                    Section {
                        ForEach(ingest.readyJobs) { job in
                            JobRow(job: job)
                        }
                    } header: {
                        HStack {
                            Text("Ready to transfer")
                            Spacer()
                            Button("Pull all") {
                                Task { await ingest.pullAllReady() }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    } footer: {
                        Text("Keep Curator Studio open while files come across your Wi-Fi.")
                    }
                }

                if !ingest.failedJobs.isEmpty {
                    Section("Failed") {
                        ForEach(ingest.failedJobs) { job in
                            JobRow(job: job)
                        }
                    }
                }

                if ingest.jobs.isEmpty && ingest.pendingRequests.isEmpty {
                    Section {
                        EmptyStateView(
                            symbol: "link.badge.plus",
                            title: "Nothing in the pipe",
                            message: "Paste a YouTube link here, message your Telegram bot, or share straight from the YouTube app. Your Mac does the download and hands the file over next time you're home.",
                            actionTitle: "Add a link",
                            action: { showingAdd = true }
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if !ingest.historyJobs.isEmpty {
                    Section("Already on this iPhone") {
                        ForEach(ingest.historyJobs.prefix(15)) { job in
                            HStack(spacing: 10) {
                                Image(systemName: "iphone")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.displayTitle).lineLimit(1).font(.subheadline)
                                    Text(job.folder ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingPair = true
                        } label: {
                            Label("Connect to Mac", systemImage: "desktopcomputer")
                        }
                        Button {
                            showingShelf = true
                        } label: {
                            Label("Browse Mac library", systemImage: "externaldrive.connected.to.line.below")
                        }
                        Toggle("Pull automatically", isOn: $ingest.autoPull)
                        Button {
                            Task { await ingest.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable { await ingest.refresh() }
            .sheet(isPresented: $showingAdd) { AddLinkSheet() }
            .sheet(isPresented: $showingPair) { PairMacSheet() }
            .sheet(isPresented: $showingShelf) { MacShelfSheet() }
            .task {
                ingest.startPolling()
            }
            .onDisappear { ingest.stopPolling() }
            .alert("Curator Studio", isPresented: Binding(
                get: { ingest.lastMessage != nil },
                set: { if !$0 { ingest.lastMessage = nil } }
            )) {
                Button("OK") { ingest.lastMessage = nil }
            } message: {
                Text(ingest.lastMessage ?? "")
            }
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                showingPair = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ingest.connection.symbol)
                        .foregroundStyle(ingest.connection.isOnline ? Color.green : Theme.accent)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ingest.connection.isOnline ? ingest.connection.label : "Mac")
                            .font(.subheadline.weight(.medium))
                        Text(ingest.connection.isOnline
                             ? "Connected over Wi-Fi"
                             : ingest.connection.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var pendingSection: some View {
        Section {
            ForEach(ingest.pendingRequests) { request in
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.url).lineLimit(1).font(.subheadline)
                    Text("\(request.quality.label) → \(request.folder.isEmpty ? "library root" : request.folder)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        ingest.removePending(request.id)
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
        } header: {
            Text("Waiting for your Mac")
        } footer: {
            Text("These go out automatically the next time the Mac is reachable.")
        }
    }
}

// MARK: - Job row

struct JobRow: View {
    let job: RemoteJob
    @EnvironmentObject private var ingest: IngestStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: job.symbol)
                    .foregroundStyle(job.isFailed ? .orange : Theme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(job.quality.capitalized)
                        if let folder = job.folder, !folder.isEmpty {
                            Text("→ \(folder)")
                        }
                        if let source = job.source, source != "app" {
                            Text("· \(source)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if job.isReady, ingest.transfers[job.id] == nil {
                    Button {
                        Task { await ingest.pull(job) }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let transfer = ingest.transfers[job.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressPill(fraction: transfer.fraction)
                    Text("Transferring · \(Fmt.fileSize(transfer.received)) of \(Fmt.fileSize(transfer.total))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if job.isActive {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressPill(fraction: job.progress)
                    HStack(spacing: 6) {
                        Text(job.stage ?? job.status)
                        if let speed = job.speed, !speed.isEmpty { Text("· \(speed)") }
                        if let eta = job.eta, !eta.isEmpty { Text("· ETA \(eta)") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            } else if job.isFailed, let error = job.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await ingest.delete(job) }
            } label: { Label("Remove", systemImage: "trash") }

            if job.isFailed {
                Button {
                    Task { await ingest.retry(job) }
                } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .tint(Theme.accentDeep)
            }
        }
    }
}

// MARK: - Add link

struct AddLinkSheet: View {

    @EnvironmentObject private var ingest: IngestStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("ingest.lastQuality") private var qualityRaw = DownloadQuality.mid.rawValue
    @AppStorage("ingest.lastFolder") private var folder = "Randoms"

    @State private var url = ""
    @State private var newFolder = ""
    @State private var creatingFolder = false

    private var quality: DownloadQuality {
        DownloadQuality(rawValue: qualityRaw) ?? .mid
    }

    private var folderChoices: [String] {
        var all = Set(library.allFolderPaths)
        all.formUnion(ingest.macFolders)
        if !folder.isEmpty { all.insert(folder) }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://youtube.com/watch?v=…", text: $url, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .lineLimit(1...3)
                        Button {
                            if let pasted = UIPasteboard.general.string {
                                url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                } header: {
                    Text("Link")
                } footer: {
                    Text("YouTube and anything else yt-dlp handles. Paste a playlist URL and add the word “playlist” to grab the lot.")
                }

                Section("Quality") {
                    ForEach(DownloadQuality.allCases) { option in
                        Button {
                            qualityRaw = option.rawValue
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .frame(width: 26)
                                    .foregroundStyle(quality == option ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    Text(option.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if quality == option {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Picker("Folder", selection: $folder) {
                        Text("Library root").tag("")
                        ForEach(folderChoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Button {
                        creatingFolder = true
                    } label: {
                        Label("New folder…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("The Mac creates the folder if it doesn't exist yet, and the file lands in the matching folder here. Use / to nest, e.g. Learn Stuff/German.")
                }

                Section {
                    Button {
                        let target = url
                        let chosen = quality
                        let destination = folder
                        Task {
                            await ingest.submit(url: target, quality: chosen, folder: destination)
                            dismiss()
                        }
                    } label: {
                        Label(ingest.connection.isOnline ? "Send to Mac" : "Save for later",
                              systemImage: ingest.connection.isOnline ? "paperplane.fill" : "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add from link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("e.g. Learn Stuff/German", text: $newFolder)
                Button("Create") {
                    let clean = newFolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    guard !clean.isEmpty, (try? library.createFolder(clean)) != nil else { return }
                    folder = clean
                    newFolder = ""
                    Task { await library.rescan() }
                }
                Button("Cancel", role: .cancel) { newFolder = "" }
            }
        }
    }
}

// MARK: - Pairing

struct PairMacSheet: View {

    @EnvironmentObject private var ingest: IngestStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = MacBrowser()

    @State private var manualHost = ""
    @State private var manualPort = "8787"
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: ingest.connection.symbol)
                            .foregroundStyle(ingest.connection.isOnline ? .green : Theme.accent)
                        Text(ingest.connection.label)
                            .font(.subheadline)
                        Spacer()
                        if ingest.connection.isOnline {
                            Button("Disconnect", role: .destructive) { ingest.disconnect() }
                                .font(.caption)
                        }
                    }
                }

                Section {
                    if browser.found.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking on this Wi-Fi…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.found) { found in
                        Button {
                            manualHost = found.host
                            manualPort = String(found.port)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.name)
                                    Text("\(found.host):\(found.port)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.left.circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Macs found nearby")
                } footer: {
                    Text("Tap one to fill in the address, then paste the pairing token below.")
                }

                Section("Address") {
                    TextField("192.168.1.20", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("8787", text: $manualPort)
                        .keyboardType(.numberPad)
                }

                Section {
                    TextField("Pairing token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Token")
                } footer: {
                    Text("On your Mac run:\npython3 ~/.curator-studio/curator_daemon.py --token")
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text("Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(manualHost.isEmpty || token.isEmpty || busy)
                }
            }
            .navigationTitle("Connect to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
            .onAppear {
                browser.start()
                if let host = ingest.host {
                    manualHost = host.host
                    manualPort = String(host.port)
                }
                token = ingest.token
            }
            .onDisappear { browser.stop() }
        }
    }

    private func connect() {
        busy = true
        let host = MacHost(
            name: browser.found.first(where: { $0.host == manualHost })?.name ?? "Mac",
            host: manualHost.trimmingCharacters(in: .whitespaces),
            port: Int(manualPort) ?? 8787
        )
        let suppliedToken = token.trimmingCharacters(in: .whitespaces)
        Task {
            await ingest.pair(host: host, token: suppliedToken)
            busy = false
            if ingest.connection.isOnline { dismiss() }
        }
    }
}

// MARK: - Mac shelf

/// Browse everything the Mac already has and pull individual files across,
/// even ones you put there by hand rather than through a download job.
struct MacShelfSheet: View {

    @EnvironmentObject private var ingest: IngestStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var items: [ShelfItem] {
        guard !search.isEmpty else { return ingest.shelf }
        return ingest.shelf.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                if ingest.shelf.isEmpty {
                    EmptyStateView(symbol: "externaldrive",
                                   title: "Nothing listed",
                                   message: "Either the Mac is unreachable, or its library folder is empty.")
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    let key = "shelf:" + item.path
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline).lineLimit(2)
                                Text("\(item.folder.isEmpty ? "root" : item.folder) · \(Fmt.fileSize(item.size))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ingest.transfers[key] == nil {
                                Button {
                                    Task { await ingest.pullShelfItem(item, into: item.folder) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let transfer = ingest.transfers[key] {
                            ProgressPill(fraction: transfer.fraction)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search the Mac library")
            .navigationTitle("On your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await ingest.refreshShelf() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await ingest.refreshShelf() }
        }
    }
}
