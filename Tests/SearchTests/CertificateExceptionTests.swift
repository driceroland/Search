import Security
import XCTest
@testable import Search

/// "Continue Anyway" on a site with a bad certificate trusts that
/// certificate, for this launch, not the site: a different bad certificate
/// on the same name asks again (#1377).
@MainActor
final class CertificateExceptionTests: XCTestCase {
    // Two self-signed certificates for the same name, bad.test.
    private static let a = "MIIC5jCCAc6gAwIBAgIUbuxM26bvdL39hvj7S2X7U7iMtpMwDQYJKoZIhvcNAQELBQAwEzERMA8GA1UEAwwIYmFkLnRlc3QwHhcNMjYxMTIyMTcyNzE3WhcNMzYxMTE5MTcyNzE3WjATMREwDwYDVQQDDAhiYWQudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK1G8j+VgqiywQ1fe+uPh9Xh13gm9WbSDg7OfUmhEvynvPz4+Nm6JKiuxdaZThYX4S7BzVxgrDHdC9d9yPqWXwzqrLS4Dlr8dyFrGD7AKHAkfn6aesXpmUtsn0o0zSrgGZ+XS4eFV/Uk3jGnH9PGQ9zmigExKhlkiGZqbJkwBFE2XcpQ3ftOnVSy5NvzHaA9pCWchd7X5+9gmmOqpY1lzTCPkyIdKWXWrzQHGIsmoVtBJl14KInmGuO9Etxw9jo1zGLnr6aFE4/6HVx0zj8iTvv3/XQj+HUR3NePoB5JOA3DFTVxUYDlaPASuyiKN6iz62oQnMrT81Bkt+B9ikb73RMCAwEAAaMyMDAwHQYDVR0OBBYEFMQucsvD/17FWXsCdRjzdnOqQbj2MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAIh5TC9xgzjG48zl9hKEUj+vdF6U4vW6qcS8Xhcfd04hxyFQXm1FEKP6xSio7nBQ0GT1yKElxLOlh4anIkke6YQLq513sOFXw7jkKfu4EHvT9I+vBXZ5xhgaqnLPQWCfgKhHfrpTDX5RXNfsv5NSNF+Z5QEmCqKJHhzEpo9Hft/aRDFmgx+YQFcTVQb7rl/tFcdJM1D4Z1wBDhJMrvvo1nT5jDGXU6pec2VmkF6RK1B8Vrsa+mo0/OGbOCaBFhCNHxn8SeHv67cCmvvRkMZNDW+wB0b9yTgAzvByTkZrNISimKFZBG/+z3RKPApeNB3u+0VKIO0bC/+x1hjZSK9yFEU="
    private static let b = "MIIC5jCCAc6gAwIBAgIUSCSIb4fctgr82TqPQ//FFXayNUQwDQYJKoZIhvcNAQELBQAwEzERMA8GA1UEAwwIYmFkLnRlc3QwHhcNMjYxMTIyMTcyNzE3WhcNMzYxMTE5MTcyNzE3WjATMREwDwYDVQQDDAhiYWQudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAIym0KJT4032T95Nd3PZVjZQ86fTcjbEW/fC2GFd0cZQXFj/EJYpezZ8rt5hh+U/1LPahfTDgTaPdUBN8WDZkOuUjVArOBXDJ/P+nt3E8Y092Ce1cYFLQ5//7cV4IC7ZA7j+N9J1HY0sW06+jB71gjsx+pugZyoL665OPXZkfNjxPw5q8aMdudATiOVpNEwGgeIZ/imu6fKxsiS3LdNPCTXq34LtpJUY12pnW+vWSWiiymDoxYkYQCmxyfVjlU9ujNQDfrlJZAti0/4DLiyhsqaGZLKmcSZWx+ulIBKoptlBGvUDK+jPkLdtPQ1t5frotCR5kJNVkFLpDIegq7d7jkkCAwEAAaMyMDAwHQYDVR0OBBYEFMVIvOqiyh5o2ty0j7BJ+dEBTyMgMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBADfa1SZEE+6W85LyX9ZtJcIQbWpqyLbhEglL9k+ZirSEhxdws+xwhq9CW+xRdBxhrqI5wKYNBGDw1j+Z+Wkv5SxMIKSogaXQ7pde3715q8vj0n1SvuH3YjI+5fY1sfhgPsakdSAI4zB9qAvjXzVAJNMHhKp+I0dRHNHpJv721jJyZPX6obABMCaotYEPA69ckUII59hWplGIp6Ex6EkuMOuD5srKRA4F1VfiBYW6PzVBJ70CcEaHDxuwklt5Yz8+StrL8hcQtNUyB0sY8bywlpijcza7PwBT0XoysdD3KY7FeUesnL10SO5IQu22OW4cgYxunMQty9d45Ltol5y7fOw="

    private func trust(_ base64: String) throws -> SecTrust {
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "bad.test" as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    func testContinueAnywayCoversOnlyTheCertificateShown() throws {
        let saved = Dialogs.excused
        defer { Dialogs.excused = saved }
        let a = try trust(Self.a), b = try trust(Self.b)
        XCTAssertFalse(SecTrustEvaluateWithError(a, nil), "a bad certificate: the question is asked")

        // Continue Anyway on A.
        Dialogs.excused.insert(Dialogs.excuse("bad.test", a))
        XCTAssertTrue(Dialogs.excused.contains(Dialogs.excuse("bad.test", try trust(Self.a))), "A again: not asked again this launch")
        XCTAssertFalse(Dialogs.excused.contains(Dialogs.excuse("bad.test", b)), "another bad certificate on the same name: asked again")
        XCTAssertFalse(Dialogs.excused.contains(Dialogs.excuse("other.test", a)), "A on another name: asked again")
        XCTAssertFalse(Dialogs.excused.contains("bad.test"), "the name alone is never what is trusted")
    }
}
