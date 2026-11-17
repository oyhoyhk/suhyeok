import XCTest
@testable import AgentDeck

final class RemoteServersTests: XCTestCase {
    func testPrivateHostsAllowPlainHTTP() {
        for h in ["127.0.0.1", "localhost", "192.168.0.12", "10.1.2.3", "172.20.0.5", "100.101.102.103",
                  "my-pc.tail1234.ts.net", "desk.local", "fd12::1", "fe80::1"] {
            XCTAssertTrue(RemoteServers.privateHost(h), h)
        }
        for h in ["8.8.8.8", "172.32.0.1", "100.200.0.1", "example.com", "suhyeok.pickuma.com"] {
            XCTAssertFalse(RemoteServers.privateHost(h), h)
        }
    }

    @MainActor
    func testAddRejectsBadLinksAndRemembersServers() {
        let m = RemoteServers.shared
        let before = m.servers
        defer { for s in m.servers where !before.contains(s) { m.remove(s) } }
        XCTAssertNotNil(m.add(link: "not a link"))
        XCTAssertNotNil(m.add(link: "http://example.com/desk#pair=0123456789abcdef0123456789abcdef"), "plain http to a public host")
        XCTAssertNil(m.add(link: "http://192.168.0.12:4381/desk#pair=0123456789abcdef0123456789abcdef"))
        XCTAssertEqual(m.open?.absoluteString, "http://192.168.0.12:4381/desk#pair=0123456789abcdef0123456789abcdef")
        XCTAssertTrue(m.servers.contains { $0.origin == "http://192.168.0.12:4381" })
        XCTAssertNil(m.add(link: "https://suhyeok.example.net/desk#pair=bad"))
        XCTAssertEqual(m.open?.absoluteString, "https://suhyeok.example.net/desk", "a malformed pair fragment is dropped")
    }
}
