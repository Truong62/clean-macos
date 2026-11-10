import SwiftUI

extension Binding where Value: Equatable {
    static func changing(get: @escaping () -> Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { value in
            guard value != get() else { return }
            set(value)
        })
    }
}
