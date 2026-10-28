//
//  AutoOffPolicy.swift
//  Awayke
//
//  Pure decision logic for battery-based auto-off. No IOKit, no side
//  effects - given the current state it returns the action to take.
//

enum AutoOffAction: Equatable {
    case none
    case suspend
    case resume
}

enum AutoOffPolicy {
    /// - Parameters:
    ///   - intent: the user wants Awayke on.
    ///   - suspended: battery auto-off is currently holding Awayke off.
    ///   - overridden: the user manually turned Awayke on while already
    ///     below the floor, so auto-off stands down for this discharge.
    ///   - percent: current battery charge, 0...100.
    ///   - onAC: running on AC / external power.
    ///   - threshold: 0 disables the feature; otherwise the low-battery floor.
    ///   - hysteresis: extra points above threshold required to resume.
    static func decide(intent: Bool,
                       suspended: Bool,
                       overridden: Bool = false,
                       percent: Int,
                       onAC: Bool,
                       threshold: Int,
                       hysteresis: Int = 5) -> AutoOffAction {
        guard threshold > 0 else { return .none }

        if !suspended, intent, !onAC, !overridden, percent < threshold {
            return .suspend
        }
        if suspended, onAC, percent >= threshold + hysteresis {
            return .resume
        }
        return .none
    }

    /// A manual override lasts only as long as the current discharge.
    /// Reaching AC ends it, so auto-off re-arms for the next one.
    static func shouldKeepOverride(_ overridden: Bool, onAC: Bool) -> Bool {
        overridden && !onAC
    }
}
