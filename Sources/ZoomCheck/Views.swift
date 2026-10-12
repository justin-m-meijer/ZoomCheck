import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SettingsView(model: model)
                .navigationSplitViewColumnWidth(min: 290, ideal: 310)
        } detail: {
            ResultsView(model: model)
        }
        .task { await model.load() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Photos library") {
                Text(model.libraryURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.libraryURL.path)
                HStack {
                    Button("Choose…", action: chooseLibrary)
                    Button("Reload") { Task { await model.load() } }
                        .disabled(model.isLoading)
                }
                if !model.records.isEmpty {
                    let videos = model.records.filter(\.isVideo).count
                    Text("\((model.records.count - videos).formatted()) iPhone photos and \(videos.formatted()) videos with zoom or lens data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Highest zoom", selection: $model.targetZoom) {
                    ForEach(AppModel.zoomOptions, id: \.self) { zoom in
                        Text(ZoomFormat.string(zoom)).tag(zoom)
                    }
                }
            } header: {
                Text("Phone to compare with")
            } footer: {
                Text("The highest zoom the other phone takes at full quality. Everything you shot above it with a telephoto lens is what you'd lose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include videos", isOn: $model.includeVideos)
                ForEach(model.availableModels, id: \.model) { entry in
                    Toggle(isOn: Binding(
                        get: { !model.excludedModels.contains(entry.model) },
                        set: { included in
                            if included { model.excludedModels.remove(entry.model) }
                            else { model.excludedModels.insert(entry.model) }
                        }
                    )) {
                        HStack {
                            Text(entry.model)
                            Spacer()
                            Text(entry.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("What")
            } footer: {
                Text("Turn off iPhones that aren't yours, e.g. a partner's photos saved to your library. Videos are classified by lens: on recent iPhones 1x and 2x share a lens, so a 2x video counts as 1x.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Where") {
                Picker("Region", selection: $model.regionID) {
                    Text("Everywhere").tag(Region.everywhereID)
                    ForEach(Region.presets) { region in
                        Text(region.name).tag(region.id)
                    }
                    Text("Custom area").tag(Region.customID)
                }
                if model.regionID == Region.customID {
                    TextField("Latitude from", value: $model.customLatMin, format: .number)
                    TextField("Latitude to", value: $model.customLatMax, format: .number)
                    TextField("Longitude from", value: $model.customLonMin, format: .number)
                    TextField("Longitude to", value: $model.customLonMax, format: .number)
                }
            }

            Section("When") {
                Toggle("Limit to a date range", isOn: $model.useDateRange)
                if model.useDateRange {
                    DatePicker("From", selection: $model.startDate, displayedComponents: .date)
                    DatePicker("To", selection: $model.endDate, displayedComponents: .date)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.message = "Choose your Photos library (.photoslibrary)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.libraryURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.libraryURL = url
            Task { await model.load() }
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    let model: AppModel

    var body: some View {
        if model.isLoading {
            ProgressView("Reading Photos library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.loadError {
            LoadErrorView(error: error) { Task { await model.load() } }
        } else if let message = model.otherError {
            ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            let result = model.result
            if result.total == 0 {
                ContentUnavailableView("No photos match", systemImage: "photo.on.rectangle",
                                       description: Text("Try another region or date range."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SummaryView(result: result, target: model.targetZoom, hasRegion: model.region != nil)
                        BucketChart(result: result, target: model.targetZoom)
                        ModelTable(rows: result.models)
                        AlbumActions(model: model, result: result)
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
    }
}

struct SummaryView: View {
    let result: AnalysisResult
    let target: Double
    let hasRegion: Bool

    var body: some View {
        let lost = result.count(.beyondTele)
        let crops = result.count(.beyondCrop)
        let targetText = ZoomFormat.string(target)
        let noun = result.videos == 0 ? "photos" : (result.photos == 0 ? "videos" : "photos and videos")

        VStack(alignment: .leading, spacing: 8) {
            Text("\(lost.formatted()) of \(result.total.formatted()) \(noun) (\(percent(result.percent(.beyondTele))))")
                .font(.system(size: 32, weight: .semibold))
            Text("were taken above \(targetText) with a telephoto lens. A phone that tops out at \(targetText) could only crop to these, at lower resolution.")
                .foregroundStyle(.secondary)
            if crops > 0 {
                Text("\(crops.formatted()) more above \(targetText) were already crops of the main camera, so the other phone can match those.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if hasRegion && result.excludedWithoutLocation > 0 {
                Text("\(result.excludedWithoutLocation.formatted()) items without location were left out. Use a date range instead to include them.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

struct BucketChart: View {
    let result: AnalysisResult
    let target: Double

    private var buckets: [Bucket] {
        Bucket.allCases.filter { !($0 == .withinTarget && target < 2) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zoom levels").font(.headline)
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Photos", result.count(bucket)),
                    y: .value("Zoom", bucket.title(target: target))
                )
                .foregroundStyle(bucket.isLoss ? Color.red : Color.accentColor)
                .annotation(position: .trailing) {
                    Text("\(result.count(bucket)) · \(String(format: "%.1f%%", result.percent(bucket)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(buckets.count) * 40)
        }
    }
}

struct ModelTable: View {
    let rows: [ModelRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per camera").font(.headline)
            Table(rows) {
                TableColumn("Camera") { Text($0.id) }
                TableColumn("Photos") { Text($0.photos.formatted()) }
                TableColumn("Videos") { Text($0.videos.formatted()) }
                TableColumn("Above target · telephoto") { Text($0.beyondTele.formatted()) }
                TableColumn("Above target · crop") { Text($0.beyondCrop.formatted()) }
            }
            .frame(height: CGFloat(min(rows.count, 8)) * 26 + 32)
        }
    }
}

struct AlbumActions: View {
    let model: AppModel
    let result: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await model.createAlbum() }
                } label: {
                    Text("Create album with these \(result.beyondTeleUUIDs.count) items")
                }
                .buttonStyle(.borderedProminent)
                .disabled(result.beyondTeleUUIDs.isEmpty || model.isCreatingAlbum)

                Button("Copy IDs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.beyondTeleUUIDs.joined(separator: "\n"), forType: .string)
                }
                .disabled(result.beyondTeleUUIDs.isEmpty)
            }
            if let status = model.albumStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct LoadErrorView: View {
    let error: PhotosDatabaseError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(error.localizedDescription)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if case .accessDenied = error {
                Text("Turn on ZoomCheck under Full Disk Access, then quit ZoomCheck (⌘Q) and open it again. ZoomCheck only reads a temporary copy of the database; your library is never modified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Try again", action: retry)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
