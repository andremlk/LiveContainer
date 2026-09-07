import Foundation
import ApplePackage

@MainActor
final class AppStoreSearchModel: ObservableObject {
    @Published var query = "Infuse"
    @Published var countryCode = "MX"
    @Published private(set) var results: [Software] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSearchSummary = "Sin probar todavía"

    private var didRunInitialSearch = false

    func runInitialSearchIfNeeded() async {
        guard !didRunInitialSearch else { return }
        didRunInitialSearch = true
        await search()
    }

    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        lastSearchSummary = "Consultando App Store para Apple TV…"
        defer { isSearching = false }

        do {
            let found = try await Searcher.search(
                term: term,
                countryCode: countryCode,
                limit: 25,
                entityType: .appleTV
            )
            results = found
            lastSearchSummary = "OK · \(found.count) resultado(s) · tienda \(countryCode) · AppleTV"
        } catch {
            results = []
            errorMessage = String(describing: error)
            lastSearchSummary = "Falló la búsqueda"
        }
    }
}
