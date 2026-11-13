import AppKit
import PoscarCore
import SwiftUI

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: ComposerModel
    let controller: ComposerController
    @FocusState private var focus: ComposerFocus?

    var body: some View {
        VStack(spacing: 0) {
            if let error = draft.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).lineLimit(3)
                    Spacer()
                    Button("Dismiss") { draft.error = nil }.buttonStyle(.link)
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
            }
            header
            Divider()
            if draft.showingPreview {
                MarkdownPreview(markdown: draft.body)
            } else {
                BodyEditor(text: $draft.body, focusOnAppear: draft.initialFocus == .body, cursorAtStart: draft.cursorAtStart)
                    .onDisappear {
                        // Coming back from the preview should land in the text, where the user left off.
                        draft.initialFocus = .body
                        draft.cursorAtStart = false
                    }
            }
            if !draft.attachments.isEmpty {
                Divider()
                attachmentStrip
            }
            Divider()
            bottomBar
        }
        .overlay {
            if draft.showingSendLater {
                SendLaterPanel(draft: draft, controller: controller)
            }
        }
        .onAppear {
            if draft.initialFocus != .body {
                DispatchQueue.main.async { focus = draft.initialFocus }
            }
        }
        .onChange(of: draft.subject) { controller.updateTitle() }
        .onChange(of: focus) { oldFocus, newFocus in
            if let old = Self.addressField(oldFocus), old != Self.addressField(newFocus) { draft.fieldLostFocus(old) }
            draft.activeField = Self.addressField(newFocus)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in draft.addAttachments([url]) }
                }
            }
            return true
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            if model.accounts.count > 1 {
                fieldRow("From") {
                    Picker("", selection: $draft.accountId) {
                        ForEach(model.accounts) { account in
                            Text("\(account.name) <\(account.email)>").tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                Divider()
            }
            addressRow("To", field: .to, focusValue: .to) {
                if !draft.showCcBcc {
                    CommandButton(command: .toggleCcBcc, title: "Cc/Bcc")
                }
            }
            if draft.showCcBcc {
                Divider()
                addressRow("Cc", field: .cc, focusValue: .cc) { EmptyView() }
                Divider()
                addressRow("Bcc", field: .bcc, focusValue: .bcc) { EmptyView() }
            }
            Divider()
            fieldRow("Subject") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
            }
        }
    }

    private func addressRow<Accessory: View>(
        _ label: String, field: AddressFieldKind, focusValue: ComposerFocus, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let list = draft.list(for: field)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                    .padding(.top, 2)
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(list.addresses.enumerated()), id: \.element.email) { index, address in
                        RecipientToken(
                            address: address,
                            isSelected: draft.selectedToken?.field == field && draft.selectedToken?.index == index,
                            onRemove: { draft.removeToken(at: index, from: field) }
                        )
                    }
                    TextField("", text: Binding(
                        get: { draft.list(for: field).draft },
                        set: { draft.setDraft($0, for: field, database: model.database) }
                    ))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: focusValue)
                    .frame(minWidth: 140)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focus = focusValue }
                accessory()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            if draft.suggestionField == field, !draft.suggestions.isEmpty, focus == focusValue {
                suggestionList
            }
        }
    }

    private static func addressField(_ focus: ComposerFocus?) -> AddressFieldKind? {
        switch focus {
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        default: nil
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(draft.suggestions.enumerated()), id: \.element.email) { index, contact in
                HStack {
                    Avatar(name: contact.name, email: contact.email, size: 20)
                    Text(contact.name.isEmpty ? contact.email : contact.name)
                    if !contact.name.isEmpty {
                        Text(contact.email).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index == draft.suggestionIndex {
                        Keycap(symbol: "⇥")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == draft.suggestionIndex ? Theme.selection : .clear))
                .contentShape(Rectangle())
                .onTapGesture { draft.acceptSuggestion(at: index) }
            }
        }
        .padding(.leading, 70)
        .padding(.bottom, 6)
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        Text(attachment.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.attachments.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button {
                controller.perform(.send)
            } label: {
                HStack(spacing: 6) {
                    if draft.isSending { ProgressView().controlSize(.small) }
                    Text("Send")
                    KeyHint(sequence: model.keymap.primary(for: .send), prominent: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.isSending)

            composerButton(.sendLater, icon: "clock")
            composerButton(.attachFile, icon: "paperclip")
            Spacer()
            composerButton(.togglePreview, icon: draft.showingPreview ? "pencil" : "eye", title: draft.showingPreview ? "Edit" : "Preview")
            composerButton(.discardDraft, icon: "trash", showTitle: false)
        }
        .padding(10)
    }

    private func composerButton(_ command: CommandID, icon: String, title: String? = nil, showTitle: Bool = true) -> some View {
        Button {
            controller.perform(command)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if showTitle { Text(title ?? command.title) }
                KeyHint(sequence: model.keymap.primary(for: command))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(HintButtonStyle())
        .help(command.title)
    }
}

private struct SendLaterPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: ComposerModel
    let controller: ComposerController

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).onTapGesture { draft.showingSendLater = false }
            VStack(alignment: .leading, spacing: 4) {
                Text("Send later").font(.headline).padding(.bottom, 6)
                ForEach(Array(SendLaterOption.all.enumerated()), id: \.offset) { index, option in
                    Button {
                        controller.send(at: option.date())
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            Text(option.date().formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            Keycap(symbol: "\(index + 1)")
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HintButtonStyle())
                }
                Divider().padding(.vertical, 6)
                HStack {
                    DatePicker("", selection: $draft.customSendDate, in: Date()...)
                        .labelsHidden()
                    Spacer()
                    Button("Schedule") { controller.send(at: draft.customSendDate) }
                }
                Text("Sent while Pošćar is running.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(16)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
    }
}

/// Plain-text editor with smart substitutions off, so Markdown stays as typed.
struct BodyEditor: NSViewRepresentable {
    @Binding var text: String
    var focusOnAppear: Bool
    var cursorAtStart: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.string = text
        if cursorAtStart { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// One recipient: the name (or address) in a pill that can only be removed, never edited.
private struct RecipientToken: View {
    let address: EmailAddress
    let isSelected: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(address.name.isEmpty ? address.email : address.name)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0.5)
            .help("Remove")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(Capsule().fill(isSelected ? Theme.accent : Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.hairline, lineWidth: 0.5))
        .onHover { hovering = $0 }
        .help(address.formatted)
    }
}

/// Lays children out left to right, wrapping to a new line when they don't fit.
/// The last child (the text field) takes whatever width is left on its line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let frames = arrange(subviews, width: width)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if index == subviews.count - 1 { size.width = max(size.width, width - x) }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        // Centre each item vertically on its line, so the text field lines up with the pills.
        var result: [CGRect] = []
        var lineStart = 0
        for index in frames.indices {
            let isLineEnd = index == frames.count - 1 || frames[index + 1].minY != frames[index].minY
            guard isLineEnd else { continue }
            let line = frames[lineStart...index]
            let height = line.map(\.height).max() ?? 0
            result += line.map { $0.offsetBy(dx: 0, dy: (height - $0.height) / 2) }
            lineStart = index + 1
        }
        return result
    }
}
