import Foundation
import TmuxPadCore

/// Шаг онбординга (§3.7). Переходы — чистые функции над `OnboardingContext`, без SwiftUI.
enum OnboardingStep: Hashable {
    /// Создать ключ; тип по умолчанию — SE, если он есть.
    case key(SSHKeyInfo.Kind)
    /// Публичный ключ и команда для сервера.
    case publicKey(UUID)
    /// Новый сервер с этим ключом.
    case server(keyID: UUID)
    /// «Проверить подключение» с вопросом «Доверять».
    case check(serverID: UUID)
    /// «Подготовить сервер»: чеклист и число проектов.
    case prepare(serverID: UUID)
    case done

    /// Первый шаг: ключа в онбординге ещё нет.
    static func first(context: OnboardingContext) -> OnboardingStep {
        resolve(.key(context.defaultKind), context: context)
    }

    /// Шаг после `step`; `nil` — онбординг закончен. Если ключ или сервер онбординга пропал
    /// (удалили), возврат на шаг, где его создают.
    static func next(after step: OnboardingStep, context: OnboardingContext) -> OnboardingStep? {
        let wanted: OnboardingStep
        switch step {
        case .key:
            guard let keyID = context.keyID else {
                return .key(context.defaultKind)
            }
            wanted = .publicKey(keyID)
        case let .publicKey(keyID):
            wanted = .server(keyID: keyID)
        case .server:
            guard let serverID = context.serverID else {
                return resolve(step, context: context)
            }
            wanted = .check(serverID: serverID)
        case let .check(serverID):
            wanted = .prepare(serverID: serverID)
        case .prepare:
            wanted = .done
        case .done:
            return nil
        }
        return resolve(wanted, context: context)
    }

    /// `wanted` или самый ранний шаг, требование которого не выполнено.
    private static func resolve(_ wanted: OnboardingStep, context: OnboardingContext) -> OnboardingStep {
        if case .key = wanted {
            return .key(context.defaultKind)
        }
        guard let keyID = context.keyID else {
            return .key(context.defaultKind)
        }
        switch wanted {
        case .key, .publicKey:
            return .publicKey(keyID)
        case .server:
            return .server(keyID: keyID)
        case .check, .prepare, .done:
            guard let serverID = context.serverID else {
                return .server(keyID: keyID)
            }
            switch wanted {
            case .check: return .check(serverID: serverID)
            case .prepare: return .prepare(serverID: serverID)
            default: return .done
            }
        }
    }
}

/// Что уже есть у онбординга: ключ и сервер, созданные в нём и ещё не удалённые.
struct OnboardingContext: Equatable {
    var secureEnclaveAvailable: Bool
    var keyID: UUID?
    var serverID: UUID?

    var defaultKind: SSHKeyInfo.Kind {
        secureEnclaveAvailable ? .secureEnclaveP256 : .ed25519
    }
}

/// Показывать ли онбординг: флаг `onboarding.done` ставят «Готово» и «Пропустить».
enum OnboardingFlag {
    static let doneKey = "onboarding.done"

    static func shouldShow(defaults: UserDefaults, hasKeys: Bool, hasServers: Bool) -> Bool {
        !defaults.bool(forKey: doneKey) && !hasKeys && !hasServers
    }

    static func markDone(_ defaults: UserDefaults) {
        defaults.set(true, forKey: doneKey)
    }
}
