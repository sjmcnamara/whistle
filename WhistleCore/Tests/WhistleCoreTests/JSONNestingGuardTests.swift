import XCTest
@testable import WhistleCore

/// Regression coverage for the deeply-nested-JSON crash found by the
/// ClusterFuzzLite `Fuzz_LocationPayload` target: a hostile group member could
/// crash every recipient by sending a payload of nested brackets, because
/// Foundation's JSON scanner recurses without a depth cap and overflows the
/// stack. Every decoder that touches attacker-influenceable bytes must now
/// *throw* on such input rather than crash.
///
/// The 513-`[` case is the exact fuzzer testcase; the 100k case confirms the
/// guard trips long before the scanner would ever recurse (these decode calls
/// would hard-crash the test process without the guard, so a green run *is* the
/// assertion).
final class JSONNestingGuardTests: XCTestCase {

    private func nestedBrackets(_ count: Int) -> String {
        String(repeating: "[", count: count)
    }

    // MARK: - The guard itself

    func testValidateAcceptsShallowJSON() {
        XCTAssertNoThrow(try JSONNestingGuard.validate(Data(#"{"a":[1,2,{"b":3}]}"#.utf8)))
    }

    func testValidateRejectsBeyondMaxDepth() {
        let data = Data(nestedBrackets(JSONNestingGuard.maxDepth + 1).utf8)
        XCTAssertThrowsError(try JSONNestingGuard.validate(data)) { error in
            XCTAssertEqual(error as? JSONNestingGuard.GuardError, .tooDeeplyNested)
        }
    }

    func testValidateAcceptsExactlyMaxDepth() {
        // maxDepth opening brackets, balanced — allowed.
        let json = nestedBrackets(JSONNestingGuard.maxDepth)
            + String(repeating: "]", count: JSONNestingGuard.maxDepth)
        XCTAssertNoThrow(try JSONNestingGuard.validate(Data(json.utf8)))
    }

    func testValidateIgnoresBracketsInsideStrings() {
        // A chat message that literally contains many brackets must not trip
        // the guard: they are string content, not structural nesting.
        let brackets = nestedBrackets(200)
        let json = #"{"text":"\#(brackets)"}"#
        XCTAssertNoThrow(try JSONNestingGuard.validate(Data(json.utf8)))
    }

    func testValidateHandlesEscapedQuoteInsideString() {
        // An escaped quote must not prematurely end the string, which would
        // otherwise cause following brackets to be miscounted.
        let json = #"{"text":"he said \"[[[\" ok"}"#
        XCTAssertNoThrow(try JSONNestingGuard.validate(Data(json.utf8)))
    }

    // MARK: - Decoders must throw, not crash (the actual fuzzer finding)

    func testLocationPayloadThrowsOnDeeplyNestedInput() {
        XCTAssertThrowsError(try LocationPayload.from(jsonString: nestedBrackets(513)))
        XCTAssertThrowsError(try LocationPayload.from(jsonString: nestedBrackets(100_000)))
    }

    func testChatPayloadThrowsOnDeeplyNestedInput() {
        XCTAssertThrowsError(try ChatPayload.from(jsonString: nestedBrackets(513)))
        XCTAssertThrowsError(try ChatPayload.from(jsonString: nestedBrackets(100_000)))
    }

    func testJoinRequestThrowsOnDeeplyNestedInput() {
        XCTAssertThrowsError(try JoinRequest.from(jsonString: nestedBrackets(513)))
        XCTAssertThrowsError(try JoinRequest.from(jsonString: nestedBrackets(100_000)))
    }

    func testInviteCodeThrowsOnDeeplyNestedInput() {
        // InviteCode decodes base64 first, so feed base64-encoded nested JSON.
        let encoded = Data(nestedBrackets(513).utf8).base64EncodedString()
        XCTAssertThrowsError(try InviteCode.decode(from: encoded))
    }
}
