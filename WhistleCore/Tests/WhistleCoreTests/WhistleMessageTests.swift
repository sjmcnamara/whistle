import XCTest
@testable import WhistleCore

final class WhistleMessageTests: XCTestCase {

    private func makeMessage(content: String, createdAt: UInt64 = 1_700_000_000) -> WhistleMessage {
        WhistleMessage(
            id: "evt1",
            mlsGroupId: "abc123",
            senderPubkey: "alice",
            kind: MarmotKind.chat,
            content: content,
            createdAt: createdAt
        )
    }

    func testPayloadTypeReadsTypeDiscriminator() {
        let message = makeMessage(content: #"{"type":"nickname","name":"Alice"}"#)
        XCTAssertEqual(message.payloadType, "nickname")
    }

    func testPayloadTypeIsNilForJsonWithoutTypeField() {
        XCTAssertNil(makeMessage(content: #"{"text":"hello"}"#).payloadType)
    }

    // Plain text predates the typed payloads — callers treat a nil type as
    // ordinary chat rather than discarding the message.
    func testPayloadTypeIsNilForPlainText() {
        XCTAssertNil(makeMessage(content: "just a message").payloadType)
    }

    func testPayloadTypeIsNilForMalformedJson() {
        XCTAssertNil(makeMessage(content: #"{"type":"chat""#).payloadType)
    }

    func testPayloadTypeIsNilWhenTypeIsNotAString() {
        XCTAssertNil(makeMessage(content: #"{"type":42}"#).payloadType)
    }

    func testDateConvertsFromUnixSeconds() {
        XCTAssertEqual(
            makeMessage(content: "hi", createdAt: 1_700_000_000).date,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
