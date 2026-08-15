import Foundation

enum Config {
    /// Reads a value from Secrets.plist.
    /// Fatal-errors in DEBUG so you notice immediately; returns nil in RELEASE.
    static func value(for key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let value = dict[key] as? String,
              !value.isEmpty
        else {
            #if DEBUG
            fatalError(
                "⚠️ Missing key '\(key)' in Secrets.plist. "
                + "Copy Secrets.example.plist → Secrets.plist and add your keys."
            )
            #else
            return nil
            #endif
        }
        return value
    }

    static var transitLandAPIKey: String {
        value(for: "TRANSITLAND_API_KEY") ?? ""
    }
}
