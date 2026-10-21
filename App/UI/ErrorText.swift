import Foundation
import TmuxPadCore

/// Текст ошибки для пользователя. У ошибок ядра английские `description`; переводятся здесь,
/// неизвестные показываются как есть.
func userText(_ error: Error) -> String {
    switch error {
    case let error as SSHError:
        switch error {
        case let .connectFailed(message): "Не удалось подключиться: \(message)"
        case .authFailed: "Сервер не принял ключ"
        case let .hostKeyChanged(expected, actual): "Ключ сервера изменился: ожидался \(expected), получен \(actual)"
        case .channelRefused: "Сервер отказал в новом канале"
        case .timeout: "Сервер не ответил вовремя"
        case .disconnected: "Соединение потеряно"
        }
    case let error as HostError:
        switch error {
        case .scriptMissing: "На сервере нет host-скрипта"
        case let .badRequest(message): message.isEmpty ? "Сервер отклонил запрос" : "Сервер отклонил запрос: \(message)"
        case .sessionExists: "Сессия с таким именем уже есть"
        case .noSession: "Сессии больше нет"
        case .projectsRootMissing: "Папки проектов нет на сервере"
        case let .failed(code, stderr):
            stderr.isEmpty ? "Команда завершилась с кодом \(code)" : "Команда завершилась с кодом \(code): \(stderr)"
        case let .badOutput(message): "Неожиданный ответ сервера: \(message)"
        }
    case let error as KeyError:
        switch error {
        case let .invalidKey(message): "Не удалось прочитать ключ: \(message)"
        }
    case let error as KeyStoreError:
        switch error {
        case .secureEnclaveUnavailable: "Secure Enclave недоступен на этом устройстве"
        case .unsupportedKind: "Ключ этого типа так сохранить нельзя"
        case .notFound: "Приватной части ключа нет в Keychain"
        }
    case let error as KeyLibraryError:
        switch error {
        case let .inUse(labels): "Ключ используется: \(labels.joined(separator: ", "))"
        }
    case let error as AppError:
        switch error {
        case .keyMissing: "Ключа сервера нет на устройстве — выберите другой в настройках сервера"
        case .serverMissing: "Сервер удалён"
        }
    case let error as KeychainError:
        switch error {
        case let .status(status): "Ошибка Keychain (код \(status))"
        case .unexpectedData: "В Keychain неожиданные данные"
        }
    default:
        String(describing: error)
    }
}

/// Перевод строк `ServerConfig.validationIssues()`; незнакомая строка остаётся как есть.
func serverIssueText(_ issue: String) -> String {
    switch issue {
    case "host is empty": "Укажите адрес"
    case "port must be 1...65535": "Порт — от 1 до 65535"
    case "user must be non-empty without spaces": "Укажите пользователя без пробелов"
    case "projects root must be non-empty without quotes or control characters":
        "Папка проектов не должна быть пустой и содержать кавычки ' или управляющие символы"
    case "start command must be non-empty without quotes or control characters":
        "Команда запуска не должна быть пустой и содержать кавычки ' или управляющие символы"
    case "keepalive must be 5...300 seconds": "Keepalive — от 5 до 300 секунд"
    default: issue
    }
}
