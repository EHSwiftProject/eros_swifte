import EHModels
import Foundation

/// Reads EhTagTranslation's `db.raw.json`, as Flutter's `TagTransController.updateDB` does.
///
/// The file is `{"data":[{"namespace":"female","count":…,"data":{"<key>":{"name":…,"intro":…,"links":…}, …}}, …]}`;
/// every other top-level key (`head`, `version`, `repo`) and `count` are ignored.
enum TagDatabaseFile {
    /// The entries of `json`, ready to insert in this order.
    ///
    /// Namespaces keep their order in the file; within a namespace the keys are sorted by their UTF-8 bytes, so that
    /// the row ids, and every tie broken by them, are the same on every import of the same file. Elements without a
    /// non-empty string `namespace` or an object `data`, and entries whose value is not an object, are skipped;
    /// `name`, `intro` and `links` that are missing, null or not strings read as "".
    /// - Throws: `TagDatabaseError.malformedJSON` when `json` is not a JSON object with a `data` array;
    ///   `TagDatabaseError.empty` when no entry is valid.
    static func entries(from json: Data) throws(TagDatabaseError) -> [TagTranslation] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: json)
        } catch {
            throw .malformedJSON
        }
        guard let object = root as? [String: Any], let namespaces = object["data"] as? [Any] else {
            throw .malformedJSON
        }

        var entries: [TagTranslation] = []
        for element in namespaces {
            guard let block = element as? [String: Any],
                  let namespace = block["namespace"] as? String, !namespace.isEmpty,
                  let tags = block["data"] as? [String: Any] else {
                continue
            }
            for key in tags.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard let fields = tags[key] as? [String: Any] else { continue }
                entries.append(TagTranslation(
                    namespace: namespace,
                    key: key,
                    name: fields["name"] as? String ?? "",
                    intro: fields["intro"] as? String ?? "",
                    links: fields["links"] as? String ?? ""
                ))
            }
        }
        guard !entries.isEmpty else { throw .empty }
        return entries
    }
}
