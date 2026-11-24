import Foundation
import TmuxPadCore

/// Экран «Новый проект» мастера «Новая сессия» без UI (§3.3): пустая папка (`mkproject`) или
/// клон репозитория (`clone`).
struct NewProjectFlow: Equatable {
    enum Mode: Hashable, CaseIterable {
        case clone
        case empty
    }

    enum NameIssue: Equatable {
        case empty
        /// Вне `[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}`.
        case invalid
        /// Есть в снимке сервера или сервер ответил «уже есть».
        case exists
    }

    enum URLIssue: Equatable {
        case empty
        /// Не проходит `Validation.isValidRepositoryURL`.
        case invalid
    }

    enum CreateOutcome: Equatable {
        /// Имя созданного проекта.
        case created(String)
        /// Код 5: папка с этим именем уже есть, хотя снимок её не знал.
        case exists
        /// `HostError.badRequest` — текст под полями.
        case invalid(String)
        /// Прочее — алерт.
        case failed(String)
    }

    let serverID: UUID
    private(set) var mode: Mode = .clone
    private(set) var url = ""
    private(set) var name = ""
    /// Пользователь правил имя — адрес больше не подставляет его.
    private(set) var nameEdited = false
    /// Текст `badRequest` от сервера; сбрасывается правкой любого поля.
    private(set) var serverIssue: String?
    /// Имена, которые сервер назвал занятыми, хотя снимок их не знает (файл, папка с точкой).
    private var takenNames: Set<String> = []

    init(serverID: UUID) {
        self.serverID = serverID
    }

    mutating func selectMode(_ mode: Mode) {
        if mode != self.mode {
            serverIssue = nil
        }
        self.mode = mode
    }

    /// Пробелы по краям (вставка из буфера) отбрасываются; пока имя не правили, оно берётся из адреса.
    mutating func editURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != url {
            serverIssue = nil
        }
        url = trimmed
        if !nameEdited {
            name = Validation.suggestedProjectName(fromRepositoryURL: trimmed)
        }
    }

    /// Пробел сразу становится `-`, как в имени сессии. Стёртое до пустого имя снова берётся из адреса.
    mutating func editName(_ value: String) {
        let replaced = value.replacingOccurrences(of: " ", with: "-")
        if replaced != name {
            serverIssue = nil
        }
        name = replaced
        nameEdited = !replaced.isEmpty
    }

    func nameIssue(snapshot: ServerSnapshot?) -> NameIssue? {
        if name.isEmpty {
            return .empty
        }
        if !Validation.isValidProjectName(name) {
            return .invalid
        }
        if takenNames.contains(name) || snapshot?.projects.contains(where: { $0.name == name }) == true {
            return .exists
        }
        return nil
    }

    /// Только для клона: у пустой папки адреса нет.
    var urlIssue: URLIssue? {
        guard mode == .clone else {
            return nil
        }
        if url.isEmpty {
            return .empty
        }
        return Validation.isValidRepositoryURL(url) ? nil : .invalid
    }

    func canCreate(snapshot: ServerSnapshot?) -> Bool {
        nameIssue(snapshot: snapshot) == nil && urlIssue == nil && serverIssue == nil
    }

    /// `mkproject` или `clone` через `SessionActions`; успех — дерево уже перечитано. Результат
    /// записывает в состояние `apply`: сам метод не меняет `self`, пока идёт запрос.
    func create(using actions: SessionActions) async -> CreateOutcome {
        do {
            try await actions.createProject(serverID: serverID, name: name, cloneURL: mode == .clone ? url : nil)
            return .created(name)
        } catch HostError.projectExists {
            return .exists
        } catch let HostError.badRequest(message) {
            return .invalid(message.isEmpty ? "Сервер отклонил запрос" : message)
        } catch let HostError.failed(_, stderr) where mode == .clone {
            return .failed(stderr.isEmpty ? "Не удалось клонировать репозиторий" : "Не удалось клонировать репозиторий: \(stderr)")
        } catch SSHError.timeout where mode == .clone {
            // канал закрыт, а git на сервере дорабатывает (§7)
            return .failed("Клон не закончился за 10 минут. Если git на сервере доработает, проект появится в списке")
        } catch SSHError.disconnected where mode == .clone {
            // уход в фон или обрыв сети закрыли канал, клон на сервере идёт дальше (§7)
            return .failed("Связь прервалась до конца клона. Если git на сервере доработает, проект появится в списке")
        } catch {
            return .failed(userText(error))
        }
    }

    /// `request` — копия, с которой шёл `create`: ответ про другое имя, адрес или режим не применяется.
    mutating func apply(_ outcome: CreateOutcome, of request: NewProjectFlow) {
        guard request.mode == mode, request.name == name, request.url == url else {
            return
        }
        switch outcome {
        case .exists:
            takenNames.insert(name)
        case let .invalid(message):
            serverIssue = message
        case .created, .failed:
            break
        }
    }
}
