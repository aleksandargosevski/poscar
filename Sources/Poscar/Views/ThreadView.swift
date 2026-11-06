import PoscarCore
import SwiftUI

/// An open conversation, shown in place of the list.
struct ThreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            if let rendered = model.renderedThread {
                ReaderWebView(html: rendered.html, model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CommandButton(command: .backToList, icon: "chevron.left", title: model.displayName(for: model.mailbox.kind))
            Spacer()
            CommandButton(command: .previousMessage, icon: "chevron.up", title: "Newer")
            CommandButton(command: .nextMessage, icon: "chevron.down", title: "Older")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(BarBackground(edge: .top))
    }
}
