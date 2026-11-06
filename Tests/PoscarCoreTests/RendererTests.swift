import Foundation
import Testing
@testable import PoscarCore

@Suite struct RendererTests {
    @Test func wrapsPlainTextQuoteWithItsAttribution() {
        let text = "Hvala!\n\nOn Thu, Oct 29, Ana wrote:\n> Prva linija\n>\n> Druga\n\nPotpis"
        let (html, hasQuotes) = ThreadRenderer.plainTextBody(text)
        #expect(hasQuotes)
        #expect(html.hasPrefix("Hvala!\n\n<div class=\"q\">On Thu, Oct 29, Ana wrote:\n"))
        #expect(html.hasSuffix("&gt; Druga</span>\n</div>\nPotpis"))
    }

    @Test func leavesTextWithoutQuotesAlone() {
        let (html, hasQuotes) = ThreadRenderer.plainTextBody("Samo tekst:\nbez citata")
        #expect(!hasQuotes)
        #expect(!html.contains("class=\"q\""))
    }

    @Test func addsToggleOnlyForQuotedHTML() {
        func render(_ html: String) -> String {
            var record = MessageRecord.sample
            record.id = 1
            let parsed = ParsedMessage(headers: MIMEHeaders(), html: html, text: nil, attachments: [])
            return ThreadRenderer.render(
                subject: "S", messages: [RenderableMessage(record: record, parsed: parsed)],
                expanded: [], loadImages: false, accountEmail: "me@x.com"
            ).html
        }
        #expect(render("<p>Hi</p><div class=\"gmail_quote\">old</div>").contains("poscar://quotes/0"))
        #expect(!render("<p>Hi</p>").contains("poscar://quotes/0"))
    }
}

extension MessageRecord {
    static var sample: MessageRecord {
        MessageRecord(
            id: nil, accountId: "a", folder: "INBOX", uid: 1, gmailMessageId: nil, threadKey: "t", messageId: nil,
            inReplyTo: nil, references: "", subject: "S", fromName: "Ana", fromEmail: "ana@x.com", toAddresses: "me@x.com",
            ccAddresses: "", replyTo: "", date: Date(), size: 1, seen: true, flagged: false, answered: false, draft: false,
            labels: "", hasAttachments: false, snippet: "", hasBody: true, hidden: false
        )
    }
}
