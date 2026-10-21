import Foundation
import TmuxPadCore

/// Шаги мастера «Новая сессия» без UI (§3.3): сервер → проект → имя → `new`.
struct NewSessionFlow: Equatable {
    enum Step: Hashable {
        case server
        case project
        case name
    }

    enum NameIssue: Equatable {
        case empty
        /// Вне `[A-Za-z0-9_-]{1,64}`.
        case invalid
        /// Есть в снимке сервера или `new` ответил «занято».
        case exists
    }

    enum CreateOutcome: Equatable {
        case created(OpenSessionKey)
        /// Гонка: снимок устарел, сессия с этим именем уже есть.
        case conflict
        /// `HostError.badRequest` — текст под полем.
        case invalid(String)
        /// Прочее — алерт.
        case failed(String)
    }

    /// Шаги, которые мастер показывает, по порядку; последний — всегда `.name`.
    let steps: [Step]
    private(set) var serverID: UUID?
    private(set) var project: String?
    private(set) var name = ""
    /// Пользователь правил поле — выбор проекта больше не подставляет подсказку.
    private(set) var nameEdited = false
    /// Текст `badRequest` от сервера; сбрасывается правкой имени.
    private(set) var serverIssue: String?
    /// Имена, которые `new` назвал занятыми, хотя снимок их ещё не знает.
    private var takenNames: Set<String> = []

    /// `serverID` и `project` — предзаполнение из «Новая сессия здесь»: их шаги пропускаются.
    /// При одном сервере шаг сервера тоже пропускается.
    init(servers: [ServerConfig], serverID: UUID? = nil, project: String? = nil) {
        let presetServer = serverID ?? (servers.count == 1 ? servers.first?.id : nil)
        var steps: [Step] = []
        if presetServer == nil {
            steps.append(.server)
        }
        if presetServer == nil || project == nil {
            steps.append(.project)
        }
        steps.append(.name)
        self.steps = steps
        self.serverID = presetServer
        if presetServer != nil, let project {
            selectProject(project)
        }
    }

    /// Шаг после `step`; `nil` — последний.
    func step(after step: Step) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            return nil
        }
        return steps[index + 1]
    }

    /// Смена сервера сбрасывает проект: у другого сервера свои папки.
    mutating func selectServer(_ id: UUID) {
        if serverID != id {
            project = nil
        }
        serverID = id
    }

    mutating func selectProject(_ name: String) {
        project = name
        if !nameEdited {
            self.name = Validation.suggestedSessionName(from: name)
        }
    }

    /// Ввод в поле имени: пробел сразу становится `-` (§3.3).
    mutating func editName(_ value: String) {
        let replaced = value.replacingOccurrences(of: " ", with: "-")
        if replaced != name {
            serverIssue = nil
        }
        name = replaced
        nameEdited = true
    }

    /// Проверка по снимку сервера выбранного сервера.
    func nameIssue(snapshot: ServerSnapshot?) -> NameIssue? {
        if name.isEmpty {
            return .empty
        }
        if !Validation.isValidSessionName(name) {
            return .invalid
        }
        if takenNames.contains(name) || snapshot?.sessions.contains(where: { $0.name == name }) == true {
            return .exists
        }
        return nil
    }

    func canCreate(snapshot: ServerSnapshot?) -> Bool {
        serverID != nil && project != nil && nameIssue(snapshot: snapshot) == nil && serverIssue == nil
    }

    /// Ключ сессии с текущим именем — для «Подключиться» на экране конфликта.
    var key: OpenSessionKey? {
        serverID.map { OpenSessionKey(serverID: $0, name: name) }
    }

    /// `new` через `SessionActions`; успех — сессия уже открыта и выделена. Результат
    /// записывает в состояние `apply`: сам метод не меняет `self`, пока идёт запрос.
    func create(using actions: SessionActions) async -> CreateOutcome {
        guard let key, let project else {
            return .failed("Выберите сервер и проект")
        }
        do {
            try await actions.create(key, project: project)
            return .created(key)
        } catch HostError.sessionExists {
            return .conflict
        } catch let HostError.badRequest(message) {
            return .invalid(message.isEmpty ? "Сервер отклонил имя" : message)
        } catch {
            return .failed(userText(error))
        }
    }

    mutating func apply(_ outcome: CreateOutcome) {
        switch outcome {
        case .conflict:
            takenNames.insert(name)
        case let .invalid(message):
            serverIssue = message
        case .created, .failed:
            break
        }
    }
}
