//
//  LidSessionTracker.swift
//  Awayke
//
//  Small state machine for an "until the lid is reopened" session. Starting
//  while the lid is open must not expire immediately; it first waits for a
//  close, then expires on the following open.
//

final class LidSessionTracker {
    private enum State {
        case inactive
        case waitingForClose
        case waitingForOpen
    }

    private var state = State.inactive

    var isActive: Bool {
        if case .inactive = state { return false }
        return true
    }

    var isWaitingForClose: Bool {
        if case .waitingForClose = state { return true }
        return false
    }

    func start(lidClosed: Bool?) {
        state = (lidClosed == true) ? .waitingForOpen : .waitingForClose
    }

    func cancel() {
        state = .inactive
    }

    /// Returns true exactly once: when a started session observes the lid
    /// reopen after it has been closed.
    func handle(lidClosed: Bool) -> Bool {
        switch (state, lidClosed) {
        case (.waitingForClose, true):
            state = .waitingForOpen
        case (.waitingForOpen, false):
            state = .inactive
            return true
        default:
            break
        }
        return false
    }
}
