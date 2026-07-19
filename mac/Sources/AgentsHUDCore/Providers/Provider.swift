import Foundation

/// A pluggable source of agent sessions (providers/types.ts). Claude is the
/// first implementation; other CLIs (Codex, Gemini) can implement the same
/// interface so the rest of the stack is unchanged.
public protocol Provider: Sendable {
    var name: String { get }
    /// Read the current sessions and usage events from disk in a single pass.
    func collect() async -> ProviderSnapshot
    /// Watch the underlying data for changes. The callback receives the changed
    /// session id (when known). Returns a disposer.
    func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void
}
