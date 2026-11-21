#!/usr/bin/env python3
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "ThreeOneOSFive/BigVipAccount.swift").read_text()
models = source[source.index("struct BigVipUser"):source.index("private enum BigVipKeychain")]
auth = source[source.index("@MainActor final class BigVipAuth"):source.index("@MainActor final class BigVipPreferences")]
stub = '''
@MainActor private enum BigVipKeychain {
    static var cached: String?
    static func read() -> String? { cached }
    static func write(_ token: String?) { cached = token }
}
final class TrapProtocol: URLProtocol {
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {}
}
'''
test = '''
@main struct AuthTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrapProtocol.self]
        let session = URLSession(configuration: config)
        let auth = BigVipAuth(session: session)
        auth.serverURL = "https://test.invalid"
        precondition(!auth.signInWithKey("wrong") && auth.user == nil)
        precondition(auth.signInWithKey("bigvip"))
        precondition(auth.user != nil && auth.isLocalKeySession && !auth.isAdmin)
        try await auth.requireActive()
        await auth.restoreSession()
        auth.expireIfNeeded()
        precondition(auth.user != nil)
        do { _ = try await auth.request("v1/admin/users"); fatalError("Local key cannot call admin API") }
        catch { precondition((error as? BigVipAPIError)?.errorDescription == "admin_required") }
        await auth.signOut()
        precondition(auth.user == nil && !auth.isLocalKeySession && TrapProtocol.calls == 0)
        BigVipKeychain.cached = "old-server-token"
        let restoring = BigVipAuth(session: session)
        restoring.serverURL = "https://test.invalid"
        let oldRequest = Task { await restoring.restoreSession() }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(restoring.signInWithKey("bigvip"))
        await oldRequest.value
        precondition(restoring.user != nil && restoring.isLocalKeySession && !restoring.isAdmin)
        precondition(TrapProtocol.calls == 1, "Only pending old restore may contact network")
        print("PASS: wrong key blocked, correct key enters lobby, offline actions make zero requests, no admin role, logout, stale request cannot kick out local session")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="bigvip-auth-tests-") as temp:
    p = pathlib.Path(temp) / "AuthTests.swift"
    p.write_text("import Foundation\nimport Combine\n" + models + stub + auth + test)
    exe = pathlib.Path(temp) / "AuthTests"
    subprocess.run(["swiftc", "-parse-as-library", str(p), "-o", str(exe)], check=True, timeout=180)
    subprocess.run([str(exe)], check=True, timeout=180)
