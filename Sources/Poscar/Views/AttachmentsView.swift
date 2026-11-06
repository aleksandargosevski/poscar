import AppKit
import PoscarCore
import SwiftUI

/// Every attachment of downloaded mail, searchable and filterable by type and account.
struct AttachmentsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            searchBar(text: $model.attachmentFilter.text)
            kindFilters
            if model.attachments.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(model.attachments) { record in
                                AttachmentCard(record: record, isSelected: record.id == model.selectedAttachmentID)
                                    .id(record.id)
                                    .onTapGesture(count: 2) { model.openAttachment(record) }
                                    .onTapGesture { model.selectedAttachmentID = record.id }
                                    .contextMenu {
                                        Button("Open") { model.openAttachment(record) }
                                        Button("Show in Finder") { model.revealAttachment(record) }
                                        Button("Show Message") { model.showMessage(of: record) }
                                    }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(GeometryReader { geometry in
                            Color.clear
                                .onAppear { updateColumns(width: geometry.size.width) }
                                .onChange(of: geometry.size.width) { _, width in updateColumns(width: width) }
                        })
                    }
                    .onChange(of: model.selectedAttachmentID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }

    /// Mirrors how the adaptive grid lays out columns: 170pt minimum, 16pt spacing, 22pt margins.
    private func updateColumns(width: CGFloat) {
        model.attachmentColumns = max(1, Int((width - 44 + 16) / (170 + 16)))
    }

    private func searchBar(text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search attachments by name, sender or subject", text: text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            KeyHint(sequence: model.keymap.primary(for: .search))
            if model.accounts.count > 1 {
                Menu {
                    Button("All accounts") { model.attachmentFilter.accountId = nil }
                    Divider()
                    ForEach(model.accounts) { account in
                        Button(account.email) { model.attachmentFilter.accountId = account.id }
                    }
                } label: {
                    Text(model.attachmentFilter.accountId.flatMap(model.account)?.email ?? "All accounts")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 0.5))
        )
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var kindFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", icon: "square.grid.2x2", count: model.attachmentCounts.values.reduce(0, +), kind: nil)
                ForEach(AttachmentKind.allCases, id: \.self) { kind in
                    if let count = model.attachmentCounts[kind], count > 0 {
                        chip(title: kind.title, icon: kind.systemImage, count: count, kind: kind)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }
    }

    private func chip(title: String, icon: String, count: Int, kind: AttachmentKind?) -> some View {
        let selected = model.attachmentFilter.kind == kind
        return Button {
            model.attachmentFilter.kind = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Theme.selection : Theme.card))
            .overlay(Capsule().strokeBorder(selected ? Theme.selectionEdge : Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "paperclip").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(model.attachmentFilter == AttachmentFilter() ? "No attachments yet" : "No matching attachments")
                .font(.title3).foregroundStyle(.secondary)
            Text("Attachments from mail of the last 90 days and from opened messages appear here.")
                .font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AttachmentCard: View {
    let record: AttachmentRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The image sits in an overlay so wide pictures can't widen the card and overlap neighbours.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 124)
                .overlay(alignment: .top) { preview }
                .clipped()
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(record.sender) · \(ThreadRow.format(record.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? Theme.selection : Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(record.subject)
    }

    @ViewBuilder
    private var preview: some View {
        if let image = ThumbnailCache.image(for: record) {
            GeometryReader { proxy in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .clipped()
            }
            .background(Color.white)
        } else {
            ZStack {
                Theme.canvas
                Image(systemName: record.kind.systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Decoded thumbnails, so scrolling the grid doesn't decode the same JPEG again.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSNumber, NSImage>()

    static func image(for record: AttachmentRecord) -> NSImage? {
        guard let id = record.id, let data = record.thumbnail else { return nil }
        if let cached = cache.object(forKey: NSNumber(value: id)) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: NSNumber(value: id))
        return image
    }
}
