import SwiftUI

/// Выбор способа и ввод нового PIN или пароля дважды (§3.8): включение режима, смена способа
/// и «Забыли код?». Успех — `AppLock.configure`, затем `onDone`.
struct LockSetupForm: View {
    let lock: AppLock
    let submitTitle: String
    let onDone: () -> Void

    @State private var method: LockMethod
    @State private var code = ""
    @State private var repeated = ""
    @State private var busy = false
    @State private var error: String?

    init(lock: AppLock, initialMethod: LockMethod, submitTitle: String, onDone: @escaping () -> Void) {
        self.lock = lock
        self.submitTitle = submitTitle
        self.onDone = onDone
        let available = Self.methods(device: lock.device)
        _method = State(initialValue: available.contains(initialMethod) ? initialMethod : available[0])
    }

    var body: some View {
        Form {
            Section {
                Picker("Способ", selection: $method) {
                    ForEach(Self.methods(device: lock.device), id: \.self) { method in
                        Text(lock.title(of: method)).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(Self.footer(method: method, device: lock.device))
            }
            if method != .biometrics {
                Section {
                    SecureField(method == .pin ? "PIN, 4–8 цифр" : "Пароль, от 4 символов", text: $code)
                        .keyboardType(method == .pin ? .numberPad : .default)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Ещё раз", text: $repeated)
                        .keyboardType(method == .pin ? .numberPad : .default)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                } footer: {
                    if let issue = Self.codeIssue(code: code, repeated: repeated, method: method) {
                        Text(issue)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                Button(action: submit) {
                    if busy {
                        ProgressView()
                    } else {
                        Text(submitTitle)
                    }
                }
                .disabled(!canSubmit)
            } footer: {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: method) {
            code = ""
            repeated = ""
            error = nil
        }
    }

    private var canSubmit: Bool {
        !busy && (method == .biometrics || (Self.codeIssue(code: code, repeated: repeated, method: method) == nil && !repeated.isEmpty))
    }

    private func submit() {
        guard canSubmit else {
            return
        }
        busy = true
        error = nil
        let method = method
        let code = method == .biometrics ? nil : code
        Task {
            do throws(LockSetupError) {
                try await lock.configure(method: method, code: code)
                busy = false
                onDone()
            } catch {
                busy = false
                self.error = Self.text(error)
            }
        }
    }

    /// «Face ID» — только при коде-пароле на iPad: без него запросу не на что отступить.
    static func methods(device: any DeviceAuthInfo) -> [LockMethod] {
        device.canUseDeviceOwnerAuth ? LockMethod.allCases : [.pin, .password]
    }

    static func footer(method: LockMethod, device: any DeviceAuthInfo) -> String {
        switch method {
        case .biometrics:
            return "Если \(device.biometryName ?? "биометрия") не пройдёт, iPad спросит свой код-пароль."
        case .pin, .password:
            return device.canUseDeviceOwnerAuth
                ? "Забытый код можно сбросить кодом-паролем iPad."
                : "На iPad нет кода-пароля: забытый код сбрасывается только переустановкой приложения."
        }
    }

    /// Пустое поле подсказки не требует: кнопка просто неактивна.
    static func codeIssue(code: String, repeated: String, method: LockMethod) -> String? {
        if !code.isEmpty, !AppLock.isValid(code, for: method) {
            return method == .pin ? "PIN — от 4 до 8 цифр" : "Пароль — от 4 до 128 символов"
        }
        if !repeated.isEmpty, repeated != code {
            return method == .pin ? "PIN не совпадает" : "Пароли не совпадают"
        }
        return nil
    }

    static func text(_ error: LockSetupError) -> String {
        switch error {
        case .notAuthorized: "Сначала подтвердите текущий способ"
        case .invalidCode: "Код не подходит"
        case .biometricsUnavailable: "На iPad не задан код-пароль"
        case .biometricsDenied: "Проверка не пройдена"
        case .storeFailed: "Не удалось сохранить код в Keychain"
        }
    }
}
