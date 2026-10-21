import SwiftUI

@main
struct TmuxPadApp: App {
    private enum Startup {
        case ready(AppEnvironment)
        case failed(String)
        /// Хост `AppTests`: пустой корень, тесты строят свои окружения.
        case testHost
    }

    private let startup: Startup

    init() {
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil {
            startup = .testHost
            return
        }
        do {
            let env = process.arguments.contains("-uitest-inmemory") ? try AppEnvironment.inMemory() : try AppEnvironment.live()
            startup = .ready(env)
        } catch {
            startup = .failed(userText(error))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .ready(env):
                RootView().appEnvironment(env)
            case let .failed(message):
                StartupErrorView(message: message)
            case .testHost:
                Color.clear
            }
        }
    }
}
