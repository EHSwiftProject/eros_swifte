import EHModels
import Foundation
import Testing

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let text = #"[null,true,false,0,1,1.5,"s",[1],{"a":null}]"#
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == .array([
            .null, .bool(true), .bool(false), .number(0), .number(1), .number(1.5), .string("s"), .array([.number(1)]),
            .object(["a": .null]),
        ]))
    }

    @Test(arguments: [
        (JSONValue.number(3), "3"), (.number(1762000210000), "1762000210000"), (.number(-2), "-2"),
        (.number(1.5), "1.5"), (.object(["a": .null]), #"{"a":null}"#),
    ])
    func integralNumbersHaveNoFraction(_ value: JSONValue, _ text: String) throws {
        #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == text)
    }
}
