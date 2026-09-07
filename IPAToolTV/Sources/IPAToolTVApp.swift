import SwiftUI
import ApplePackage

@main
struct IPAToolTVApp: App {
    init() {
        DeviceIdentity.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum DeviceIdentity {
    private static let key = "IPAToolTV.AppStoreDeviceIdentifier"

    static func bootstrap() {
        let defaults = UserDefaults.standard
        let identifier: String

        if let saved = defaults.string(forKey: key),
           saved.count == 12,
           saved.allSatisfy({ $0.isHexDigit }) {
            identifier = saved.uppercased()
        } else {
            identifier = DeviceIdentifier.random()
            defaults.set(identifier, forKey: key)
        }

        Configuration.deviceIdentifier = identifier
    }
}
