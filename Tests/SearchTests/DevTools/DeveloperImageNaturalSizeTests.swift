import XCTest
@testable import Search

/// WebKit reports a scaled-down image's decoded size as its naturalWidth;
/// the audits take the file's size from a probe instead.
final class DeveloperImageNaturalSizeTests: XCTestCase {
    private let images: [[String: Any]] = [
        // 1200×1200 shown at 40×40 on a 1.75× screen: reported as 70×70.
        ["src": "http://127.0.0.1/big.png", "nw": 70, "nh": 70, "dw": 40, "dh": 40],
        // Reported larger than shown: WebKit didn't scale it.
        ["src": "http://127.0.0.1/hero.jpg", "nw": 2000, "nh": 1000, "dw": 400, "dh": 200],
        ["src": "data:image/png;base64,AAAA", "nw": 1, "nh": 1, "dw": 1, "dh": 1],
    ]

    func testOnlyImagesNoBiggerThanShownAreProbed() {
        XCTAssertEqual(DeveloperImageNaturalSize.suspects(images, ratio: 1.75), ["http://127.0.0.1/big.png"])
    }

    func testAProbedSizeReplacesASmallerReportedOne() {
        let corrected = DeveloperImageNaturalSize.corrected(images, sizes: [
            "http://127.0.0.1/big.png": (1200, 1200),
            "http://127.0.0.1/hero.jpg": (10, 10),
        ])
        XCTAssertEqual(corrected[0]["nw"] as? Double, 1200)
        XCTAssertEqual(corrected[0]["nh"] as? Double, 1200)
        XCTAssertEqual(corrected[1]["nw"] as? Int, 2000, "a smaller probe never shrinks an image")
    }
}
