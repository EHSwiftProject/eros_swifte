/// Why a page could not be parsed. Each case names a field or a selector, never page content.
public enum ParseError: Error, Equatable {
    /// A required field or element is missing (the site may have changed its markup).
    case missing(String)
    /// A field is present but its value cannot be read.
    case malformed(String)
    /// The page says the content is not available (removed, expunged, not found, …).
    case unavailable(String)
    /// The page says it is shown to signed-in accounts only ("This page requires you to log on."): the site saw no
    /// session, or no longer accepts it. Not an empty result; the user has to log in again.
    case loginRequired
}

/// Why an `api.php` answer is not a result.
public enum APIError: Error, Equatable {
    /// The answer is a JSON object `{"error": …}`; carries the server's message.
    case server(String)
    /// The answer is not a JSON object: not JSON at all, or JSON of another kind (an array, a string, a number).
    case notJSON
}
