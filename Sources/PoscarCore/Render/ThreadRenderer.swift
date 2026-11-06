import Foundation

public struct RenderableMessage: Sendable {
    public var record: MessageRecord
    public var parsed: ParsedMessage?
    public var loadError: String?
    /// JPEG previews of attachments, keyed by attachment id.
    public var thumbnails: [Int: Data]

    public init(record: MessageRecord, parsed: ParsedMessage?, loadError: String? = nil, thumbnails: [Int: Data] = [:]) {
        self.record = record
        self.parsed = parsed
        self.loadError = loadError
        self.thumbnails = thumbnails
    }
}

/// Renders a conversation as one HTML page. Each message body lives in its own sandboxed
/// iframe so email CSS can't leak; remote content is blocked by CSP unless images are allowed.
public enum ThreadRenderer {
    public static let scheme = "poscar"

    public struct Output: Sendable {
        public var html: String
        public var hasBlockedImages: Bool
    }

    public static func render(
        subject: String,
        messages: [RenderableMessage],
        expanded: Set<Int64>,
        loadImages: Bool,
        accountEmail: String
    ) -> Output {
        var blocked = false
        var sections = ""
        for (index, message) in messages.enumerated() {
            let id = message.record.id ?? 0
            let isOpen = expanded.contains(id) || index == 0
            let (section, hasRemote) = renderMessage(message, index: index, open: isOpen, loadImages: loadImages, accountEmail: accountEmail)
            if hasRemote { blocked = true }
            sections += section
        }

        let imageSources = loadImages ? "* data: cid:" : "data: cid:"
        let styleSources = loadImages ? "'unsafe-inline' https: http:" : "'unsafe-inline'"
        let fontSources = loadImages ? "https: data:" : "data:"
        let banner = blocked && !loadImages
            ? "<div class=\"banner\">Remote images are hidden to protect your privacy. <a href=\"\(scheme)://load-images\">Load images</a> <kbd>I</kbd></div>"
            : ""

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src \(imageSources); style-src \(styleSources); font-src \(fontSources); frame-src about: data:; child-src about: data:">
        <style>\(css)</style></head><body>
        <h1 class="subject">\(HTMLText.escape(subject.isEmpty ? "(no subject)" : subject))</h1>
        \(banner)
        \(sections)
        </body></html>
        """
        return Output(html: html, hasBlockedImages: blocked && !loadImages)
    }

    /// JavaScript run from the app (page scripts are disabled) to size iframes to their content.
    public static let resizeScript = """
    (function(){var changed=false;document.querySelectorAll('iframe.body').forEach(function(f){try{var d=f.contentDocument;\
    if(!d||!d.documentElement)return;var h=d.body?Math.ceil(d.body.getBoundingClientRect().height):d.documentElement.scrollHeight;\
    if(h>0&&f.dataset.h!=String(h)){f.dataset.h=String(h);f.style.height=h+'px';changed=true;}}catch(e){}});return changed;})();
    """

    public static func toggleScript(index: Int) -> String {
        "(function(){var m=document.getElementById('m\(index)');if(m){m.classList.toggle('open');}})();"
    }

    public static func focusScript(index: Int) -> String {
        """
        (function(){var m=document.getElementById('m\(index)');if(!m)return;m.classList.add('open');\
        document.querySelectorAll('.msg.focused').forEach(function(e){e.classList.remove('focused')});\
        m.classList.add('focused');m.scrollIntoView({behavior:'smooth',block:'start'});})();
        """
    }

    public static func scrollScript(pages: Double) -> String {
        "window.scrollBy({top: window.innerHeight * \(pages) * 0.85, behavior: 'smooth'});"
    }

    // MARK: - Pieces

    private static func renderMessage(
        _ message: RenderableMessage, index: Int, open: Bool, loadImages: Bool, accountEmail: String
    ) -> (String, Bool) {
        let record = message.record
        let sender = record.from
        let initial = String(sender.displayName.prefix(1)).uppercased()
        let recipients = (record.to + record.cc).map { address in
            address.email.caseInsensitiveCompare(accountEmail) == .orderedSame ? "me" : address.displayName
        }

        var body = ""
        var hasRemote = false
        if let parsed = message.parsed {
            let (frameDocument, remote) = bodyDocument(parsed, index: index)
            hasRemote = remote
            body = "<iframe id=\"f\(index)\" class=\"body\(parsed.html == nil ? " plain" : "")\" sandbox=\"allow-same-origin allow-popups allow-popups-to-escape-sandbox\" srcdoc=\"\(HTMLText.escape(frameDocument))\"></iframe>"
            body += attachmentsHTML(parsed.visibleAttachments, thumbnails: message.thumbnails, messageID: record.id ?? 0)
        } else if let error = message.loadError {
            body = "<div class=\"error\">Could not load this message: \(HTMLText.escape(error))</div>"
        } else {
            body = "<div class=\"loading\">Loading…</div>"
        }

        let section = """
        <section class="msg\(open ? " open" : "")\(record.seen ? "" : " unread")" id="m\(index)">
        <a class="header" href="\(scheme)://toggle/\(index)">
          <div class="avatar" style="background:\(avatarColor(for: sender.email))">\(HTMLText.escape(initial))</div>
          <div class="meta">
            <div class="from"><b>\(HTMLText.escape(sender.displayName))</b> <span class="email">\(HTMLText.escape(sender.email))</span></div>
            <div class="to">to \(HTMLText.escape(recipients.joined(separator: ", ")))</div>
            <div class="snippet">\(HTMLText.escape(record.snippet))</div>
          </div>
          <time>\(HTMLText.escape(formatDate(record.date)))</time>
        </a>
        <div class="content">\(body)</div>
        </section>
        """
        return (section, hasRemote)
    }

    /// Images and PDFs as preview cards, everything else as compact chips.
    private static func attachmentsHTML(_ attachments: [MailAttachment], thumbnails: [Int: Data], messageID: Int64) -> String {
        guard !attachments.isEmpty else { return "" }
        let previewed = attachments.filter { thumbnails[$0.id] != nil }
        let others = attachments.filter { thumbnails[$0.id] == nil }
        var html = ""
        if !previewed.isEmpty {
            html += "<div class=\"previews\">"
            for attachment in previewed {
                let image = thumbnails[attachment.id]!.base64EncodedString()
                html += """
                <a class="preview" href="\(scheme)://attachment/\(messageID)/\(attachment.id)" title="\(HTMLText.escape(attachment.filename))">\
                <img src="data:image/jpeg;base64,\(image)" alt="">\
                <span>\(HTMLText.escape(attachment.filename))<small>\(attachment.sizeDescription)</small></span></a>
                """
            }
            html += "</div>"
        }
        if !others.isEmpty {
            html += "<div class=\"attachments\">"
            for attachment in others {
                html += "<a class=\"chip\" href=\"\(scheme)://attachment/\(messageID)/\(attachment.id)\">📎 \(HTMLText.escape(attachment.filename)) <span>\(attachment.sizeDescription)</span></a>"
            }
            html += "</div>"
        }
        return html
    }

    private static func bodyDocument(_ parsed: ParsedMessage, index: Int) -> (String, Bool) {
        let toggle = "<a class=\"poscar-quote-toggle\" href=\"\(scheme)://quotes/\(index)\" target=\"_blank\"></a>"

        guard var html = parsed.html else {
            let (text, hasQuotes) = plainTextBody(parsed.plainText)
            return (plainFrameStyle + quoteStyle + "<pre>\(text)</pre>" + (hasQuotes ? toggle : ""), false)
        }

        for attachment in parsed.attachments {
            guard let contentID = attachment.contentID, html.contains("cid:\(contentID)") else { continue }
            let dataURI = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(contentID)", with: dataURI)
        }
        let hasRemote = html.range(of: #"(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
        let hasQuotes = quoteMarkers.contains { html.range(of: $0, options: .caseInsensitive) != nil }
        return (htmlFrameStyle + quoteStyle + html + (hasQuotes ? toggle : ""), hasRemote)
    }

    /// Markup that mail clients put around the quoted previous message.
    private static let quoteMarkers = [
        "gmail_quote", "type=\"cite\"", "type=cite", "divRplyFwdMsg", "appendonsend", "yahoo_quoted", "moz-cite-prefix", "protonmail_quote",
    ]

    /// Hidden until the frame's root gets `show-quotes` from the toggle.
    private static let quoteStyle = """
    <style>
    html:not(.show-quotes) .gmail_quote, html:not(.show-quotes) blockquote[type="cite"],
    html:not(.show-quotes) .moz-cite-prefix, html:not(.show-quotes) .yahoo_quoted,
    html:not(.show-quotes) .protonmail_quote, html:not(.show-quotes) #divRplyFwdMsg,
    html:not(.show-quotes) #divRplyFwdMsg ~ *, html:not(.show-quotes) #appendonsend ~ *,
    html:not(.show-quotes) .q { display: none !important; }
    .poscar-quote-toggle { display: inline-block; margin: 10px 0 2px; padding: 2px 10px; border-radius: 10px;
      font: 600 11px -apple-system, sans-serif; color: #7a736b; text-decoration: none;
      background: #f3f1ee; border: .5px solid rgba(0,0,0,.10); }
    .poscar-quote-toggle::after { content: "•••  Show quoted text"; }
    html.show-quotes .poscar-quote-toggle::after { content: "Hide quoted text"; }
    </style>
    """

    /// Escapes plain text and wraps quoted runs (with the "… wrote:" line before them) in `.q`.
    static func plainTextBody(_ text: String) -> (String, Bool) {
        let lines = linkify(HTMLText.escape(text)).components(separatedBy: "\n")
        var output: [String] = []
        var quote: [String] = []
        var hasQuotes = false

        func flushQuote() {
            guard !quote.isEmpty else { return }
            hasQuotes = true
            output.append("<div class=\"q\">" + quote.joined(separator: "\n") + "</div>")
            quote = []
        }

        for line in lines {
            if line.hasPrefix("&gt;") {
                // Pull a preceding attribution line ("On …, X wrote:") into the quote.
                if quote.isEmpty, let last = output.last, last.trimmingCharacters(in: .whitespaces).hasSuffix(":"),
                   !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    quote.append(output.removeLast())
                }
                quote.append("<span class=\"quote\">\(line)</span>")
            } else if !quote.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty {
                quote.append(line)
            } else {
                flushQuote()
                output.append(line)
            }
        }
        flushQuote()
        return (output.joined(separator: "\n"), hasQuotes)
    }

    public static func toggleQuotesScript(index: Int) -> String {
        "(function(){var f=document.getElementById('f\(index)');if(f&&f.contentDocument){f.contentDocument.documentElement.classList.toggle('show-quotes');}})();"
    }

    private static func linkify(_ escapedText: String) -> String {
        escapedText.replacingOccurrences(
            of: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])"#,
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? timeFormatter : dateTimeFormatter).string(from: date)
    }

    static func avatarColor(for email: String) -> String {
        let palette = ["#5B6EE1", "#E0565B", "#2FA37A", "#D98E2B", "#9B59B6", "#1E9BD7", "#C2557D", "#5A8F29"]
        let hash = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[hash % palette.count]
    }

    private static let htmlFrameStyle = """
    <meta charset="utf-8"><base target="_blank"><style>html,body{margin:0;padding:0;background:#fff;color:#222;}\
    body{display:flow-root;padding:20px 26px 24px;font:14.5px/1.55 -apple-system,Helvetica,Arial,sans-serif;word-wrap:break-word;overflow-x:auto;}\
    img{max-width:100%;height:auto;}blockquote{margin-left:.6ex;padding-left:1ex;border-left:2px solid #ccc;color:#555;}</style>
    """

    private static let plainFrameStyle = """
    <meta charset="utf-8"><base target="_blank"><style>html,body{margin:0;padding:0;background:transparent;}\
    body{display:flow-root;padding:18px 26px 22px;color:#2a2622;}pre{white-space:pre-wrap;word-wrap:break-word;font:14.5px/1.6 -apple-system,Helvetica,sans-serif;margin:0;}\
    .quote{color:#8a847c;}a{color:#c9502f;}@media (prefers-color-scheme: dark){body{color:#ece7e0;}.quote{color:#9a948c;}a{color:#ef7a5f;}\
    .poscar-quote-toggle{color:#b5aea6 !important;background:#3a3734 !important;border-color:#000 !important;}}</style>
    """

    private static let css = """
    :root{color-scheme:light dark;--bg:#f9f7f4;--fg:#2a2622;--muted:#8a847c;--line:#e7e1d9;--card:#fffefc;--accent:#d9573f;--focus:#d9573f33;--unread:#4585f2;}
    @media (prefers-color-scheme: dark){:root{--bg:#1e1d1c;--fg:#f0ece6;--muted:#9a948c;--line:#3a3734;--card:#2a2826;--accent:#ef7a5f;--focus:#ef7a5f33;}}
    html,body{background:var(--bg);color:var(--fg);margin:0;font:13px -apple-system,BlinkMacSystemFont,sans-serif;}
    body{padding:34px 48px 80px;max-width:920px;margin:0 auto;}
    h1.subject{font-size:26px;font-weight:650;letter-spacing:-.015em;margin:0 0 26px;line-height:1.25;}
    .banner{background:var(--focus);padding:11px 16px;border-radius:12px;margin-bottom:18px;color:var(--fg);}
    .banner a{color:var(--accent);font-weight:600;text-decoration:none;margin-left:6px;}
    kbd{font:500 10.5px -apple-system,sans-serif;border-radius:5px;padding:1px 5px;margin-left:4px;color:var(--muted);border:1px solid rgba(127,127,127,.35);}
    .msg{border:.5px solid var(--line);border-radius:14px;margin-bottom:16px;background:var(--card);overflow:hidden;
      box-shadow:0 1px 3px rgba(0,0,0,.04);}
    .msg.focused{box-shadow:0 0 0 2px var(--accent);}
    .header{display:flex;gap:14px;align-items:center;padding:16px 22px;color:inherit;text-decoration:none;cursor:default;}
    .msg.open .header{border-bottom:.5px solid var(--line);}
    .avatar{width:38px;height:38px;border-radius:50%;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:600;flex:none;}
    .meta{flex:1;min-width:0;}
    .from{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:14px;}
    .email,.to,time{color:var(--muted);font-size:12px;}
    .to{margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .snippet{display:none;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px;}
    .msg:not(.open) .snippet{display:block;}
    .msg:not(.open) .to{display:none;}
    .msg:not(.open) .content{display:none;}
    .msg:not(.open){background:transparent;box-shadow:none;}
    .msg.unread .from b::after{content:"";display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--unread);margin-left:6px;vertical-align:middle;}
    time{flex:none;white-space:nowrap;}
    iframe.body{display:block;width:100%;border:0;height:60px;background:#fff;}
    iframe.body.plain{background:transparent;}
    .attachments{display:flex;flex-wrap:wrap;gap:8px;padding:6px 24px 20px;}
    .chip{border:.5px solid var(--line);border-radius:8px;padding:5px 9px;color:var(--fg);text-decoration:none;font-size:12px;
      background:var(--card);}
    .chip span{color:var(--muted);margin-left:4px;}
    .previews{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;padding:8px 24px 16px;}
    .preview{display:block;border:.5px solid var(--line);border-radius:10px;overflow:hidden;background:var(--card);color:var(--fg);
      text-decoration:none;transition:border-color .12s;}
    .preview:hover{border-color:var(--accent);}
    .preview img{display:block;width:100%;height:118px;object-fit:cover;object-position:top;background:#fff;border-bottom:.5px solid var(--line);}
    .preview span{display:block;font-size:11.5px;padding:7px 9px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .preview small{display:block;color:var(--muted);font-size:10.5px;margin-top:1px;}
    .loading,.error{padding:20px 26px;color:var(--muted);}
    """
}
