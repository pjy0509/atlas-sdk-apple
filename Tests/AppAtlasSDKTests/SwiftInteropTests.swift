import XCTest

import AppAtlasSDK

/// Swift consumes this SDK as a module — the SPM-generated module map for
/// `include`, or the one CocoaPods writes under `use_frameworks!`. A bridging
/// header is an app's business, never a library's, and nothing here needs one.
///
/// What this holds in place is the shape Swift sees: the names the other Atlas
/// SDKs use, the optionality the nullability annotations promise, and a
/// listener that reads as a trailing closure.
final class SwiftInteropTests: XCTestCase {

    func testTheNamesMatchTheOtherSdks() {
        // ATLLink/ATLLinks/ATLCore wear the prefix only because Objective-C
        // has no namespaces; Swift is given the cross-platform names.
        XCTAssertFalse(AtlasCore.newEventId().isEmpty)
        XCTAssertNotNil(AtlasLinks.self)
    }

    func testNullabilityIsAnnotated() {
        // Without NS_ASSUME_NONNULL these would arrive as implicitly unwrapped
        // optionals and this would not compile as written.
        let eventId: String = AtlasCore.newEventId()
        XCTAssertEqual(eventId.count, 36)

        // Before `start`, both of these are genuinely absent — and say so.
        let core: AtlasCore? = Atlas.core()
        XCTAssertNil(core)

        let link: AtlasLink? = AtlasLinks.firstReferringLink()
        XCTAssertNil(link)
    }

    func testTheListenerReadsAsAClosure() {
        let received = expectation(description: "not called before a link arrives")
        received.isInverted = true

        AtlasLinks.setListener { link in
            // The fields are the same eight every SDK carries.
            _ = (link.payload, link.path, link.shortId, link.channel,
                 link.campaign, link.clickedAt, link.deferred, link.match)
            received.fulfill()
        }

        wait(for: [received], timeout: 0.2)
        AtlasLinks.setListener(nil)
    }

    func testAUrlThatIsNotOursIsRefused() {
        XCTAssertFalse(AtlasLinks.handle(URL(string: "https://appatlas.dev/settings")!))
    }
}
