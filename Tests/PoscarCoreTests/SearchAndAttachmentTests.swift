import Foundation
import GRDB
import Testing
@testable import PoscarCore

@Suite struct SearchQueryTests {
    @Test func separatesFiltersFromText() {
        let query = SearchQuery(#"from:ana@x.com to:"Marko Marković" ponuda has:attachment sajt"#)
        #expect(query.from == ["ana@x.com"])
        #expect(query.to == ["Marko Marković"])
        #expect(query.text == ["ponuda", "sajt"])
    }

    @Test func readsFolderFilters() {
        let query = SearchQuery(#"in:sent in:"Moji projekti" ponuda"#)
        #expect(query.folders == ["sent", "Moji projekti"])
        #expect(query.text == ["ponuda"])
        #expect(SearchQuery.standardMailbox(named: "Sent") == .some(.sent))
        #expect(SearchQuery.standardMailbox(named: "bin") == .some(.trash))
        #expect(SearchQuery.standardMailbox(named: "anywhere") == .some(nil))
        #expect(SearchQuery.standardMailbox(named: "Posao") == nil)
    }

    @Test func buildsIMAPCriteria() {
        let parts = SearchQuery("from:ana ponuda").imapCriteria
        let text = parts.map { part -> String in
            if case .text(let value) = part { return value }
            return "<literal>"
        }.joined()
        #expect(text == #"FROM "ana" TEXT "ponuda""#)
    }

    @Test func filtersLocallyBySenderAndRecipient() throws {
        let database = try MailDatabase()
        try database.writer.write { db in
            for (uid, from, to) in [(1, "ana@x.com", "me@x.com"), (2, "marko@y.com", "me@x.com"), (3, "ana@x.com", "boss@z.com")] as [(Int64, String, String)] {
                var record = MessageRecord.sample
                record.uid = uid
                record.fromEmail = from
                record.fromName = ""
                record.toAddresses = to
                try record.insert(db)
                try db.execute(sql: "INSERT INTO message_fts (rowid, subject, participants, body) VALUES (?, 'Ponuda', '', '')", arguments: [record.id])
            }
        }
        let fromAna = try database.writer.read { db in try MailQueries.search(db, query: SearchQuery("from:ana")) }
        #expect(fromAna.count == 2)
        let fromAnaToBoss = try database.writer.read { db in try MailQueries.search(db, query: SearchQuery("from:ana to:boss ponuda")) }
        #expect(fromAnaToBoss.count == 1)
    }

    @Test func treatsUnderscoreInAddressesLiterally() throws {
        let database = try MailDatabase()
        try database.writer.write { db in
            for (uid, from) in [(1, "srdjan_g@gmail.com"), (2, "srdjanXg@gmail.com")] as [(Int64, String)] {
                var record = MessageRecord.sample
                record.uid = uid
                record.fromEmail = from
                record.fromName = ""
                try record.insert(db)
            }
        }
        let hits = try database.writer.read { db in try MailQueries.search(db, query: SearchQuery("from:srdjan_g@gmail.com")) }
        #expect(hits.count == 1)
    }
}

@Suite struct AttachmentIndexTests {
    @Test func classifiesByTypeAndExtension() {
        #expect(AttachmentKind.classify(filename: "polisa.pdf", mimeType: "application/octet-stream") == .pdf)
        #expect(AttachmentKind.classify(filename: "IMG_1.jpg", mimeType: "image/jpeg") == .image)
        #expect(AttachmentKind.classify(filename: "budzet.xlsx", mimeType: "application/octet-stream") == .spreadsheet)
        #expect(AttachmentKind.classify(filename: "ugovor.docx", mimeType: "application/octet-stream") == .document)
        #expect(AttachmentKind.classify(filename: "site.zip", mimeType: "application/zip") == .archive)
        #expect(AttachmentKind.classify(filename: "data.bin", mimeType: "application/octet-stream") == .other)
    }

    @Test func backfillIndexesDownloadedBodies() async throws {
        let database = try MailDatabase()
        let raw = MessageBuilder.build(OutgoingMessage(
            from: EmailAddress(email: "ana@x.com"), to: [EmailAddress(email: "me@x.com")], subject: "Polisa", body: "Evo",
            attachments: [OutgoingAttachment(filename: "polisa.pdf", data: Data("%PDF-1.4".utf8))]
        ), messageID: "m@x")
        try await database.writer.write { db in
            var record = MessageRecord.sample
            record.hasAttachments = true
            try record.insert(db)
            try db.execute(sql: "INSERT INTO body (messageRowId, raw) VALUES (?, ?)", arguments: [record.id, raw])
        }

        #expect(try await AttachmentIndex.backfill(database) == 1)
        #expect(try await AttachmentIndex.backfill(database) == 0)

        let pdfs = try await database.writer.read { db in try AttachmentIndex.fetch(db, filter: AttachmentFilter(kind: .pdf)) }
        #expect(pdfs.map(\.filename) == ["polisa.pdf"])
        let searched = try await database.writer.read { db in try AttachmentIndex.fetch(db, filter: AttachmentFilter(text: "poli")) }
        #expect(searched.count == 1)
        let otherAccount = try await database.writer.read { db in try AttachmentIndex.fetch(db, filter: AttachmentFilter(accountId: "nobody")) }
        #expect(otherAccount.isEmpty)
    }
}
