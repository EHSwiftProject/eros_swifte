/// Identifies a gallery: the numeric gallery id and its 10-hex-digit token, as in `/g/<gid>/<token>/`.
public struct GalleryID: Sendable, Hashable, Codable {
    /// The gallery id.
    public let gid: Int
    /// The gallery token.
    public let token: String

    public init(gid: Int, token: String) {
        self.gid = gid
        self.token = token
    }
}
