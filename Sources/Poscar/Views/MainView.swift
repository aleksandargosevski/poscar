import AppKit
import PoscarCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A plain split instead of NavigationSplitView: on macOS 26 its sidebar floats up under the
        // title bar, while here the toolbar spans the whole window and the sidebar sits below it.
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .frame(width: 240)
                    .transition(.move(edge: .leading))
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
            }
            ContentArea()
        }
        .animation(.easeOut(duration: 0.18), value: model.sidebarVisible)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(Theme.barTop, for: .windowToolbar)
        .navigationTitle(model.mailboxTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CommandButton(command: .toggleSidebar, icon: "sidebar.left", showTitle: false, bordered: false)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                CommandButton(command: .refresh, icon: "arrow.clockwise", title: "Check mail", bordered: false)
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
        .background(WindowAccessor { window in model.mainWindow = window })
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
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
