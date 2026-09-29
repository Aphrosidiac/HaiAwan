import SwiftUI
import Combine

/// Drop-in replacement for `@State`.
///
/// In the macOS 27 SDK `@State` is a compiler macro whose plugin ships only inside Xcode.app;
/// Awan builds with the Command Line Tools toolchain, so view-local state uses this wrapper
/// (backed by `@StateObject`, which is still a plain property wrapper). Same semantics:
/// storage survives view updates, `$x` is a Binding, writes re-render the view.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: @autoclosure @escaping () -> Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue()))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let box = box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

extension Local where Value: ExpressibleByNilLiteral {
    init() { self.init(wrappedValue: nil) }
}
