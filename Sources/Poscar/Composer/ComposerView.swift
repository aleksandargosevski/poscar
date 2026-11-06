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
        VStack(alignment: .leading, spacing: 0) {
            fieldRow(label) {
                TextField("", text: Binding(
                    get: { draft.text(for: field) },
                    set: { value in
                        draft.setText(value, for: field)
                        draft.updateSuggestions(for: field, database: model.database)
                    }
                ))
                .textFieldStyle(.plain)
                .focused($focus, equals: focusValue)
                .onChange(of: focus) { _, newFocus in
                    if newFocus != focusValue, draft.suggestionField == field { draft.suggestions = [] }
                }
                accessory()
            }
            if draft.suggestionField == field, !draft.suggestions.isEmpty {
                suggestionList
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(draft.suggestions.enumerated()), id: \.element.email) { index, contact in
                HStack {
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
                .background(index == draft.suggestionIndex ? Color.accentColor.opacity(0.18) : .clear)
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
