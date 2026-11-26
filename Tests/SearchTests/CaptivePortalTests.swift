import XCTest
@testable import Search

/// What counts as a gateway's doing (CaptivePortal): which failures prompt a
/// look, and which names a gateway may have put its own certificate on.
@MainActor
final class CaptivePortalTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testGatewayFailures() {
        XCTAssertTrue(CaptivePortal.looksLikeGateway(NSURLErrorTimedOut))
        XCTAssertTrue(CaptivePortal.looksLikeGateway(NSURLErrorServerCertificateUntrusted))
        XCTAssertTrue(CaptivePortal.looksLikeGateway(NSURLErrorSecureConnectionFailed))
        XCTAssertFalse(CaptivePortal.looksLikeGateway(NSURLErrorBadServerResponse))
        XCTAssertFalse(CaptivePortal.looksLikeGateway(NSURLErrorUnsupportedURL))
    }

    func testOnlyPublicNamesAreAskedAbout() {
        let portal = CaptivePortal.shared
        XCTAssertTrue(portal.mayBeIntercepted("google.com"))
        XCTAssertTrue(portal.mayBeIntercepted("Gemini.com"))
        XCTAssertFalse(portal.mayBeIntercepted("router"))
        XCTAssertFalse(portal.mayBeIntercepted("printer.local"))
        XCTAssertFalse(portal.mayBeIntercepted("192.168.1.1"))
        XCTAssertFalse(portal.mayBeIntercepted("localhost"))
    }

    func testTheGatewaysOwnNameStillGetsTheQuestion() {
        let portal = CaptivePortal.shared
        XCTAssertTrue(portal.isPortalHost("gateway.iisertvm.ac.in"))
        XCTAssertFalse(portal.mayBeIntercepted("gateway.iisertvm.ac.in"))
    }
}
