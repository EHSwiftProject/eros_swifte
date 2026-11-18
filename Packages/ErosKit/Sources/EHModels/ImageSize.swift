/// The pixel size of an image.
public struct ImageSize: Sendable, Hashable, Codable {
    /// Width in pixels.
    public let width: Int
    /// Height in pixels.
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
