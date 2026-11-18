import CommonCrypto
import Foundation

/// Errors from ``LegacyCipher``.
public enum LegacyCipherError: Error, Equatable, Sendable {
    /// Foundation could not decode the text as Base64 (standard or URL-safe alphabet). Dart's
    /// `base64.decode` rejects the same inputs except for non-canonical ones, see ``LegacyCipher``.
    case invalidBase64
    /// Ciphertext empty or not a multiple of the 16-byte block size; the legacy app rejects it too.
    case invalidLength(Int)
    /// PKCS7 padding check failed, as in pointycastle `PKCS7Padding.padCount`.
    case invalidPadding
    /// CommonCrypto returned an error status. Not expected with the fixed key and IV.
    case cryptor(Int32)
    /// CommonCrypto reported success but produced a different number of bytes than it was given.
    case unexpectedOutputLength(expected: Int, actual: Int)
}

/// Byte-compatible re-implementation of the Flutter app's WebDAV payload encoding.
///
/// The app builds `Encrypter(AES(Key.fromUtf8(kAESKey)))` and calls
/// `encrypt(text, iv: IV.fromUtf8(kAESIV)).base64` (webdav_controller.dart:35-36, 163-165, 293).
/// In encrypt 5.0.3 `AES()` defaults to `mode: AESMode.sic, padding: 'PKCS7'`
/// (encrypt-5.0.3/lib/src/algorithms/aes.dart:11), which pointycastle runs as
/// `PaddedBlockCipher('AES/SIC/PKCS7')`: the UTF-8 text is PKCS7-padded to whole 16-byte
/// blocks and then XORed with an AES-CTR key stream whose 128-bit big-endian counter starts at
/// the IV. The 24-byte key selects AES-192.
///
/// The key and IV are public constants in the open-source app, so this is obfuscation, not
/// encryption: anyone can decrypt the files, and equal plaintext prefixes give equal ciphertext
/// prefixes because the IV never changes.
public enum LegacyCipher {
    /// `kAESKey` (webdav_controller.dart:35).
    public static let keyString = "fehviewer is very good!!"
    /// `kAESIV` (webdav_controller.dart:36).
    public static let ivString = "0000000000000000"

    public static var keyBytes: [UInt8] { Array(keyString.utf8) }
    public static var ivBytes: [UInt8] { Array(ivString.utf8) }

    private static let blockSize = kCCBlockSizeAES128

    /// Encrypts `plaintext` and returns standard Base64, as `Encrypted.base64` does.
    ///
    /// encrypt 5.0.3 throws a `RangeError` for an empty string; this returns the single
    /// padding block a correct PKCS7 implementation produces, which the legacy app decrypts
    /// to an empty string.
    public static func encrypt(_ plaintext: String) throws -> String {
        Data(try encrypt(bytes: Array(plaintext.utf8))).base64EncodedString()
    }

    /// Decrypts a Base64 ciphertext the way `Encrypter.decrypt64` does.
    public static func decrypt(_ base64: String) throws -> String {
        // Dart decodes with allowMalformed: true; String(decoding:) also substitutes U+FFFD.
        String(decoding: try decrypt(bytes: try decodeBase64(base64)), as: UTF8.self)
    }

    /// PKCS7-pads and applies the AES-192-CTR key stream.
    public static func encrypt(bytes: [UInt8]) throws -> [UInt8] {
        let padCount = blockSize - bytes.count % blockSize
        return try applyKeyStream(bytes + [UInt8](repeating: UInt8(padCount), count: padCount))
    }

    /// Applies the key stream and strips PKCS7 padding with pointycastle's checks.
    public static func decrypt(bytes: [UInt8]) throws -> [UInt8] {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: blockSize) else {
            throw LegacyCipherError.invalidLength(bytes.count)
        }
        let padded = try applyKeyStream(bytes)
        let padCount = Int(padded[padded.count - 1])
        guard (1...blockSize).contains(padCount),
              padded.suffix(padCount).allSatisfy({ $0 == UInt8(padCount) }) else {
            throw LegacyCipherError.invalidPadding
        }
        return Array(padded.dropLast(padCount))
    }

    /// The payload rule of `downloadHistory`, `downloadRead` and `downloadGroupProfile`
    /// (webdav_controller.dart:326-331, 398-403, 477-482): text that starts with `{` is plain
    /// JSON, anything else is Base64 ciphertext.
    public static func decodePayload(_ fileText: String) throws -> String {
        fileText.hasPrefix("{") ? fileText : try decrypt(fileText)
    }

    /// Dart's `base64.decode` accepts the standard and the URL-safe alphabet, requires padding to a
    /// multiple of four and rejects whitespace; so does this. They differ only on input no Base64
    /// encoder produces: Foundation accepts non-zero trailing bits (`QR==`, `QUJ=`), which Dart
    /// rejects, and Dart accepts `%3D` as padding (`QQ%3D%3D`), which Foundation rejects.
    private static func decodeBase64(_ text: String) throws -> [UInt8] {
        let standard = String(text.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 })
        guard let data = Data(base64Encoded: standard) else { throw LegacyCipherError.invalidBase64 }
        return Array(data)
    }

    /// CTR is its own inverse, so encryption and decryption share this.
    private static func applyKeyStream(_ input: [UInt8]) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        let key = keyBytes
        let iv = ivBytes
        var status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE), &cryptor
        )
        guard status == kCCSuccess, let cryptor else { throw LegacyCipherError.cryptor(status) }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw LegacyCipherError.cryptor(status) }
        guard moved == input.count else {
            throw LegacyCipherError.unexpectedOutputLength(expected: input.count, actual: moved)
        }
        return output
    }
}
