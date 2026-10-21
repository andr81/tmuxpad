import SwiftUI
import TmuxPadCore

struct KeysView: View {
    @Environment(KeyLibrary.self) private var keys
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case create, importKey
        var id: String { rawValue }
    }

    var body: some View {
        List(keys.keys) { key in
            NavigationLink {
                KeyDetailView(keyID: key.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(key.name)
                    Text(key.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if keys.keys.isEmpty {
                ContentUnavailableView("Ключей нет", systemImage: "key", description: Text("Создайте ключ или импортируйте свой"))
            }
        }
        .navigationTitle("Ключи")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Создать", systemImage: "plus") { sheet = .create }
                    Button("Импортировать", systemImage: "square.and.arrow.down") { sheet = .importKey }
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create: NewKeyView()
            case .importKey: ImportKeyView()
            }
        }
    }
}

extension SSHKeyInfo.Kind {
    var title: String {
        switch self {
        case .secureEnclaveP256: "Secure Enclave P-256"
        case .ed25519: "Ed25519"
        }
    }

    /// Имя нового ключа по умолчанию.
    var defaultName: String {
        switch self {
        case .secureEnclaveP256: "iPad SE-key"
        case .ed25519: "iPad Ed25519"
        }
    }
}

#Preview {
    NavigationStack { KeysView() }.appEnvironment(try! AppEnvironment.inMemory())
}
