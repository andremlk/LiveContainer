import SwiftUI
import ApplePackage

struct ContentView: View {
    @StateObject private var model = AppStoreSearchModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                controls
                status
                results
            }
            .padding(.horizontal, 54)
            .padding(.vertical, 36)
            .navigationTitle("IPATool TV")
        }
        .task {
            await model.runInitialSearchIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("App Store para tvOS")
                    .font(.title2.bold())
                Text("MVP 0.1 · ApplePackage · EntityType.appleTV")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.countryCode) Store")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            TextField("Buscar app de Apple TV", text: $model.query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .onSubmit {
                    Task { await model.search() }
                }

            Picker("Tienda", selection: $model.countryCode) {
                Text("México").tag("MX")
                Text("Estados Unidos").tag("US")
                Text("España").tag("ES")
            }
            .frame(width: 260)

            Button {
                Task { await model.search() }
            } label: {
                Label("Buscar", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSearching)
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 12) {
            if model.isSearching {
                ProgressView()
            } else {
                Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
            }

            Text(model.lastSearchSummary)
                .font(.callout.monospaced())

            Spacer()
        }
        .padding(.horizontal, 16)

        if let error = model.errorMessage {
            ScrollView(.horizontal) {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(model.results) { app in
                    NavigationLink {
                        AppDetailView(app: app)
                    } label: {
                        AppRow(app: app)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct AppRow: View {
    let app: Software

    var body: some View {
        HStack(spacing: 22) {
            AsyncImage(url: URL(string: app.artworkUrl)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        RoundedRectangle(cornerRadius: 22).fill(.thinMaterial)
                        Image(systemName: "appletv")
                            .font(.system(size: 34))
                    }
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 24))

            VStack(alignment: .leading, spacing: 7) {
                Text(app.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(app.artistName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 16) {
                    Label(app.version, systemImage: "shippingbox")
                    Label(app.minimumOsVersion, systemImage: "appletv")
                    if app.averageUserRating > 0 {
                        Label(String(format: "%.1f", app.averageUserRating), systemImage: "star.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(app.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct AppDetailView: View {
    let app: Software

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 26) {
                    AsyncImage(url: URL(string: app.artworkUrl)) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 28).fill(.thinMaterial)
                                Image(systemName: "appletv").font(.system(size: 48))
                            }
                        }
                    }
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 30))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.name).font(.largeTitle.bold())
                        Text(app.artistName).font(.title3).foregroundStyle(.secondary)
                        Text(app.bundleID).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text("Versión \(app.version) · tvOS mínimo \(app.minimumOsVersion)")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text(app.description)
                    .font(.body)

                Divider()

                Text("Esta primera compilación solo valida búsqueda real de apps tvOS. El siguiente paso es autenticación Apple ID + 2FA y luego descarga del IPA.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(54)
        }
        .navigationTitle(app.name)
    }
}
