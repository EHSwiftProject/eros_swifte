/// Why a tag translation database file was not imported, or why the store could not answer. The store keeps its
/// previous data and version, except that a damaged file is replaced the next time a store opens it (`damaged`).
public enum TagDatabaseError: Error, Equatable {
    /// The data starts like a gzip archive but is truncated, damaged or not a single DEFLATE member.
    case corruptArchive
    /// The data is not a JSON object with a `data` array (an HTML error page, a GitHub `{"message":…}`, …).
    case malformedJSON
    /// The file holds no valid entry.
    case empty
    /// Plain JSON larger than `Gzip.maximumSize` (64 MiB), the most an archive may hold once decompressed; it is not
    /// parsed.
    case tooLarge
    /// SQLite found the database file damaged (`SQLITE_CORRUPT` and its extended codes, `SQLITE_NOTADB`) while the
    /// store used it: an import or a read met a damaged page. The store has marked the file
    /// (`TagTranslations.sqlite.rebuild` beside it): the next store opened on it deletes it and starts empty (the
    /// use times of the suggestions go with it), and the database is downloaded again. Until then every import, and
    /// every read that meets the damage, throws this. A store in memory marks nothing.
    case damaged
}
