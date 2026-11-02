import XCTest
@testable import PairDesk

final class CallHandRaiseTests: XCTestCase {
    func testRaisedAndLoweredMessagesRoundTrip() throws {
        for raised in [true, false] {
            let original = CallHandRaiseMessage(raised: raised)
            XCTAssertEqual(CallHandRaiseMessage.decode(try original.encoded()), original)
        }
    }

    func testDecodeRejectsMalformedOversizedAndUnsupportedMessages() {
        XCTAssertNil(CallHandRaiseMessage.decode(Data("not-json".utf8)))
        XCTAssertNil(CallHandRaiseMessage.decode(Data(repeating: 0x20, count: CallHandRaiseMessage.maximumWireBytes + 1)))
        XCTAssertNil(CallHandRaiseMessage.decode(Data(#"{"version":2,"raised":true}"#.utf8)))
    }
}
