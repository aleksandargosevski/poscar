import PoscarCore
import SwiftUI

struct ScheduledView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.scheduled.isEmpty {
                ContentUnavailableView("Nothing scheduled", systemImage: "clock", description: Text("Use Send later in a draft."))
            } else {
                List(model.scheduled) { item in
                    ScheduledRow(item: item)
                }
                .listStyle(.inset)
            }
            Divider()
            Text("Scheduled messages are sent while Pošćar is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
    }
}

private struct ScheduledRow: View {
    @Environment(AppModel.self) private var model
    let item: OutboxRecord

    var body: some View {
        let message = try? item.decodedMessage()
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("To: " + (message?.to.map(\.displayName).joined(separator: ", ") ?? "?")).lineLimit(1)
                Text(message?.subject.isEmpty == false ? message!.subject : "(no subject)").lineLimit(1)
                Text(item.sendAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = item.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Edit") { if let id = item.id { model.cancelSend(id) } }
            Button("Send now") { if let id = item.id { model.sendNow(id) } }
        }
        .padding(.vertical, 4)
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Pošćar").font(.largeTitle.bold())
            Text("A fast, keyboard-first mail app. Add an account to start.")
                .foregroundStyle(.secondary)
            AccountSetupView(onDone: {})
                .frame(width: 460)
                .padding(20)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
