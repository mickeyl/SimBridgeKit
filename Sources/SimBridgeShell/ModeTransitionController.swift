import Foundation

/// Single source of truth for the selected provider mode.
///
/// The UI binds to `mode` so the picker reflects the user's choice immediately,
/// rather than inferring it from the live — and, mid-transition, briefly
/// inconsistent — state of the server. Without this, a slow transition would
/// make the segmented control snap back to the previous mode until the next
/// status update caught up.
///
/// Transitions are serialized: while one is in flight, only the most recent
/// requested mode is remembered and applied once the current transition
/// finishes, so rapid clicks converge on the last choice instead of racing.
///
/// Mutations happen on the main thread (the SwiftUI caller and the transition
/// completion handlers all hop to main).
public final class ModeTransitionController<Mode: Equatable>: ObservableObject {
    @Published public private(set) var mode: Mode
    @Published public private(set) var isSwitching = false

    private let persist: ((Mode) -> Void)?
    private let transition: (Mode, @escaping () -> Void) -> Void
    private var queuedMode: Mode?

    /// - Parameters:
    ///   - initial: the restored mode; its transition is applied immediately.
    ///   - persist: called on every user selection (not on the initial apply).
    ///   - transition: performs the actual switch and must call the completion
    ///     exactly once, on the main thread.
    public init(
        initial: Mode,
        persist: ((Mode) -> Void)? = nil,
        transition: @escaping (Mode, @escaping () -> Void) -> Void
    ) {
        self.mode = initial
        self.persist = persist
        self.transition = transition
        applyTransition(to: initial)
    }

    public func select(_ newMode: Mode) {
        mode = newMode
        persist?(newMode)
        applyTransition(to: newMode)
    }

    private func applyTransition(to target: Mode) {
        guard !isSwitching else {
            queuedMode = target
            return
        }

        isSwitching = true
        transition(target) { [weak self] in
            guard let self else { return }
            self.isSwitching = false
            if let queued = self.queuedMode, queued != target {
                self.queuedMode = nil
                self.applyTransition(to: queued)
            } else {
                self.queuedMode = nil
            }
        }
    }
}
