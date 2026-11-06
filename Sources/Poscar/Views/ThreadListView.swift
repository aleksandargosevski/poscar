import AppKit
import PoscarCore
import SwiftUI

struct ThreadListView: View {
    /// One margin for the search field, date headers and rows, so their edges line up.
    static let margin: CGFloat = 32

    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            searchBar(text: $model.searchText)
                .overlay(alignment: .topLeading) {
                    if searchFocused, !model.searchSuggestions.isEmpty {
                        suggestions
                            .padding(.top, 62)
                            .padding(.horizontal, ThreadListView.margin)
                    }
                }
                .zIndex(1)
            if model.threads.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background { Mascot() }
        .onChange(of: model.searchFocusRequest) {
            searchFocused = true
        }
        .onChange(of: model.searchText) { model.updateSearchSuggestions() }
    }

    /// Addresses for the `from:`/`to:` filter being typed; ↑↓ choose, ⇥ or ↩ complete.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.searchSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 10) {
                    if let email = suggestion.avatarEmail {
                        Avatar(name: suggestion.title, email: email, size: 22)
                    } else if let icon = suggestion.icon {
                        Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                    }
                    Text(suggestion.title)
                    if let subtitle = suggestion.subtitle {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index == model.searchSuggestionIndex { Keycap(symbol: "⇥") }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(index == model.searchSuggestionIndex ? Theme.selection : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.acceptSearchSuggestion(at: index) }
            }
        }
        .padding(5)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private func searchBar(text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all mail", text: text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    model.submitSearch()
                    searchFocused = false
                }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if model.activeSearch != nil {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            filterButton("From:", prefix: "from:")
            filterButton("To:", prefix: "to:")
            filterButton("In:", prefix: "in:")
            KeyHint(sequence: model.keymap.primary(for: .search))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 0.5))
        )
        .padding(.horizontal, Self.margin)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func filterButton(_ title: String, prefix: String) -> some View {
        Button {
            model.insertSearchFilter(prefix)
            searchFocused = true
            // Focusing selects all text; put the caret after the new filter instead.
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
            }
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(prefix == "in:" ? "Limit to a folder or label, e.g. in:sent" : "Filter by \(prefix == "from:" ? "sender" : "recipient"); addresses complete as you type")
    }

    /// A lazy stack instead of List: full control over the look and cheap updates for long lists.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DateGroup.group(model.threads), id: \.title) { group in
                        Text(group.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                            .padding(.bottom, 12)
                        ForEach(group.threads) { thread in
                            ThreadRow(
                                thread: thread,
                                isSelected: thread.id == model.selectedThreadID,
                                isChecked: model.checked.contains(thread.id)
                            )
                            .id(thread.id)
                            .onTapGesture {
                                model.selectedThreadID = thread.id
                                model.openSelectedThread()
                            }
                            .onAppear { model.loadMoreIfNeeded(thread) }
                        }
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, 16)
            }
            .onChange(of: model.listScrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
                model.listScrollTarget = nil
            }
            .onAppear {
                if let selected = model.selectedThreadID { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if model.activeSearch != nil {
                Text(model.isSearching ? "Searching…" : "No results").foregroundStyle(.secondary)
            } else {
                Image(systemName: syncing ? "tray.and.arrow.down" : "tray")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(syncing ? "Downloading mail…" : "All done here").font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var syncing: Bool {
        !model.syncStatus.compactMapValues { $0 }.isEmpty
    }
}

/// Newton-style buckets: Today, Yesterday, Last Week, then one per month.
struct DateGroup {
    let title: String
    var threads: [ThreadSummary]

    static func group(_ threads: [ThreadSummary], now: Date = Date()) -> [DateGroup] {
        var groups: [DateGroup] = []
        for thread in threads {
            let title = title(for: thread.latest.date, now: now)
            if groups.last?.title == title {
                groups[groups.count - 1].threads.append(thread)
            } else {
                groups.append(DateGroup(title: title, threads: [thread]))
            }
        }
        return groups
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    static func title(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return "Last Week"
        }
        return monthFormatter.string(from: date)
    }
}

struct ThreadRow: View {
    /// Same space before the avatar (where the unread dot sits) as after the date.
    static let inset: CGFloat = 14

    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    let isSelected: Bool
    let isChecked: Bool

    var body: some View {
        let latest = thread.latest
        HStack(spacing: 0) {
            // The unread dot lives inside the row, so the row's left edge lines up with the search field.
            // A fixed spacer holds it: a frame around an empty view would collapse to nothing.
            Color.clear
                .frame(width: ThreadRow.inset, height: 1)
                .overlay { indicator }
            HStack(spacing: 14) {
                Avatar(name: avatarAddress.name, email: avatarAddress.email, size: 30, outline: avatarColor)
                HStack(spacing: 6) {
                    Text(participants)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                        .foregroundStyle(thread.isUnread ? .primary : .secondary)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                .frame(width: 230, alignment: .leading)

                if thread.hasAttachments {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                }
                (Text(latest.subject.isEmpty ? "(no subject)" : latest.subject)
                    .fontWeight(thread.isUnread ? .semibold : .regular)
                    .foregroundStyle(thread.isUnread ? Color.primary : Color.secondary)
                 + Text(latest.snippet.isEmpty ? "" : " - " + latest.snippet).foregroundStyle(.secondary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if thread.isFlagged {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                }
                Text(ThreadRow.relative(latest.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
            }
            .padding(.trailing, ThreadRow.inset)
            .frame(height: 54)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.primary.opacity(0.055) : isChecked ? Theme.selection.opacity(0.6) : .clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .font(.system(size: 13.5))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        if isChecked {
            Image(systemName: "checkmark.circle").font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
        } else if thread.isUnread {
            Circle().fill(Theme.unread).frame(width: 9, height: 9)
        }
    }

    /// In a mixed list the avatar takes the account's colour, which also tells accounts apart.
    private var avatarColor: Color {
        let showsAccount = model.accounts.count > 1 && (model.mailbox.accountId == nil || model.activeSearch != nil)
        if showsAccount, let account = model.account(thread.latest.accountId) { return account.color }
        return Theme.unread
    }

    private var isOutgoing: Bool {
        model.mailbox.kind == .sent || model.mailbox.kind == .drafts
    }

    private var avatarAddress: EmailAddress {
        isOutgoing ? (thread.latest.to.first ?? thread.latest.from) : thread.latest.from
    }

    private var participants: String {
        if isOutgoing {
            let names = thread.latest.to.map(\.displayName)
            return "To: " + (names.isEmpty ? "(no recipients)" : names.joined(separator: ", "))
        }
        let names = thread.participants.isEmpty ? [thread.latest.from.displayName] : thread.participants
        return names.joined(separator: ", ")
    }

    /// "3m ago" and "5h ago" for today, otherwise a short date.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(seconds / 3600))h ago" }
        return format(date)
    }

    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// Žuća the postman, faintly in the middle behind the list. Can be turned off in Settings → General.
private struct Mascot: View {
    private static let image = Bundle.main.url(forResource: "Mascot", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    @AppStorage("showMascot") private var showMascot = true

    var body: some View {
        if showMascot, let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 400, height: 400)
                .opacity(0.12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
