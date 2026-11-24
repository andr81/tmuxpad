import SwiftUI

/// «Настройки» → «Безопасный режим» (§3.8). Выключить, сменить способ или код — после проверки
/// текущим способом.
struct AppLockSettingsView: View {
    @Environment(AppLock.self) private var lock
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case enable
        case disable
        case change

        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Блокировать приложение", isOn: Binding(
                    get: { lock.enabled },
                    set: { sheet = $0 ? .enable : .disable }
                ))
            } footer: {
                Text("При запуске и после возврата из фона приложение спросит Face ID, PIN или пароль. Face ID для ключей настраивается отдельно, в разделе «Ключи».")
            }
            if lock.enabled {
                Section {
                    LabeledContent("Способ", value: lock.title(of: lock.method))
                    Button("Сменить способ или код") { sheet = .change }
                    Picker("Блокировать через", selection: Binding(get: { lock.delay }, set: { lock.setDelay($0) })) {
                        ForEach(LockDelay.allCases, id: \.self) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                } footer: {
                    Text("Столько приложение может пробыть в фоне, не блокируясь. При запуске оно блокируется всегда.")
                }
            }
        }
        .navigationTitle("Безопасный режим")
        // закрытый без изменений лист не оставляет разрешение на смену
        .sheet(item: $sheet, onDismiss: { lock.cancelChange() }) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .enable:
                        LockSetupForm(lock: lock, initialMethod: .biometrics, submitTitle: "Включить") { self.sheet = nil }
                            .navigationTitle("Безопасный режим")
                    case .disable:
                        LockVerifyView(lock: lock) {
                            try? lock.disable()
                            self.sheet = nil
                        }
                    case .change:
                        LockChangeView(lock: lock) { self.sheet = nil }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { self.sheet = nil }
                    }
                }
            }
        }
    }
}

/// Проверка текущим способом; «Забыли код?» — код-пароль устройства.
struct LockVerifyView: View {
    let lock: AppLock
    let onVerified: () -> Void

    @State private var code = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            if lock.method == .biometrics {
                Section {
                    Button("Проверить: \(lock.title(of: .biometrics))", action: verify)
                        .disabled(busy)
                } footer: {
                    if let message {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Section {
                    SecureField(lock.method == .pin ? "Текущий PIN" : "Текущий пароль", text: $code)
                        .keyboardType(lock.method == .pin ? .numberPad : .default)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(verify)
                    Button("Проверить", action: verify)
                        .disabled(code.isEmpty || busy)
                } footer: {
                    if let message {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
                if lock.device.canUseDeviceOwnerAuth {
                    Section {
                        Button("Забыли код?") {
                            Task {
                                if await lock.authorizeWithDevicePasscode() {
                                    onVerified()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Текущий способ")
        .task {
            if lock.method == .biometrics {
                verify()
            }
        }
    }

    private func verify() {
        guard !busy else {
            return
        }
        busy = true
        let entered = code
        Task {
            let result = await lock.authorizeChange(code: entered)
            busy = false
            code = ""
            if result == .accepted {
                onVerified()
            } else {
                message = lock.method == .biometrics ? "Проверка не пройдена" : AppLockView.message(for: result, method: lock.method)
            }
        }
    }
}

/// Смена способа или кода: сначала проверка, потом новый способ.
struct LockChangeView: View {
    let lock: AppLock
    let onDone: () -> Void
    @State private var verified = false

    var body: some View {
        if verified {
            LockSetupForm(lock: lock, initialMethod: lock.method, submitTitle: "Сохранить", onDone: onDone)
                .navigationTitle("Новый способ")
        } else {
            LockVerifyView(lock: lock) { verified = true }
        }
    }
}
