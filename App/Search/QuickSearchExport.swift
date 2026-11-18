import CoreTransferable
import EHStore
import Foundation
import UniformTypeIdentifiers

/// The quick searches as a file to share or export (search Q4; Flutter `utils/import_export.dart`): plain text, the
/// `#FEhViewer` header and one search a line (`QuickSearchFile.export(_:)`), named `QSearch_yyyyMMdd_HHmmss.txt`
/// (`QuickSearchFile.fileName(at:)`). The file is written to the temporary directory only when it is shared or
/// exported (`writeFile(at:)`).
nonisolated struct QuickSearchExport: Transferable {
    let texts: [String]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try export.writeFile())
        }
    }

    /// Writes the file for `date` to the temporary directory, as UTF-8 and atomically, in place of a file of the same
    /// name, and returns its URL.
    func writeFile(at date: Date = .now) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: QuickSearchFile.fileName(at: date))
        try Data(QuickSearchFile.export(texts).utf8).write(to: url, options: .atomic)
        return url
    }
}
