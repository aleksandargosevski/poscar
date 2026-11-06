import Foundation
import Testing
@testable import PoscarCore

@Suite struct IMAPParserTests {
    private func parse(_ text: String) throws -> IMAPResponse {
        try IMAPResponseParser.parse(Array(text.utf8))
    }

    @Test func parsesTaggedResponses() throws {
        guard case .tagged(let tag, let status, let code, let text) = try parse("P1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)") else {
            Issue.record("expected tagged")
            return
        }
        #expect(tag == "P1")
        #expect(status == .no)
        #expect(code?.name == "AUTHENTICATIONFAILED")
        #expect(text == "Invalid credentials (Failure)")
    }

    @Test func parsesSelectCodes() throws {
        guard case .untagged(.status(.ok, let code?, _)) = try parse("* OK [UIDVALIDITY 3857529045] UIDs valid") else {
            Issue.record("expected status")
            return
        }
        #expect(code.name == "UIDVALIDITY")
        #expect(code.arguments.first?.number == 3_857_529_045)
    }

    @Test func parsesListWithModifiedUTF7() throws {
        guard case .untagged(.list(let attributes, let delimiter, let name)) = try parse(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Poslate po&AWE-te""#) else {
            Issue.record("expected list")
            return
        }
        #expect(attributes == ["\\HasNoChildren", "\\Sent"])
        #expect(delimiter == "/")
        #expect(IMAPFolder(path: name, delimiter: delimiter, attributes: attributes).displayName == "[Gmail]/Poslate pošte")
        #expect(IMAPFolder(path: name, delimiter: delimiter, attributes: attributes).specialUse == .sent)
    }

    @Test func parsesFetchWithLiteralsAndGmailAttributes() throws {
        let header = "Subject: Hi\r\nFrom: a@b.com\r\n\r\n"
        let raw = "* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) INTERNALDATE \" 3-Nov-2026 14:05:00 +0100\" RFC822.SIZE 2048 "
            + "X-GM-THRID 1780000000000000001 X-GM-LABELS (\"\\\\Inbox\" Posao \"&AWE-kola\") MODSEQ (991) "
            + "BODY[HEADER.FIELDS (SUBJECT FROM)] {\(header.utf8.count)}\r\n\(header))"
        guard case .untagged(.fetch(let sequence, let attributes)) = try parse(raw),
              let message = FetchedMessage(attributes: attributes) else {
            Issue.record("expected fetch")
            return
        }
        #expect(sequence == 12)
        #expect(message.uid == 345)
        #expect(message.isSeen && message.isFlagged)
        #expect(message.size == 2048)
        #expect(message.gmailThreadID == 1_780_000_000_000_000_001)
        #expect(message.gmailLabels == ["\\Inbox", "Posao", "škola"])
        #expect(message.modSeq == 991)
        #expect(message.header == Data(header.utf8))
        #expect(message.internalDate != nil)
    }

    @Test func parsesSearchIgnoringModseq() throws {
        guard case .untagged(.search(let uids)) = try parse("* SEARCH 2 84 882 (MODSEQ 917162500)") else {
            Issue.record("expected search")
            return
        }
        #expect(uids == [2, 84, 882])
    }

    @Test func roundTripsModifiedUTF7() {
        for name in ["Inbox", "Posao & privatno", "Škola/Đačko", "日本語"] {
            #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name)
        }
        #expect(ModifiedUTF7.encode("&") == "&-")
    }

    @Test func compressesUIDSets() {
        #expect(UIDSet.string([7, 1, 2, 3, 9, 10]) == "1:3,7,9:10")
        #expect(UIDSet.string([5]) == "5")
    }
}

@Suite struct ThreadingTests {
    @Test func repliesShareTheRootKey() {
        let root = ThreadKey.compute(messageId: "a@x", references: [], inReplyTo: nil, fallback: "1")
        let reply = ThreadKey.compute(messageId: "b@x", references: ["a@x"], inReplyTo: "a@x", fallback: "2")
        let replyToReply = ThreadKey.compute(messageId: "c@x", references: ["a@x", "b@x"], inReplyTo: "b@x", fallback: "3")
        #expect(root == reply)
        #expect(reply == replyToReply)
    }
}
