import Foundation

// Serving the active Codex login to another local macOS user.
//
// Codex has no long-lived token like `claude setup-token`, and its refresh
// tokens rotate: if the other user ever renewed with ours, this Mac's Codex
// would be signed out. So the other user gets an access-only `auth.json`: the
// account's current access and ID tokens with a placeholder where the refresh
// token goes. This app stays the only one that renews, and renews the active
// account early enough that the served copy never runs out mid-week.
//
// Measured against Codex CLI 0.169.0: `codex exec` runs on such a file, never
// rewrites it, and never sends the placeholder, even with `last_refresh` nine
// days old. Its access tokens live 240 hours. The other user pins its Codex
// version and checks this again before upgrading.

public enum CodexServeRefusal: Error, Equatable, Sendable {
    /// The access token has no readable expiry, so its life can't be judged.
    case unknownExpiry
    /// Under `CodexServe.withdrawBelow` left: serving it would start work that dies.
    case expiring
}

public enum CodexServe {
    /// Written where the refresh token goes. It is not a token, so a refresh
    /// attempt with it fails at the provider and rotates nothing.
    public static let placeholderRefreshToken = "vibecom-served-no-refresh"
    /// Renew the active Codex account once its access token has less than this left.
    public static let renewBelow: TimeInterval = 72 * 3600
    /// Stop serving when less than this is left and renewing failed.
    public static let withdrawBelow: TimeInterval = 24 * 3600
    /// The other user refuses to start a new job with less than this left.
    public static let consumerRefuseBelow: TimeInterval = 12 * 3600

    /// When the access token stops working, from its own `exp` claim.
    public static func expiry(of credentials: CodexCredentials) -> Date? {
        guard let claims = JWT.claims(of: credentials.accessToken), let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether the active account should be renewed before it is served.
    public static func needsRenewal(_ credentials: CodexCredentials, now: Date) -> Bool {
        guard let expiry = expiry(of: credentials) else { return true }
        return expiry.timeIntervalSince(now) < renewBelow
    }

    /// The bytes of the served `auth.json`, or why it must not be served.
    public static func payload(for credentials: CodexCredentials, now: Date) -> Result<Data, CodexServeRefusal> {
        guard let expiry = expiry(of: credentials) else { return .failure(.unknownExpiry) }
        guard expiry.timeIntervalSince(now) >= withdrawBelow else { return .failure(.expiring) }
        var served = credentials
        served.refreshToken = placeholderRefreshToken
        // An API key is a separate, unexpiring secret; it never crosses over.
        served.apiKey = nil
        guard let data = try? served.authFileJSON() else { return .failure(.unknownExpiry) }
        // Belt and braces: the real refresh token must not be anywhere in the bytes.
        if !credentials.refreshToken.isEmpty, data.range(of: Data(credentials.refreshToken.utf8)) != nil {
            return .failure(.unknownExpiry)
        }
        return .success(data)
    }
}
