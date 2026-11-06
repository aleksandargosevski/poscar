import Foundation

/// Turns fetched IMAP data into database records.
public enum MessageFactory {
    static let headerFields = "FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO CONTENT-TYPE"

    static func headerFetchItems(gmail: Bool) -> String {
        let base = "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(headerFields))]"
        return gmail ? base + " X-GM-MSGID X-GM-THRID X-GM-LABELS" : base
    }

    static func flagFetchItems(gmail: Bool) -> String {
        gmail ? "UID FLAGS X-GM-LABELS" : "UID FLAGS"
    }

    public static func record(from fetched: FetchedMessage, accountId: String, folder: String, gmail: Bool) -> MessageRecord {
        let headers = MIMEHeaders(data: fetched.header ?? Data())
        let from = headers.addresses("From").first ?? EmailAddress(email: "")
        let messageId = headers.messageIDs("Message-ID").first
        let references = headers.messageIDs("References")
        let inReplyTo = headers.messageIDs("In-Reply-To").first

        let threadKey: String
        if gmail, let threadID = fetched.gmailThreadID {
            threadKey = "gm:\(threadID)"
        } else {
            threadKey = ThreadKey.compute(
                messageId: messageId, references: references, inReplyTo: inReplyTo,
                fallback: "\(folder):\(fetched.uid)"
            )
        }

        return MessageRecord(
            id: nil,
            accountId: accountId,
            folder: folder,
            uid: Int64(fetched.uid),
            gmailMessageId: fetched.gmailMessageID.map { Int64(bitPattern: $0) },
            threadKey: threadKey,
            messageId: messageId,
            inReplyTo: inReplyTo,
            references: references.joined(separator: " "),
            subject: headers.decoded("Subject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            fromName: from.name,
            fromEmail: from.email,
            toAddresses: AddressParser.format(headers.addresses("To")),
            ccAddresses: AddressParser.format(headers.addresses("Cc")),
            replyTo: AddressParser.format(headers.addresses("Reply-To")),
            date: fetched.internalDate ?? headers["Date"].flatMap(MailDate.parse) ?? Date(),
            size: fetched.size,
            seen: fetched.isSeen,
            flagged: fetched.isFlagged,
            answered: fetched.isAnswered,
            draft: fetched.isDraft,
            labels: gmail ? LabelSet.encode(fetched.gmailLabels ?? []) : "",
            hasAttachments: headers.contentType.value == "multipart/mixed",
            snippet: "",
            hasBody: false,
            hidden: false
        )
    }
}

public enum ThreadKey {
    /// Threads non-Gmail messages by the first Message-ID of the conversation.
    public static func compute(messageId: String?, references: [String], inReplyTo: String?, fallback: String) -> String {
        if let root = references.first { return "id:\(root)" }
        if let inReplyTo { return "id:\(inReplyTo)" }
        if let messageId { return "id:\(messageId)" }
        return "uid:\(fallback)"
    }
}
