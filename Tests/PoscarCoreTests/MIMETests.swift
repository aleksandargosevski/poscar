import Foundation
import Testing
@testable import PoscarCore

@Suite struct HeaderTests {
    @Test func decodesEncodedWords() {
        #expect(EncodedWords.decode("=?UTF-8?B?xaBhYmxvbg==?=") == "Šablon")
        #expect(EncodedWords.decode("=?iso-8859-2?Q?=A9to_je?= ovo") == "Što je ovo")
        #expect(EncodedWords.decode("=?UTF-8?Q?Pozdrav_?= =?UTF-8?Q?svima?=") == "Pozdrav svima")
        #expect(EncodedWords.decode("plain text") == "plain text")
    }

    @Test func joinsMultibyteCharacterSplitAcrossWords() {
        // "č" is C4 8D in UTF-8, split between two encoded words.
        #expect(EncodedWords.decode("=?UTF-8?Q?=C4?= =?UTF-8?Q?=8D?=") == "č")
    }

    @Test func encodesNonASCIIHeaders() {
        let encoded = EncodedWords.encodeIfNeeded("Ćao, šta ima?")
        #expect(encoded.hasPrefix("=?UTF-8?B?"))
        #expect(EncodedWords.decode(encoded) == "Ćao, šta ima?")
        #expect(EncodedWords.encodeIfNeeded("Hello") == "Hello")
    }

    @Test func unfoldsHeadersAndReadsParameters() {
        let headers = MIMEHeaders(text: "Subject: Hello\r\n world\r\nContent-Type: text/plain;\r\n\tcharset=\"utf-8\"\r\n\r\nbody")
        #expect(headers["subject"] == "Hello world")
        #expect(headers.contentType.value == "text/plain")
        #expect(headers.contentType.parameters["charset"] == "utf-8")
    }

    @Test func readsRFC2231Filenames() {
        let value = HeaderValue("attachment; filename*0*=UTF-8''%C5%A0ablon; filename*1*=.pdf")
        #expect(value.parameters["filename"] == "Šablon.pdf")
    }

    @Test func parsesAddressLists() {
        let addresses = AddressParser.parse(#""Doe, John" <john@example.com>, jane@example.com, Team: a@b.co;"#)
        #expect(addresses == [
            EmailAddress(name: "Doe, John", email: "john@example.com"),
            EmailAddress(email: "jane@example.com"),
            EmailAddress(email: "a@b.co"),
        ])
    }

    @Test func extractsMessageIDs() {
        let headers = MIMEHeaders(text: "References: <a@x> <b@y>\r\nMessage-ID: <c@z>\r\n")
        #expect(headers.messageIDs("References") == ["a@x", "b@y"])
        #expect(headers.messageIDs("Message-ID") == ["c@z"])
    }

    @Test func parsesDates() {
        let date = MailDate.parse("Tue, 3 Nov 2026 14:05:00 +0100 (CET)")
        #expect(date == ISO8601DateFormatter().date(from: "2026-11-03T13:05:00Z"))
        #expect(MailDate.parseInternal(" 3-Nov-2026 14:05:00 +0100") == date)
    }
}

@Suite struct MIMEParserTests {
    @Test func prefersHTMLAndKeepsPlainText() {
        let raw = """
        From: A <a@x.com>\r
        Subject: Hi\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        =C4=8Cao svima=\r
         ovde\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Čao</p>\r
        --b1--\r

        """
        let message = MIMEParser.parse(Data(raw.utf8))
        #expect(message.text == "Čao svima ovde")
        #expect(message.html == "<p>Čao</p>")
        #expect(message.snippet == "Čao svima ovde")
    }

    @Test func extractsAttachmentsAndInlineImages() {
        let raw = """
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/related; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/html\r
        \r
        <img src="cid:logo@x">\r
        --inner\r
        Content-Type: image/png\r
        Content-ID: <logo@x>\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw0KGgo=\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --outer--\r

        """
        let message = MIMEParser.parse(Data(raw.utf8))
        #expect(message.attachments.count == 2)
        #expect(message.visibleAttachments.map(\.filename) == ["report.pdf"])
        #expect(message.attachments[1].data == Data("%PDF-".utf8))
    }

    @Test func decodesLatin2Body() {
        var raw = Data("Content-Type: text/plain; charset=iso-8859-2\r\n\r\n".utf8)
        raw.append(contentsOf: [0xA9, 0x75, 0x6D, 0x61]) // "Šuma"
        #expect(MIMEParser.parse(raw).text == "Šuma")
    }

    @Test func convertsHTMLToText() {
        let text = HTMLText.toPlainText("<style>p{}</style><p>Hello&nbsp;<b>there</b></p><div>Line &amp; more</div>")
        #expect(text == "Hello there\nLine & more")
    }
}

@Suite struct MessageBuilderTests {
    @Test func buildsMessageThatParsesBack() {
        let outgoing = OutgoingMessage(
            from: EmailAddress(name: "Aleksandar Gošević", email: "a@example.com"),
            to: [EmailAddress(name: "Doe, John", email: "john@example.com")],
            subject: "Ponuda — čćšđž",
            body: "Zdravo,\n\n**Hvala** na poruci.\n" + String(repeating: "dugačka linija ", count: 20),
            attachments: [OutgoingAttachment(filename: "ugovor.pdf", data: Data("%PDF-1.4".utf8))],
            inReplyTo: "orig@example.com",
            references: ["root@example.com", "orig@example.com"]
        )
        let raw = MessageBuilder.build(outgoing, messageID: "new@example.com")
        let parsed = MIMEParser.parse(raw)

        #expect(parsed.headers.decoded("Subject") == "Ponuda — čćšđž")
        #expect(parsed.headers.addresses("From").first == outgoing.from)
        #expect(parsed.headers.addresses("To") == outgoing.to)
        #expect(parsed.headers.messageIDs("References") == ["root@example.com", "orig@example.com"])
        #expect(parsed.text?.contains("**Hvala** na poruci.") == true)
        #expect(parsed.html?.contains("<strong>Hvala</strong>") == true)
        #expect(parsed.visibleAttachments.first?.filename == "ugovor.pdf")
        #expect(parsed.visibleAttachments.first?.data == Data("%PDF-1.4".utf8))

        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 998 })
    }

    @Test func keepsLineBreaksInHTML() {
        let html = MarkdownRenderer.html(from: "Pozdrav,\nAleksandar")
        #expect(html.contains("Pozdrav,<br />"))
    }
}
