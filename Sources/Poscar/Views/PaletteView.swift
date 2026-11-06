import PoscarCore
import SwiftUI

/// The command palette (centred) and the Actions popover (above the Actions button), like Raycast.
struct PaletteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.paletteItems
        let isPopover = model.paletteMode.isPopover
        VStack(spacing: 0) {
            if isPopover {
                if model.paletteMode == .actions {
                    Text(model.actionsTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                results(items)
                Divider()
                searchField($model.paletteQuery)
            } else {
                searchField($model.paletteQuery)
                Divider()
                results(items)
                Divider()
                footer
            }
        }
        .frame(width: isPopover ? 400 : 600)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(Theme.card.opacity(0.55)))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
    }

    private func searchField(_ text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            if !model.paletteMode.isPopover {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            FocusedTextField(text: text, placeholder: model.palettePlaceholder, fontSize: model.paletteMode.isPopover ? 14 : 17)
                .frame(height: 22)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, model.paletteMode.isPopover ? 11 : 14)
    }

    private func results(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        Text("No matches").foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if showsSectionDivider(items, at: index) {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.vertical, 5).padding(.horizontal, 8)
                        }
                        row(item, selected: index == model.paletteIndex)
                            .id(item.id)
                            .onTapGesture { model.runPaletteItem(at: index) }
                    }
                }
                .padding(6)
                // Rebuild rows for every query so no stale row survives filtering.
                .id(model.paletteQuery)
            }
            .frame(maxHeight: model.paletteMode.isPopover ? 380 : 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.paletteIndex) { _, index in
                if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
    }

    /// Sections are separated by a line, as in Raycast, unless the user is filtering.
    private func showsSectionDivider(_ items: [PaletteItem], at index: Int) -> Bool {
        guard index > 0, model.paletteQuery.isEmpty, let section = items[index].section else { return false }
        return items[index - 1].section != section
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 20)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary).font(.callout).lineLimit(1)
            }
            Spacer()
            KeyHint(sequence: item.shortcut, prominent: selected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.selection)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.selectionEdge, lineWidth: 0.5))
            }
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            footerHint(["↑", "↓"], "Navigate")
            footerHint(["↩"], "Run")
            footerHint(["esc"], "Close")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func footerHint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { Keycap(symbol: $0) }
            Text(title).padding(.leading, 2)
        }
    }
}

struct ShortcutsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { model.overlay = nil }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyboard Shortcuts").font(.title2.bold())
                    Spacer()
                    Text("\(model.keymap.preset.title) preset").foregroundStyle(.secondary)
                    Keycap(symbol: "esc")
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28), GridItem(.flexible())],
                              alignment: .leading, spacing: 20) {
                        ForEach(CommandCategory.allCases, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.rawValue).font(.headline)
                                ForEach(CommandID.allCases.filter { $0.category == category && model.keymap.primary(for: $0) != nil }, id: \.self) { command in
                                    HStack {
                                        Text(command.title).foregroundStyle(.secondary)
                                        Spacer(minLength: 10)
                                        KeyHint(sequence: model.keymap.primary(for: command))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 940, maxHeight: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(radius: 30)
            .padding(40)
        }
    }
}
