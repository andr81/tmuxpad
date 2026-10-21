import Foundation
import Observation
import TmuxPadCore

/// «Проверить подключение», «Подготовить сервер» и «Передать токен Claude» для одного
/// сохранённого сервера; по экземпляру на открытый экран. Конфиг каждый раз берётся из
/// `ServerStore`, соединение — из пула.
///
/// Действия синхронно меняют `state` и возвращают задачу: алерт, который закрыла кнопка, не
/// всплывает снова, пока задача ещё не началась. Тесты ждут `value` задачи.
@MainActor
@Observable
final class ServerCheckModel {
    enum Step: Equatable {
        case connecting
        case checkingScript
        case doctor
        case preparing
        case sendingToken
        case rejecting
    }

    enum State: Equatable {
        case idle
        case running(Step)
        /// Ключ сервера увиден впервые: подключение есть, дальше — только после `trust()`.
        case trustPrompt(fingerprint: String)
        /// Подключение заблокировано до `resetHostKey()`.
        case hostKeyChanged(expected: String, actual: String)
        case authFailed
        case done(BootstrapStatus, DoctorReport?)
        case failed(String)
    }

    /// Что делать после «Доверять».
    private enum Pending {
        case check
        case prepare
        /// Токен в модели не хранится: экран передаёт его заново.
        case none
    }

    let serverID: UUID
    private(set) var state: State = .idle
    /// Последний `sendToken` дошёл до сервера.
    private(set) var tokenSent = false

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var connection: ServerConnection?
    @ObservationIgnored private var pending: Pending = .none
    @ObservationIgnored private var task: Task<Void, Never>?

    init(serverID: UUID, environment: AppEnvironment) {
        self.serverID = serverID
        env = environment
    }

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    var config: ServerConfig? {
        env.servers.server(id: serverID)
    }

    // MARK: - Действия

    /// Подключение, статус host-скрипта и, если он актуален, `doctor`.
    @discardableResult
    func check() -> Task<Void, Never> {
        start(.connecting) { model in
            guard let connection = await model.connectTrusted(then: .check) else {
                return
            }
            await model.inspect(connection)
        }
    }

    /// Установка или обновление скрипта и `setup`.
    @discardableResult
    func prepare() -> Task<Void, Never> {
        start(.connecting) { model in
            guard let connection = await model.connectTrusted(then: .prepare) else {
                return
            }
            await model.install(connection)
        }
    }

    /// Запоминает отпечаток в конфиге сервера и продолжает прерванное действие.
    @discardableResult
    func trust() -> Task<Void, Never> {
        guard case let .trustPrompt(fingerprint) = state else {
            return Task {}
        }
        let next = pending
        return start(.checkingScript) { model in
            guard model.store(fingerprint: fingerprint), let connection = model.connection else {
                return
            }
            switch next {
            case .check: await model.inspect(connection)
            case .prepare: await model.install(connection)
            case .none: model.state = .idle
            }
        }
    }

    /// «Не доверять»: соединение рвётся, отпечаток, который ядро уже сохранило, забывается.
    /// Новое действие начнётся только после сброса: иначе оно подключилось бы по старому
    /// отпечатку.
    @discardableResult
    func reject() -> Task<Void, Never> {
        guard case .trustPrompt = state else {
            return Task {}
        }
        pending = .none
        return start(.rejecting) { model in
            await model.connection?.disconnect()
            do {
                if let config = model.config {
                    try await model.env.hostKeys.reset(host: config.host, port: config.port)
                }
                model.state = .idle
            } catch {
                model.fail(error)
            }
        }
    }

    /// «Сбросить» после смены ключа сервера: доверие забывается и проверка идёт заново, с
    /// вопросом «Доверять».
    @discardableResult
    func resetHostKey() -> Task<Void, Never> {
        start(.connecting) { model in
            guard model.config != nil else {
                model.state = .failed("Сервер удалён")
                return
            }
            do {
                try await model.env.servers.resetFingerprint(id: model.serverID)
            } catch {
                model.fail(error)
                return
            }
            guard let connection = await model.connectTrusted(then: .check) else {
                return
            }
            await model.inspect(connection)
        }
    }

    /// Токен уходит только в stdin `auth`; ни в журнал, ни в состояние модели он не попадает.
    @discardableResult
    func sendToken(_ token: String) -> Task<Void, Never> {
        tokenSent = false
        return start(.connecting) { model in
            guard let connection = await model.connectTrusted(then: .none) else {
                return
            }
            model.state = .running(.sendingToken)
            do {
                try await connection.api.auth(token: token)
                model.tokenSent = true
                model.state = .idle
            } catch {
                model.fail(error)
            }
        }
    }

    // MARK: - Шаги

    /// Одно действие за раз: пока идёт прошлое, новое не начинается.
    private func start(_ step: Step, _ body: @escaping @MainActor (ServerCheckModel) async -> Void) -> Task<Void, Never> {
        if isRunning, let task {
            return task
        }
        state = .running(step)
        let task = Task { [self] in
            await body(self)
        }
        self.task = task
        return task
    }

    /// Подключённое соединение с доверенным ключом. `nil` — `state` уже объясняет почему: вопрос
    /// «Доверять» (тогда после `trust()` выполнится `next`) или ошибка.
    ///
    /// Вопрос задаётся всякий раз, когда отпечаток не совпадает с подтверждённым в конфиге, а не
    /// только при `hostKeyFirstSeen`: ядро сохраняет ключ в `HostKeyStore` до ответа, и вопрос,
    /// оставленный без ответа (приложение закрыли, соединение переподключилось, поле сбросили
    /// при живом соединении), иначе считался бы согласием.
    private func connectTrusted(then next: Pending) async -> ServerConnection? {
        guard let config else {
            state = .failed("Сервер удалён")
            return nil
        }
        state = .running(.connecting)
        let connection: ServerConnection
        do {
            let auth = try await env.auth(for: config)
            connection = await env.pool.connection(for: config, auth: auth)
            self.connection = connection
            try await connection.connect()
        } catch {
            fail(error)
            return nil
        }
        guard let fingerprint = await connection.hostKeyFingerprint, config.hostKeyFingerprint != fingerprint else {
            return connection
        }
        // копия сервера: этот ключ уже подтверждён для того же адреса, конфиг догоняет без
        // вопроса, иначе `TreeRefresher` не опрашивал бы копию
        if env.servers.isConfirmedElsewhere(fingerprint, for: config) {
            return store(fingerprint: fingerprint) ? connection : nil
        }
        pending = next
        state = .trustPrompt(fingerprint: fingerprint)
        return nil
    }

    private func store(fingerprint: String) -> Bool {
        guard var config else {
            state = .failed("Сервер удалён")
            return false
        }
        config.hostKeyFingerprint = fingerprint
        do {
            try env.servers.update(config)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func inspect(_ connection: ServerConnection) async {
        state = .running(.checkingScript)
        let api = await connection.api
        let status = await env.bootstrap.status(api: api)
        guard case .ready = status else {
            state = .done(status, nil)
            return
        }
        state = .running(.doctor)
        do {
            state = .done(status, try await api.doctor())
        } catch {
            fail(error)
        }
    }

    private func install(_ connection: ServerConnection) async {
        state = .running(.preparing)
        do {
            let report = try await env.bootstrap.prepare(api: await connection.api)
            state = .done(.ready(version: env.bootstrap.bundledVersion), report)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        switch error as? SSHError {
        case .authFailed:
            state = .authFailed
        case let .hostKeyChanged(expected, actual):
            state = .hostKeyChanged(expected: expected, actual: actual)
        default:
            state = .failed(userText(error))
        }
    }
}
