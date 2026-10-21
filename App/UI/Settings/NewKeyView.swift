import SwiftUI
import TmuxPadCore

/// Новый ключ: Secure Enclave (если есть) или Ed25519 в Keychain.
struct NewKeyView: View {
    /// Вызывается после создания, до закрытия sheet.
    var onCreated: (SSHKeyInfo) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(KeyLibrary.self) private var keys
    @State private var kind: SSHKeyInfo.Kind?
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    private var kinds: [SSHKeyInfo.Kind] {
        keys.secureEnclaveAvailable ? [.secureEnclaveP256, .ed25519] : [.ed25519]
    }

    private var selectedKind: SSHKeyInfo.Kind { kind ?? kinds[0] }

    var body: some View {
        NavigationStack {
            Form {
                if kinds.count > 1 {
                    Picker("Тип", selection: Binding(get: { selectedKind }, set: { newKind in
                        if name == selectedKind.defaultName {
                            name = newKind.defaultName
                        }
                        kind = newKind
                    })) {
                        ForEach(kinds, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    TextField("Название", text: $name)
                } footer: {
                    Text(selectedKind == .secureEnclaveP256
                        ? "Приватная часть не покидает Secure Enclave этого iPad."
                        : "Приватная часть хранится в Keychain этого iPad и не попадает в бэкапы.")
                }
            }
            .navigationTitle("Новый ключ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать", action: create)
                        .accessibilityIdentifier("newKey.create")
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert(message: $error)
            .onAppear {
                if name.isEmpty {
                    name = selectedKind.defaultName
                }
            }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                let info = try await keys.create(kind: selectedKind, name: name.trimmingCharacters(in: .whitespaces))
                onCreated(info)
                dismiss()
            } catch {
                self.error = userText(error)
            }
        }
    }
}

#Preview {
    NewKeyView().appEnvironment(try! AppEnvironment.inMemory())
}
