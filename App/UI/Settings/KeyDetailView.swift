import SwiftUI
import TmuxPadCore

/// Публичный ключ: текст, копирование, «Поделиться», QR и команда для сервера.
struct KeyDetailView: View {
    let keyID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(KeyLibrary.self) private var keys
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        if let key = keys.key(id: keyID) {
            content(key)
        } else {
            ContentUnavailableView("Ключ удалён", systemImage: "key")
        }
    }

    private func content(_ key: SSHKeyInfo) -> some View {
        let command = SSHKeys.authorizedKeysCommand(publicKey: key.publicKeyOpenSSH)
        return Form {
            Section {
                LabeledContent("Тип", value: key.kind.title)
                LabeledContent("Создан", value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Публичный ключ") {
                Text(key.publicKeyOpenSSH)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Скопировать", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = key.publicKeyOpenSSH
                }
                ShareLink(item: key.publicKeyOpenSSH) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                QRCodeView(text: key.publicKeyOpenSSH)
                    .frame(maxWidth: .infinity)
            }
            Section {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Скопировать команду", systemImage: "terminal") {
                    UIPasteboard.general.string = command
                }
            } header: {
                Text("Команда для сервера")
            } footer: {
                Text("Выполните её на сервере, чтобы он принимал этот ключ.")
            }
            Section {
                Button("Удалить ключ", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(key.name)
        .confirmationDialog("Удалить ключ «\(key.name)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { delete(key) }
        } message: {
            Text("Серверы, которые принимают этот ключ, больше не пустят с этого iPad.")
        }
        .errorAlert("Ключ не удалён", message: $error)
    }

    private func delete(_ key: SSHKeyInfo) {
        Task {
            do {
                try await keys.delete(key.id)
                dismiss()
            } catch {
                self.error = userText(error)
            }
        }
    }
}
