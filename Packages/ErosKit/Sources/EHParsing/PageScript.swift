/// The API variables a page script sets (`var apiuid`, `var apikey`), read by one rule on every page that has them:
/// the gallery page (`GalleryDetailParser`) and mytags (`MyTagsParser`). One rule, so that a key the site starts
/// writing differently is read on both pages or on neither.
enum PageScript {
    /// `var apiuid = <digits>;`; nil without it.
    static func apiUID(in text: String) -> Int? {
        text.firstMatch(of: /\bvar\s+apiuid\s*=\s*([0-9]+)\s*;/).flatMap { Int($0.1) }
    }

    /// `var apikey = "<ASCII letters and digits, either case>";`; nil without it.
    static func apiKey(in text: String) -> String? {
        text.firstMatch(of: /\bvar\s+apikey\s*=\s*"([0-9A-Za-z]+)"\s*;/).map { String($0.1) }
    }
}
