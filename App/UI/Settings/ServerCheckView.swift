import SwiftUI
import TmuxPadCore

/// Ход и итог проверки сервера: статус host-скрипта и чеклист `doctor`. Открывается с
/// действием, которое сразу запускается.
struct ServerCheckView: View {
    enum Action {
        case check
        case prepare
    }

    let serverID: UUID
    let action: Action

    @Environment(\.appEnvironment) private var env
    @State private var model: ServerCheckModel?

    var body: some View {
        Group {
            if let model {
                ServerCheckContent(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(action == .check ? "Проверка подключения" : "Подготовка сервера")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil, let env else {
                return
            }
            let model = ServerCheckModel(serverID: serverID, environment: env)
            self.model = model
            switch action {
            case .check: model.check()
            case .prepare: model.prepare()
            }
        }
    }
}

private struct ServerCheckContent: View {
    let model: ServerCheckModel

    var body: some View {
        Form {
            if let config = model.config {
                Section {
                    LabeledContent("Сервер") {
                        Text(verbatim: "\(config.user)@\(config.host):\(config.port)")
                    }
                }
            }
            switch model.state {
            case .idle:
                Section {
                    Text("Проверка не запускалась")
                        .foregroundStyle(.secondary)
                }
            case let .running(step):
                Section {
                    HStack {
                        ProgressView()
                        Text(stepText(step))
                            .padding(.leading, 8)
                    }
                }
            case .trustPrompt:
                Section {
                    Text("Ждём решения: доверять ли ключу сервера")
                        .foregroundStyle(.secondary)
                }
            case .hostKeyChanged:
                Section {
                    Label("Ключ сервера изменился — подключение заблокировано", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                }
            case .authFailed:
                Section {
                    Label("Сервер не принял ключ", systemImage: "key.slash")
                        .foregroundStyle(.red)
                }
            case let .done(status, report):
                Section("Host-скрипт") {
                    Text(bootstrapStatusText(status))
                }
                if let report {
                    Section {
                        DoctorReportView(report: report)
                    } header: {
                        Text("Проверка сервера")
                    } footer: {
                        if !report.ok {
                            Text("Исправьте пункты с ✗ на сервере и проверьте снова.")
                        }
                    }
                } else if needsInstall(status) {
                    Section {
                        Text("Нажмите «Подготовить сервер», чтобы установить скрипт.")
                            .foregroundStyle(.secondary)
                    }
                }
            case let .failed(message):
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button("Проверить подключение", systemImage: "network") { model.check() }
                Button("Подготовить сервер", systemImage: "wrench.and.screwdriver") { model.prepare() }
            }
            .disabled(model.isRunning)
        }
        .serverCheckAlerts(model)
    }

    private func needsInstall(_ status: BootstrapStatus) -> Bool {
        switch status {
        case .missing, .outdated: true
        case .ready, .unreachable: false
        }
    }

    private func stepText(_ step: ServerCheckModel.Step) -> String {
        switch step {
        case .connecting: "Подключение…"
        case .checkingScript: "Проверка host-скрипта…"
        case .doctor: "Проверка сервера…"
        case .preparing: "Установка скрипта и настройка…"
        case .sendingToken: "Передача токена…"
        }
    }
}

extension View {
    /// Алерты подключения: «Доверять» для нового ключа сервера, блокирующий алерт смены ключа и
    /// «Сервер не принял ключ» с переходом к публичному ключу. `onTrusted` — после того, как
    /// «Доверять» отработало.
    func serverCheckAlerts(_ model: ServerCheckModel, onTrusted: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(ServerCheckAlerts(model: model, onTrusted: onTrusted))
    }
}

private struct ServerCheckAlerts: ViewModifier {
    let model: ServerCheckModel
    let onTrusted: @MainActor () -> Void

    /// Состояние, алерт которого закрыли без смены состояния («Отмена», «OK»).
    @State private var dismissed: ServerCheckModel.State?
    @State private var showKey = false

    func body(content: Content) -> some View {
        content
            .alert("Доверять ключу сервера?", isPresented: flag(trustFingerprint != nil)) {
                Button("Доверять") {
                    let task = model.trust()
                    Task {
                        await task.value
                        onTrusted()
                    }
                }
                Button("Не доверять", role: .cancel) { model.reject() }
            } message: {
                Text("Сервер подключается впервые. Отпечаток ключа:\n\(trustFingerprint ?? "")\n\nСверьте его с выводом ssh-keygen -lf на сервере.")
            }
            .alert("Ключ сервера изменился", isPresented: dismissible(changedKeys != nil)) {
                Button("Сбросить", role: .destructive) { model.resetHostKey() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Ожидался:\n\(changedKeys?.expected ?? "")\n\nПолучен:\n\(changedKeys?.actual ?? "")\n\nЕсли сервер не переустанавливали, это может быть подмена. Подключиться можно только после сброса.")
            }
            .alert("Сервер не принял ключ", isPresented: dismissible(model.state == .authFailed)) {
                if model.config != nil {
                    Button("Показать публичный ключ") { showKey = true }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Добавьте публичный ключ в ~/.ssh/authorized_keys на сервере.")
            }
            .onChange(of: model.state) { _, state in
                if state != dismissed {
                    dismissed = nil
                }
            }
            .navigationDestination(isPresented: $showKey) {
                if let keyID = model.config?.keyID {
                    KeyDetailView(keyID: keyID)
                }
            }
    }

    private var trustFingerprint: String? {
        if case let .trustPrompt(fingerprint) = model.state { fingerprint } else { nil }
    }

    private var changedKeys: (expected: String, actual: String)? {
        if case let .hostKeyChanged(expected, actual) = model.state { (expected, actual) } else { nil }
    }

    /// Алерт, который закрывается сменой состояния модели: обе кнопки её меняют.
    private func flag(_ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { _ in })
    }

    /// Алерт, который можно закрыть, не меняя состояния; при следующем таком же состоянии он
    /// покажется снова.
    private func dismissible(_ value: Bool) -> Binding<Bool> {
        let state = model.state
        return Binding(
            get: { value && dismissed != state },
            set: { if !$0 { dismissed = state } }
        )
    }
}
