import SwiftUI

extension View {
    /// Алерт с текстом ошибки; закрытие сбрасывает `message` в `nil`.
    func errorAlert(_ title: String = "Ошибка", message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
