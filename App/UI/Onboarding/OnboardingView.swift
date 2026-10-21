import SwiftUI
import TmuxPadCore

/// Первый запуск (§3.7): ключ → публичный ключ и команда → сервер → проверка → подготовка →
/// «Готово». Экраны настроек переиспользуются в режиме онбординга; порядок шагов —
/// `OnboardingStep`. «Пропустить» на каждом шаге закрывает онбординг навсегда.
struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.appEnvironment) private var env
    @Environment(KeyLibrary.self) private var keys
    @Environment(ServerStore.self) private var servers
    @State private var path: [OnboardingStep] = []
    /// Ключ и сервер, созданные в онбординге.
    @State private var keyID: UUID?
    @State private var serverID: UUID?

    private var context: OnboardingContext {
        OnboardingContext(
            secureEnclaveAvailable: keys.secureEnclaveAvailable,
            keyID: keyID.flatMap { keys.key(id: $0)?.id },
            serverID: serverID.flatMap { servers.server(id: $0)?.id }
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen(OnboardingStep.first(context: context))
                .navigationDestination(for: OnboardingStep.self) { screen($0) }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func screen(_ step: OnboardingStep) -> some View {
        switch step {
        case let .key(kind):
            OnboardingKeyStep(defaultKind: kind, keyID: context.keyID) { key in
                keyID = key.id
                advance(from: step)
            } onContinue: {
                advance(from: step)
            }
            .skippable(finish)
        case let .publicKey(id):
            KeyDetailView(keyID: id, allowsDelete: false)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        nextButton(from: step)
                    }
                }
                .skippable(finish)
        case let .server(keyID):
            let existing = context.serverID.flatMap { servers.server(id: $0) }
            ServerEditView(config: existing ?? ServerConfig(label: "", host: "", user: "", keyID: keyID), isNew: existing == nil) { config in
                serverID = config.id
                advance(from: step)
            }
            .toolbar {
                if existing != nil {
                    ToolbarItem(placement: .primaryAction) {
                        nextButton(from: step)
                    }
                }
            }
            .skippable(finish)
        case let .check(id):
            ServerCheckView(serverID: id, action: .check) { advance(from: step) }
                .skippable(finish)
        case let .prepare(id):
            ServerCheckView(serverID: id, action: .prepare) { advance(from: step) }
                .skippable(finish)
        case .done:
            OnboardingDoneStep(onFinish: finish)
        }
    }

    private func nextButton(from step: OnboardingStep) -> some View {
        Button("Далее") { advance(from: step) }
            .accessibilityIdentifier("onboarding.next")
    }

    /// Следующий шаг; шаг, который уже в стеке (ключ или сервер пропали), — возврат к нему.
    private func advance(from step: OnboardingStep) {
        guard let next = OnboardingStep.next(after: step, context: context) else {
            finish()
            return
        }
        if let index = path.firstIndex(of: next) {
            path.removeSubrange((index + 1)...)
        } else if case .key = next {
            path = []
        } else {
            path.append(next)
        }
    }

    private func finish() {
        if let env {
            OnboardingFlag.markDone(env.defaults)
        }
        onFinish()
    }
}

private extension View {
    func skippable(_ skip: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Пропустить", action: skip)
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }
}

/// Шаг ключа: создать (SE по умолчанию, если есть) или, если ключ уже создан, идти дальше.
private struct OnboardingKeyStep: View {
    let defaultKind: SSHKeyInfo.Kind
    let keyID: UUID?
    let onCreated: (SSHKeyInfo) -> Void
    let onContinue: () -> Void

    @Environment(KeyLibrary.self) private var keys
    @State private var kind: SSHKeyInfo.Kind?
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    private var selectedKind: SSHKeyInfo.Kind { kind ?? defaultKind }

    var body: some View {
        Form {
            Section {
                Text("TmuxPad подключается к серверам по SSH-ключу этого iPad. Создайте ключ, добавьте его на сервер и подготовьте сервер — это займёт пару минут.")
            }
            if let keyID, let key = keys.key(id: keyID) {
                Section {
                    LabeledContent("Ключ создан", value: key.name)
                    Button("Далее", action: onContinue)
                        .accessibilityIdentifier("onboarding.next")
                }
            } else {
                if keys.secureEnclaveAvailable {
                    Picker("Тип", selection: Binding(get: { selectedKind }, set: { newKind in
                        if name == selectedKind.defaultName {
                            name = newKind.defaultName
                        }
                        kind = newKind
                    })) {
                        ForEach([SSHKeyInfo.Kind.secureEnclaveP256, .ed25519], id: \.self) { Text($0.title).tag($0) }
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
                Section {
                    Button("Создать ключ", systemImage: "key", action: create)
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("onboarding.createKey")
                }
            }
        }
        .navigationTitle("Добро пожаловать")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(message: $error)
        .onAppear {
            if name.isEmpty {
                name = selectedKind.defaultName
            }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                onCreated(try await keys.create(kind: selectedKind, name: name.trimmingCharacters(in: .whitespaces)))
            } catch {
                self.error = userText(error)
            }
        }
    }
}

private struct OnboardingDoneStep: View {
    let onFinish: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Сервер готов", systemImage: "checkmark.circle")
        } description: {
            Text("Проекты сервера появятся в сайдбаре. Новая сессия — «+» у проекта или ⌘N.")
        } actions: {
            Button("Начать", action: onFinish)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.finish")
        }
        .navigationBarBackButtonHidden()
    }
}

#Preview {
    OnboardingView {}.appEnvironment(try! AppEnvironment.inMemory())
}
