import PoscarCore
import SwiftUI

enum SidebarItem: Hashable {
    case mailbox(Mailbox)
    case scheduled
    case attachments
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private static let unifiedKinds: [MailboxKind] = [.inbox, .starred, .sent, .drafts, .archive]

    var body: some View {
        List(selection: selection) {
            if model.accounts.count > 1 {
                Section {
                    ForEach(Self.unifiedKinds, id: \.self) { kind in
                        row(Mailbox(kind: kind))
                    }
                } header: {
                    sectionHeader("All Accounts", color: nil, command: .goUnified)
                }
            }

            Section {
                libraryRow("Attachments", icon: "paperclip", item: .attachments, command: .goAttachments, count: nil)
                if !model.scheduled.isEmpty {
                    libraryRow("Scheduled", icon: "clock", item: .scheduled, command: .goScheduled, count: model.scheduled.count)
                }
            } header: {
                sectionHeader("Library", color: nil, command: nil)
            }
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                Section {
                    ForEach(MailboxKind.standard, id: \.self) { kind in
                        row(Mailbox(accountId: account.id, kind: kind))
                    }
                    labels(for: account)
                } header: {
                    sectionHeader(label(for: account), color: account.color, command: accountCommand(index), error: model.accountErrors[account.id])
                }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarTop)
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            if model.showingScheduled { return .scheduled }
            if model.showingAttachments { return .attachments }
            return .mailbox(model.mailbox)
        } set: { item in
            switch item {
            case .mailbox(let mailbox): model.setMailbox(mailbox)
            case .scheduled: model.showingScheduled = true
            case .attachments: model.showingAttachments = true
            case nil: break
            }
        }
    }

    /// The `g …` hint is shown only where it leads: in the scope that is currently active.
    private func row(_ mailbox: Mailbox) -> some View {
        let inScope = mailbox.accountId == model.mailbox.accountId
        let isInbox = mailbox.kind == .inbox
        let showsUnread = isInbox && (mailbox.accountId == nil || model.accounts.count == 1)
        return Label {
            HStack {
                Text(mailbox.kind.title)
                Spacer()
                if showsUnread, model.unreadCount > 0 {
                    Text("\(model.unreadCount)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.unread))
                }
                if inScope, let command = goCommand(mailbox.kind) {
                    KeyHint(sequence: model.keymap.primary(for: command))
                }
            }
        } icon: {
            Image(systemName: mailbox.kind.systemImage)
        }
        .tag(SidebarItem.mailbox(mailbox))
    }

    private func libraryRow(_ title: String, icon: String, item: SidebarItem, command: CommandID, count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                KeyHint(sequence: model.keymap.primary(for: command))
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(item)
    }

    @ViewBuilder
    private func labels(for account: Account) -> some View {
        let labels = model.folders[account.id]?.userLabels ?? []
        if !labels.isEmpty {
            DisclosureGroup("Labels") {
                ForEach(labels, id: \.path) { folder in
                    let key = account.isGmail ? folder.name : folder.path
                    Label(folder.name, systemImage: account.isGmail ? "tag" : "folder")
                        .tag(SidebarItem.mailbox(Mailbox(accountId: account.id, kind: .label(key))))
                }
            }
        }
    }

    private func sectionHeader(_ title: String, color: Color?, command: CommandID?, error: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(title)
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
            Spacer()
            if let command {
                KeyHint(sequence: model.keymap.primary(for: command))
            }
        }
        // Section headers span the full sidebar width; line the hints up with the rows' hints.
        .padding(.trailing, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// Accounts often share the owner's name; then the address tells them apart.
    private func label(for account: Account) -> String {
        model.accounts.filter { $0.name == account.name }.count > 1 ? account.email : account.name
    }

    private func accountCommand(_ index: Int) -> CommandID? {
        [.goAccount1, .goAccount2, .goAccount3, .goAccount4, .goAccount5].dropFirst(index).first
    }

    private func goCommand(_ kind: MailboxKind) -> CommandID? {
        switch kind {
        case .inbox: .goInbox
        case .starred: .goStarred
        case .sent: .goSent
        case .drafts: .goDrafts
        case .archive: .goAllMail
        case .spam: .goSpam
        case .trash: .goTrash
        case .label, .everywhere: nil
        }
    }
}
