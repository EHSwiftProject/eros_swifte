/// Names of the site cookies the app reads, writes or sends.
public enum CookieNames {
    /// Cookies sent first, in this order, to e-hentai.org, exhentai.org and their subdomains (Flutter's set).
    public static let injected: [String] = [
        memberID, passHash, igneous, "hath_perks", "sk", "star", "yay", "iq", clearance, duid,
    ]
    /// The site profile; each site keeps its own.
    public static let profile = "sp"
    public static let memberID = "ipb_member_id", passHash = "ipb_pass_hash", igneous = "igneous", clearance = "cf_clearance"

    static let duid = "cf_duid"
    /// Whether Cloudflare binds the cookie `name` to the user agent (and client) it was issued for: `cf_clearance`,
    /// `cf_duid`, `__cf_bm`, `_cfuvid` and every name starting with `cf_chl`.
    ///
    /// User decision 2026-11-05: no `cf_clearance` taken from elsewhere is injected into a WebView, and with a UA
    /// that does not match the WebView's (the Chrome fallback) Cloudflare cookies are not shared between the two
    /// sides. The same predicate decides where these cookies stay out: the WebView push, the pull on the fallback,
    /// the Cookie header on the fallback, the removal when the WebKit UA changes, the EH-to-EX copy at login, and
    /// the session consistency check.
    public static func isUserAgentBound(_ name: String) -> Bool {
        name == clearance || name == duid || name == "__cf_bm" || name == "_cfuvid" || name.hasPrefix("cf_chl")
    }
    /// "Never warn" for content warnings; every site request sends `nw=1` itself, so the jar never stores it (the
    /// WebView session bridge sets `nw=1` in the WebView the same way).
    public static let noWarning = "nw"
    /// The igneous value EX sends to an account without access; never written back (as Flutter).
    static let mysteryIgneous = "mystery"
}
