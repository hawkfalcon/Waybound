import Foundation

enum Config {
    /// Reads a value from Secrets.plist. Missing keys return nil so the
    /// app can show a recovery message instead of crashing at launch.
    static func value(for key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let value = dict[key] as? String,
              !value.isEmpty
        else {
            #if DEBUG
            print(
                "⚠️ Waybound: missing key '\(key)' in Secrets.plist. "
                    + "Copy Secrets.example.plist → Secrets.plist and add your keys."
            )
            #endif
            return nil
        }
        return value
    }

    static var transitLandAPIKey: String? {
        value(for: "TRANSITLAND_API_KEY")
    }
}
