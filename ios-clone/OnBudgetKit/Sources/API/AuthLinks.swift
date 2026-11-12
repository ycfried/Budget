import Foundation

/// Parse an auth-link `#fragment` (`k=v&k=v`) into a dictionary.
/// Shared by the reset (`onbudget://reset-password`) and sign-up
/// confirmation (`onbudget://email-confirmed`) deep links — both
/// arrive as `onbudget://<host>#access_token=…&refresh_token=…&type=…`.
/// A pair without `=` is ignored; a value may itself contain `=`
/// (base64 padding), so the split stops at the first one.
public enum AuthLinkFragment {
    public static func parse(_ fragment: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return values
    }
}
