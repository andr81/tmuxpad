import SwiftUI
import UniformTypeIdentifiers

/// Импорт OpenSSH Ed25519: файлом или вставкой текста, с паролем, если ключ зашифрован.
struct ImportKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(KeyLibrary.self) private var keys
    @State private var name = "Импорт Ed25519"
    @State private var text = ""
    @State private var passphrase = ""
    @State private var showImporter = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 160)
                    Button("Выбрать файл…", systemImage: "doc") { showImporter = true }
                } header: {
                    Text("Приватный ключ")
                } footer: {
                    Text("Текст из файла вида id_ed25519, начиная с -----BEGIN OPENSSH PRIVATE KEY-----.")
                }
                Section {
                    SecureField("Пароль ключа (если есть)", text: $passphrase)
                }
            }
            .navigationTitle("Импорт ключа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Импортировать", action: importKey)
                        .disabled(working || text.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text]) { result in
                switch result {
                case let .success(url): read(url)
                case let .failure(error): self.error = userText(error)
                }
            }
            .errorAlert(message: $error)
        }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            name = url.lastPathComponent
        } catch {
            self.error = "Не удалось прочитать файл: \(error.localizedDescription)"
        }
    }

    private func importKey() {
        working = true
        Task {
            defer { working = false }
            do {
                try await keys.importKey(
                    name: name.trimmingCharacters(in: .whitespaces),
                    text: text,
                    passphrase: passphrase.isEmpty ? nil : passphrase
                )
                dismiss()
            } catch {
                self.error = userText(error)
            }
        }
    }
}

#Preview {
    ImportKeyView().appEnvironment(try! AppEnvironment.inMemory())
}
