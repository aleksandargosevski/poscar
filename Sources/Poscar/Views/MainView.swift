import AppKit
import PoscarCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    /// Height of title bar plus toolbar, read from the window: SwiftUI reports 0 for it here.
    @State private var titlebarHeight: CGFloat = 52

    var body: some View {
        // A plain split instead of NavigationSplitView, whose sidebar floats on macOS 26. The toolbar
        // is transparent and the backdrop paints both columns up to the top, so the title bar is split
        // in the sidebar's and the content's colours.
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                SidebarResizeHandle(width: $sidebarWidth)
            }
            ContentArea()
        }
        .background {
            WindowBackdrop(sidebarWidth: model.sidebarVisible ? sidebarWidth : 0, toolbarHeight: titlebarHeight)
        }
        .animation(.easeOut(duration: 0.18), value: model.sidebarVisible)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(model.mailboxTitle)
        .hidingWindowTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CommandButton(command: .toggleSidebar, icon: "sidebar.left", showTitle: false, bordered: false)
            }
            titleItem
            // Without the system title nothing pushes these right, so a flexible space does.
            ToolbarItemGroup(placement: .automatic) {
                Spacer()
                RefreshButton()
                CommandButton(command: .compose, icon: "square.and.pencil", bordered: false)
            }
        }
        .overlay(alignment: .top) {
            if model.overlay == .palette, !model.paletteMode.isPopover {
                PaletteView()
                    .padding(.top, 70)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay {
            if model.overlay == .shortcuts {
                ShortcutsOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.overlay)
        .background(WindowAccessor { window in
            model.mainWindow = window
            let height = window.frame.height - window.contentLayoutRect.height
            if height > 0, abs(height - titlebarHeight) > 0.5 {
                DispatchQueue.main.async { titlebarHeight = height }
            }
        })
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
    }
}

extension MainView {
    /// The folder title as its own toolbar item, so macOS 26 doesn't put it in the sidebar button's
    /// glass capsule; it is shifted to line up with the content below.
    @ToolbarContentBuilder
    var titleItem: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) {
                ToolbarTitle(title: model.mailboxTitle, sidebarWidth: model.sidebarVisible ? sidebarWidth : 0)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if #available(macOS 15, *) {
            ToolbarItem(placement: .navigation) {
                ToolbarTitle(title: model.mailboxTitle, sidebarWidth: model.sidebarVisible ? sidebarWidth : 0)
            }
        }
    }
}

private struct ToolbarTitle: View {
    let title: String
    let sidebarWidth: CGFloat
    @State private var originX: CGFloat?

    var body: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .padding(.leading, leadingPadding)
            .background(GeometryReader { geometry in
                let x = geometry.frame(in: .global).minX
                Color.clear
                    .onAppear { record(x) }
                    .onChange(of: x) { _, newX in record(newX) }
            })
    }

    /// Pushes the title to where the content starts: past the sidebar plus the list margin.
    private var leadingPadding: CGFloat {
        guard let originX, sidebarWidth > 0 else { return 0 }
        return max(0, sidebarWidth + ThreadListView.margin - originX)
    }

    /// Toolbar layout must not change state mid-update, so the measured origin is stored afterwards.
    private func record(_ x: CGFloat) {
        DispatchQueue.main.async {
            if originX.map({ abs($0 - x) > 0.5 }) ?? true { originX = x }
        }
    }
}

/// Both column colours reaching under the transparent toolbar, plus the line below the content's bar.
private struct WindowBackdrop: View {
    let sidebarWidth: CGFloat
    let toolbarHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Theme.sidebarTop.frame(width: sidebarWidth)
            VStack(spacing: 0) {
                Theme.barTop.frame(height: toolbarHeight)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                Theme.canvas
            }
        }
        .ignoresSafeArea()
    }
}

/// The hairline between sidebar and content, draggable to resize the sidebar.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    static let range = 180.0...420.0

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 0.5)
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

private extension View {
    /// The title is drawn by `ToolbarLeading` so it can sit over the content column.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// The list, or the open conversation in its place, with the action bar underneath.
struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.showingScheduled {
                    ScheduledView()
                } else if model.showingAttachments {
                    AttachmentsView()
                } else if model.focus == .reader {
                    ThreadView()
                } else {
                    ThreadListView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if model.isRefreshing { RefreshProgressBar().transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: model.isRefreshing)
            ActionFooter()
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottomTrailing) {
            if model.overlay == .palette, model.paletteMode.isPopover {
                PaletteView()
                    .padding(.trailing, 14)
                    .padding(.bottom, 54)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 62)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

/// "Check mail" that turns into a spinning, disabled "Checking…" while accounts are checked.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    @State private var angle = 0.0

    var body: some View {
        Button {
            model.perform(.refresh)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(angle))
                Text(model.isRefreshing ? "Checking…" : "Check mail")
                    .monospacedDigit()
                KeyHint(sequence: model.keymap.primary(for: .refresh))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HintButtonStyle(bordered: false))
        .disabled(model.isRefreshing)
        .help("Check for new mail")
        .onChange(of: model.isRefreshing) { _, refreshing in spin(refreshing) }
        .onAppear { spin(model.isRefreshing) }
    }

    private func spin(_ refreshing: Bool) {
        if refreshing {
            angle = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            // Replacing the repeating animation with a short one stops it at rest.
            withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
        }
    }
}

/// A thin indeterminate bar under the toolbar while mail is being checked.
private struct RefreshProgressBar: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule()
                .fill(LinearGradient(
                    colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: width * 0.35, height: 2)
                .offset(x: width * phase)
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Raycast-style bar: status on the left, the main action and the Actions button on the right.
struct ActionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 12)
            primaryAction
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            CommandButton(command: .showActions, title: "Actions")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(BarBackground(edge: .bottom))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.showingAttachments {
            if let record = model.attachments.first(where: { $0.id == model.selectedAttachmentID }) {
                ShortcutButton(title: "Show in Finder", icon: "folder", keys: "o") { model.revealAttachment(record) }
                ShortcutButton(title: "Open", icon: "arrow.up.forward.square", keys: "enter") { model.openAttachment(record) }
            }
        } else if model.focus == .reader {
            CommandButton(command: .reply, icon: "arrowshape.turn.up.left")
        } else if model.selectedThreadID != nil, !model.showingScheduled, !model.showingAttachments {
            CommandButton(command: .openThread, icon: "envelope.open", title: "Open")
        } else {
            CommandButton(command: .compose, icon: "square.and.pencil")
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if !model.pendingKeys.isEmpty {
                KeyHint(sequence: KeySequence(model.pendingKeys), prominent: true)
                Text("…")
            } else if let status = model.syncStatus.values.compactMap({ $0 }).first {
                ProgressView().controlSize(.mini)
                Text(status).lineLimit(1)
            } else if let error = model.accountErrors.values.first {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(1).help(error)
            } else if !model.checked.isEmpty {
                Text("\(model.checked.count) selected")
            } else if model.showingAttachments {
                Text(model.attachments.count == 1 ? "1 attachment" : "\(model.attachments.count) attachments")
            } else if model.focus == .reader, let index = model.selectedIndex {
                Text("\(index + 1) of \(model.threads.count)")
            } else {
                Text(model.threads.count == 1 ? "1 conversation" : "\(model.threads.count) conversations")
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            if toast.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(toast.text)
                .lineLimit(2)
            if toast.undoable {
                CommandButton(command: .undo)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ButtonSurface(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .frame(maxWidth: 520)
    }
}

/// Gives the model a reference to the hosting window so the key router knows where keys come from.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}
