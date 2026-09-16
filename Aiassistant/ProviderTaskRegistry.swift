import Foundation

@MainActor
final class ProviderTaskRegistry<Value> {
    private var tasks: [UUID: Task<Value, Error>] = [:]
    var isEmpty: Bool { tasks.isEmpty }

    func run(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await operation() }
        tasks[id] = task
        defer { tasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAll() {
        let runningTasks = tasks.values
        tasks.removeAll()
        for task in runningTasks { task.cancel() }
    }
}
