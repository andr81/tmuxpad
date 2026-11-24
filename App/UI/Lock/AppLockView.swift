import SwiftUI

/// Экран блокировки (§3.8): Face ID, PIN или пароль; «Забыли код?» — код-пароль iPad и новый код.
struct AppLockView: View {
    let phase: ScenePhase
    @Environment(AppLock.self) private var lock
    @State private var code = ""
    @State private var message: String?
    @State private var busy = false
    /// После «Забыли код?»: задать новый код или выключить режим.
    @State private var resetting = false
    /// Face ID спрашивается сам один раз за возврат: сам запрос переводит сцену в `.inactive`,
    /// и без флага отказ запускал бы его снова по кругу.
    @State private var autoPrompted = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if resetting {
                NavigationStack {
                    LockSetupForm(lock: lock, initialMethod: lock.method, submitTitle: "Сохранить и разблокировать") {}
                        .navigationTitle("Новый код")
                        .toolbar {
                            ToolbarItem(placement: .destructiveAction) {
                                Button("Выключить блокировку", role: .destructive) {
                                    try? lock.disable()
                                }
                            }
                        }
                }
            } else {
                unlockScreen
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: phase, initial: true) { _, phase in
            switch phase {
            case .active:
                if lock.method == .biometrics, !autoPrompted {
                    autoPrompted = true
                    Task { await lock.unlockWithBiometrics() }
                } else if lock.method != .biometrics {
                    focused = true
                }
            case .background:
                autoPrompted = false
                code = ""
                message = nil
            default:
                break
            }
        }
    }

    private var unlockScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("TmuxPad заблокирован")
                .font(.title2)
            if lock.method == .biometrics {
                Button("Разблокировать: \(lock.title(of: .biometrics))") {
                    Task { await lock.unlockWithBiometrics() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                SecureField(lock.method == .pin ? "PIN" : "Пароль", text: $code)
                    .focused($focused)
                    .keyboardType(lock.method == .pin ? .numberPad : .default)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .font(.title3.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit(submit)
                    .disabled(busy)
                Button("Разблокировать", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.isEmpty || busy)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if lock.device.canUseDeviceOwnerAuth {
                    Button("Забыли код?") {
                        Task {
                            if await lock.authorizeWithDevicePasscode() {
                                resetting = true
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Без кода-пароля iPad забытый код сбрасывается только переустановкой приложения")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard !busy, !code.isEmpty else {
            return
        }
        busy = true
        let entered = code
        Task {
            let result = await lock.unlock(code: entered)
            busy = false
            code = ""
            message = Self.message(for: result, method: lock.method)
            focused = true
        }
    }

    /// Текст под полем после проверки; `nil` — код принят.
    static func message(for result: CodeCheck, method: LockMethod) -> String? {
        switch result {
        case .accepted:
            nil
        case .rejected:
            method == .pin ? "Неверный PIN" : "Неверный пароль"
        case let .paused(until):
            "Слишком много попыток. Повторите после \(until.formatted(date: .omitted, time: .standard))"
        case .missing:
            "Кода нет на этом устройстве. Сбросьте его через «Забыли код?»"
        }
    }
}
