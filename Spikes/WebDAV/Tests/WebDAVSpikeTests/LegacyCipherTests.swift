import Foundation
import Testing
import WebDAVSpike

/// Golden vectors come from encrypt 5.0.3 (`golden/bin/generate.dart`).
@Suite("LegacyCipher")
struct LegacyCipherTests {
    static let encryptable = Fixtures.cipherVectors.vectors.filter { $0.ciphertextBase64 != nil }

    @Test func goldenWasGeneratedWithTheLegacyConstants() {
        #expect(Fixtures.cipherVectors.key == LegacyCipher.keyString)
        #expect(Fixtures.cipherVectors.iv == LegacyCipher.ivString)
        #expect(Fixtures.cipherVectors.algorithm.hasPrefix("AES/SIC/PKCS7"))
        #expect(LegacyCipher.keyBytes.count == 24, "24 UTF-8 bytes select AES-192")
        #expect(LegacyCipher.ivBytes == [UInt8](repeating: 0x30, count: 16))
    }

    @Test func goldenCoversTheRequiredPlaintexts() {
        let lengths = Set(Fixtures.cipherVectors.vectors.map(\.utf8Length))
        #expect(lengths.isSuperset(of: [0, 15, 16, 17]))
        #expect(Fixtures.cipherVectors.vectors.contains { $0.plaintext.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0xFFFF } })
        #expect(Fixtures.cipherVectors.vectors.contains { $0.name == "history-json" })
    }

    @Test(arguments: encryptable)
    func decryptsGoldenCiphertext(_ vector: CipherVectors.Vector) throws {
        #expect(try LegacyCipher.decrypt(try #require(vector.ciphertextBase64)) == vector.plaintext)
    }

    @Test(arguments: encryptable)
    func encryptReproducesGoldenCiphertext(_ vector: CipherVectors.Vector) throws {
        #expect(vector.deterministic == true, "legacy encryption uses a fixed IV")
        let ciphertext = try LegacyCipher.encrypt(vector.plaintext)
        #expect(ciphertext == vector.ciphertextBase64)
        #expect(Data(base64Encoded: ciphertext)?.count == vector.ciphertextLength)
    }

    @Test func emptyPlaintextBecomesOnePaddingBlockTheLegacyAppCanRead() throws {
        let vector = try #require(Fixtures.cipherVectors.vectors.first { $0.name == "empty" })
        #expect(vector.encryptError?.hasPrefix("RangeError") == true, "encrypt 5.0.3 throws on empty input")
        let padded = try #require(vector.paddedBlockCiphertextBase64)
        #expect(try LegacyCipher.encrypt("") == padded)
        #expect(try LegacyCipher.decrypt(padded) == vector.paddedBlockDecryptsTo)
    }

    /// Base64 inputs no encoder produces, on which Foundation and Dart's `base64.decode` disagree.
    static let knownBase64Differences: Set<String> = ["non-canonical-trailing-bits", "percent-encoded-padding"]

    @Test(arguments: Fixtures.cipherVectors.decryptCases.filter { !knownBase64Differences.contains($0.name) })
    func decryptAgreesWithTheLegacyAppOnGoldenCases(_ testCase: CipherVectors.DecryptCase) {
        if testCase.accepted {
            #expect((try? LegacyCipher.decrypt(testCase.input)) == testCase.plaintext)
        } else {
            #expect(throws: LegacyCipherError.self) { try LegacyCipher.decrypt(testCase.input) }
        }
    }

    /// Dart rejects non-zero trailing bits and accepts `%3D` as padding; Foundation does the
    /// opposite. Neither form comes out of a Base64 encoder, so this has no practical effect.
    @Test func nonCanonicalBase64IsTheOnlyDisagreement() throws {
        let cases = Dictionary(uniqueKeysWithValues: Fixtures.cipherVectors.decryptCases.map { ($0.name, $0) })
        let trailingBits = try #require(cases["non-canonical-trailing-bits"])
        #expect(!trailingBits.accepted)
        #expect(try LegacyCipher.decrypt(trailingBits.input) == "Hello, WebDAV!")

        let percentPadding = try #require(cases["percent-encoded-padding"])
        #expect(percentPadding.accepted)
        #expect(throws: LegacyCipherError.invalidBase64) { try LegacyCipher.decrypt(percentPadding.input) }
    }

    @Test func payloadStartingWithBraceIsPlainJSON() throws {
        let json = #"{"uuid":"u","name":"n"}"#
        #expect(try LegacyCipher.decodePayload(json) == json)
        #expect(try LegacyCipher.decodePayload(try LegacyCipher.encrypt(json)) == json)
    }
}
