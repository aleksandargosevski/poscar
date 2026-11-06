import Foundation
import Testing
@testable import PoscarCore

@Suite struct GoogleOAuthTests {
    @Test func readsEmailAndNameFromIDToken() throws {
        let claims = #"{"email":"ana@gmail.com","name":"Ana Petrović","sub":"1"}"#
        let token = "eyJhbGciOiJSUzI1NiJ9." + Data(claims.utf8).base64URLEncoded + ".signature"
        let identity = try #require(GoogleOAuth.decodeIdentity(token))
        #expect(identity["email"] as? String == "ana@gmail.com")
        #expect(identity["name"] as? String == "Ana Petrović")
    }

    @Test func roundTripsBase64URL() {
        let data = Data([0xfb, 0xff, 0x00, 0x10, 0x3e])
        #expect(!data.base64URLEncoded.contains("="))
        #expect(Data(base64URLEncoded: data.base64URLEncoded) == data)
    }

    @Test func accountsSavedBeforeGoogleSignInUsePasswords() throws {
        let json = #"""
        [{"id":"a","kind":"gmail","name":"A","email":"a@gmail.com","username":"a@gmail.com",
          "imap":{"host":"imap.gmail.com","port":993,"security":"tls"},
          "smtp":{"host":"smtp.gmail.com","port":465,"security":"tls"},
          "colorIndex":0,"signature":"","notificationsEnabled":true}]
        """#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        #expect(accounts.first?.usesGoogleOAuth == false)
    }

    @Test func loopbackReceivesTheBrowserRedirect() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        #expect(receiver.port > 0)

        async let callback = receiver.waitForCallback(timeout: 10)
        let url = URL(string: "http://127.0.0.1:\(receiver.port)/?code=4%2Fabc&state=xyz")!
        let (body, response) = try await URLSession.shared.data(from: url)

        let query = try await callback
        #expect(query["code"] == "4/abc")
        #expect(query["state"] == "xyz")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("signed in"))
    }
}
