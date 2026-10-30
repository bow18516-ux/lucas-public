import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C14: the tenant token is stored with its expiry, refreshed before it dies,
/// and still usable after a daemon restart (it is read from disk, not memory).
final class FeishuMockURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: [String: Any]
    }

    static var handler: ((URLRequest) -> Reply)?
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    static func recorded() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        FeishuMockURLProtocol.lock.lock()
        FeishuMockURLProtocol.requests.append(request)
        let handler = FeishuMockURLProtocol.handler
        FeishuMockURLProtocol.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "mock", code: 0))
            return
        }
        let reply = handler(request)
        let data = try? JSONSerialization.data(withJSONObject: reply.body)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://open.feishu.cn")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FeishuTokenTests: XCTestCase {
    private var root: URL!
    private var store: KernelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-feishu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FeishuChannel.ensureDirectories(root)
        try FeishuAuthStore.ensureSchema(at: FeishuChannel.authSQLiteURL(under: root))
        store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        try store.secrets.setSecret("app-id", for: KernelStore.feishuAppIDAccount)
        try store.secrets.setSecret("app-secret", for: KernelStore.feishuAppSecretAccount)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeChannel() -> FeishuChannel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeishuMockURLProtocol.self]
        let channel = FeishuChannel(store: store, supportDirectory: root)
        channel.httpSession = URLSession(configuration: configuration)
        return channel
    }

    private func seedToken(_ token: String, expiresIn: TimeInterval) throws {
        try store.secrets.setSecret(token, for: KernelStore.feishuTenantAccessTokenAccount)
        let store = FeishuAuthStore(path: FeishuChannel.authSQLiteURL(under: root).path)
        try store.upsert(
            reference: FeishuChannel.tokenExpireReference,
            secret: String(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        )
    }

    private func tokenEndpoint(_ request: URLRequest) -> Bool {
        request.url?.path.contains("tenant_access_token") == true
    }

    func testNearExpiryTokenIsRefreshedBeforeSending() async throws {
        try seedToken("stale", expiresIn: 60)  // inside the 5 minute window
        let channel = makeChannel()
        FeishuMockURLProtocol.reset { request in
            if self.tokenEndpoint(request) {
                return .init(status: 200, body: ["code": 0, "tenant_access_token": "fresh", "expire": 7200])
            }
            return .init(status: 200, body: ["code": 0])
        }

        let result = try await channel.sendTextAsync(text: "hello", receiveID: "ou_test")
        XCTAssertEqual(result["delivered"]?.boolValue, true)

        let requests = FeishuMockURLProtocol.recorded()
        XCTAssertTrue(requests.contains(where: tokenEndpoint), "a stale token must be refreshed first")
        let sendRequest = try XCTUnwrap(requests.last { !self.tokenEndpoint($0) })
        XCTAssertEqual(sendRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(sendRequest.url?.query, "receive_id_type=open_id")
    }

    func testValidTokenSurvivesRestartWithoutRefresh() async throws {
        try seedToken("persisted", expiresIn: 3_600)
        // A brand new channel on the same store stands in for a restarted daemon.
        let restarted = makeChannel()
        FeishuMockURLProtocol.reset { request in
            if self.tokenEndpoint(request) {
                return .init(status: 500, body: ["code": -1, "msg": "should not refresh"])
            }
            return .init(status: 200, body: ["code": 0])
        }

        let status = try restarted.status()
        XCTAssertEqual(status["connected"]?.boolValue, true, "a valid on-disk token means connected")

        let result = try await restarted.sendTextAsync(text: "after restart", receiveID: "ou_test")
        XCTAssertEqual(result["delivered"]?.boolValue, true)
        XCTAssertFalse(
            FeishuMockURLProtocol.recorded().contains(where: tokenEndpoint),
            "a still-valid token must not be refreshed"
        )
    }

    func testRejectedTokenIsRefreshedOnceAndRetried() async throws {
        try seedToken("will-be-rejected", expiresIn: 3_600)
        let channel = makeChannel()
        var tokenCalls = 0
        FeishuMockURLProtocol.reset { request in
            if self.tokenEndpoint(request) {
                tokenCalls += 1
                return .init(status: 200, body: ["code": 0, "tenant_access_token": "second", "expire": 7200])
            }
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer second" {
                return .init(status: 200, body: ["code": 0])
            }
            return .init(status: 200, body: ["code": 99991663, "msg": "token invalid"])
        }

        let result = try await channel.sendTextAsync(text: "retry", receiveID: "ou_test")
        XCTAssertEqual(result["delivered"]?.boolValue, true)
        XCTAssertEqual(tokenCalls, 1)
    }
}
