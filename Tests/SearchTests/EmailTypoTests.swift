import XCTest
@testable import Search

/// "Did you mean …?" under the news-by-email field (EmailTypo.swift): likely
/// typos give the address they were meant to be, real addresses give
/// nothing, and the line never stops a second press. The same cases as the
/// site's scripts/email-typo.test.mjs.
final class EmailTypoTests: XCTestCase {
    func testTyposGiveTheAddressTheyWereMeantToBe() {
        let typos = [
            "name@gmail.con": "name@gmail.com",
            "name@gmail.cin": "name@gmail.com",
            "name@gnail.com": "name@gmail.com",
            "name@gmial.com": "name@gmail.com",
            "name@gmal.com": "name@gmail.com",
            "name@gamil.com": "name@gmail.com",
            "name@icloud.con": "name@icloud.com",
            "name@iclod.com": "name@icloud.com",
            "name@outlok.com": "name@outlook.com",
            "name@hotmial.com": "name@hotmail.com",
            "name@yaho.com": "name@yahoo.com",
            "name@gmail.co": "name@gmail.com",
            "Name.Last@GMAIL.CON": "Name.Last@gmail.com",
            "  name@gmail.con ": "name@gmail.com",
            "name@protonmial.com": "name@protonmail.com",
            "name@fastmial.com": "name@fastmail.com",
            "name@outlook.cmo": "name@outlook.com",
            "name@studio.col": "name@studio.com",
            "name@studio.cmo": "name@studio.com",
            "name@studio.vom": "name@studio.com",
            "name@studio.ogr": "name@studio.org",
            "name@studio.nte": "name@studio.net",
        ]
        for (typed, meant) in typos {
            XCTAssertEqual(EmailTypo.suggestion(for: typed), meant, typed)
        }
    }

    func testRealAddressesGiveNothing() {
        let fine = [
            "name@gmail.com", "name@icloud.com", "name@me.com", "name@mac.com", "name@proton.me",
            "name@pm.me", "name@hey.com", "name@web.de", "name@qq.com", "name@163.com",
            "jlyons@jlyons.co", "hello@officecommun.com", "hi@office-commun.studio", "team@studio.design",
            "name@studio.fr", "name@company.co.uk", "name@company.com.au", "name@startup.ai",
            "name@agency.io", "name@site.be", "name@site.ch", "name@site.nl", "name@lab.tech",
            "name@mail.com", "name@ymail.com", "name@foxmail.com", "name@gmx.de", "name@gmx.net",
            "name@126.com", "name@msn.com", "name@yahoo.fr", "name@hotmail.fr", "name@orange.fr",
            "name@university.edu", "name@city.gov", "name@example.org", "name@me.dev", "name@x.app",
            "", "name", "name@", "@gmail.con", "name@localhost",
        ]
        for typed in fine {
            XCTAssertNil(EmailTypo.suggestion(for: typed), typed)
        }
    }

    func testDistanceCountsASwapAsOne() {
        XCTAssertEqual(EmailTypo.distance("gmial", "gmail"), 1)
        XCTAssertEqual(EmailTypo.distance("gmal", "gmail"), 1)
        XCTAssertEqual(EmailTypo.distance("gamil", "gmail"), 1)
        XCTAssertEqual(EmailTypo.distance("abc", "abc"), 0)
        XCTAssertEqual(EmailTypo.distance("", "com"), 3)
    }

    func testTheLineShowsOnceThenTheAddressGoesAsTyped() {
        // First press: the line instead of sending.
        XCTAssertEqual(EmailTypo.hold("name@gmail.con", shownFor: nil), "name@gmail.com")
        // Second press with the same address: sent as typed.
        XCTAssertNil(EmailTypo.hold("name@gmail.con ", shownFor: "name@gmail.con"))
        // Another typo after an edit: the line again.
        XCTAssertEqual(EmailTypo.hold("name@gnail.com", shownFor: "name@gmail.con"), "name@gmail.com")
        // A good address never waits.
        XCTAssertNil(EmailTypo.hold("name@gmail.com", shownFor: nil))
    }
}
