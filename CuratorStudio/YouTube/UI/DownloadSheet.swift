import SwiftUI
import UIKit

/// Quality + destination, then go. The folder list is the app's own library tree — the same
/// grammar the Telegram bot used to take ("mid Learn Stuff/AI"), just as taps.
struct DownloadSheet: View {

    let video: StreamInfoItem
    /// Known formats, when the sheet is opened from a video that's already been resolved — lets
    /// the picker grey out qualities YouTube isn't offering for this one.
    var availableQualities: [DownloadQuality]?

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var quality: DownloadQuality = .mid
    @State private var folder: String = ""
    @State private var newFolder = ""
    @State private var creatingFolder = false

    private var folderChoices: [String] {
        var all = Set(library.allFolderPaths)
        if !folder.isEmpty { all.insert(folder) }
        if !downloads.defaultFolder.isEmpty { all.insert(downloads.defaultFolder) }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 11) {
                        RemoteThumbnail(url: video.thumbnailURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title).font(.subheadline.weight(.medium)).lineLimit(3)
                            if !video.channelName.isEmpty {
                                Text(video.channelName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Quality") {
                    ForEach(DownloadQuality.allCases) { option in
                        let unavailable = availableQualities.map { !$0.contains(option) } ?? false
                        Button {
                            quality = option
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .frame(width: 26)
                                    .foregroundStyle(quality == option ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    Text(unavailable ? "Not offered for this video" : option.detail)
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
                        .disabled(unavailable)
                        .opacity(unavailable ? 0.45 : 1)
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
                    Text("Lands straight in your library folder. Use / to nest, e.g. Learn Stuff/German.")
                }

                Section {
                    Button {
                        downloads.enqueue(video: video, quality: quality, folder: folder)
                        downloads.defaultQuality = quality
                        downloads.defaultFolder = folder
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    } label: {
                        Label("Download to this iPhone", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Download")
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
            .onAppear {
                quality = downloads.defaultQuality
                folder = downloads.defaultFolder
                if let available = availableQualities, !available.contains(quality) {
                    quality = available.last ?? .mid
                }
            }
        }
    }
}

/// Paste one link or a hundred. Kept from the Mac era because it's still the fastest way to move
/// a list of links you already have — only now nothing leaves the phone.
struct AddLinkSheet: View {

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var quality: DownloadQuality = .mid
    @State private var folder = ""
    @State private var newFolder = ""
    @State private var creatingFolder = false
    @State private var isWorking = false
    @State private var showingFileImporter = false
    @State private var fileImportError: String?

    /// Every link in the box, whether that's one pasted URL or a whole batch.
    private var links: [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && YouTubeService.parse(link: $0) != nil }
    }

    private var folderChoices: [String] {
        var all = Set(library.allFolderPaths)
        if !folder.isEmpty { all.insert(folder) }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        TextField(
                            "https://youtube.com/watch?v=… — a video, a playlist, or many at once",
                            text: $text, axis: .vertical
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...8)

                        VStack(spacing: 14) {
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: { Image(systemName: "doc.on.clipboard") }
                            Button {
                                showingFileImporter = true
                            } label: { Image(systemName: "doc.badge.plus") }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    if links.count > 1 {
                        Label("\(links.count) links found — all going to one folder.",
                              systemImage: "square.stack.3d.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Link")
                } footer: {
                    Text("Video links, Shorts, and playlist links all work — a playlist queues every video in it.")
                }

                Section("Quality") {
                    Picker("Quality", selection: $quality) {
                        ForEach(DownloadQuality.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(quality.detail).font(.caption2).foregroundStyle(.secondary)
                }

                Section("Destination") {
                    Picker("Folder", selection: $folder) {
                        Text("Library root").tag("")
                        ForEach(folderChoices, id: \.self) { name in Text(name).tag(name) }
                    }
                    .pickerStyle(.navigationLink)
                    Button {
                        creatingFolder = true
                    } label: {
                        Label("New folder…", systemImage: "folder.badge.plus")
                    }
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Label(
                                links.count > 1 ? "Queue \(links.count) links" : "Queue download",
                                systemImage: "arrow.down.circle.fill"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(links.isEmpty || isWorking)
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
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, .commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let fileURL = urls.first else { return }
                    let scoped = fileURL.startAccessingSecurityScopedResource()
                    defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                    if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
                        text = contents
                    } else {
                        fileImportError = "That file isn't plain text."
                    }
                case .failure(let error):
                    fileImportError = error.localizedDescription
                }
            }
            .alert("Couldn't read that file", isPresented: Binding(
                get: { fileImportError != nil },
                set: { if !$0 { fileImportError = nil } }
            )) {
                Button("OK") { fileImportError = nil }
            } message: {
                Text(fileImportError ?? "")
            }
            .onAppear {
                quality = downloads.defaultQuality
                folder = downloads.defaultFolder
            }
        }
    }

    private func start() {
        let batch = links
        isWorking = true
        downloads.defaultQuality = quality
        downloads.defaultFolder = folder
        Task {
            for link in batch {
                await downloads.enqueue(link: link, quality: quality, folder: folder)
            }
            isWorking = false
            dismiss()
        }
    }
}
