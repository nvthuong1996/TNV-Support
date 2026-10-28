//
//  SensorCatalog.swift
//  TNV Support
//
//  Readings and the pure logic that groups raw SMC temperature keys into
//  CPU / GPU / battery. SMC key names are undocumented and differ per Mac,
//  so grouping goes by the well-established key prefixes rather than a
//  per-model table.
//

nonisolated struct TemperatureReading: Equatable, Sendable {
    let key: String
    let celsius: Double
}

nonisolated struct FanReading: Equatable, Sendable {
    /// 0-based SMC fan index.
    let index: Int
    let rpm: Double
    let minRPM: Double?
    let maxRPM: Double?
}

nonisolated struct SensorSnapshot: Equatable, Sendable {
    /// False when the SMC could not be opened at all.
    let isAvailable: Bool
    let temperatures: [TemperatureReading]
    let fans: [FanReading]

    static let unavailable = SensorSnapshot(isAvailable: false, temperatures: [], fans: [])
}

nonisolated enum SensorGroup: CaseIterable, Sendable {
    case cpu
    case gpu
    case battery
    case other

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .other: return "Other"
        }
    }
}

nonisolated struct GroupSummary: Equatable, Sendable {
    let average: Double
    let maximum: Double
    let sensorCount: Int
}

nonisolated enum SensorCatalog {

    /// Readings outside this range are unpopulated or garbage keys.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 5 && celsius < 130
    }

    static func group(forKey key: String, appleSilicon: Bool) -> SensorGroup {
        let prefix = String(key.prefix(2))
        if appleSilicon {
            // Tp: CPU cores (performance, and efficiency on M1),
            // Te: efficiency cores on M2 and later, Tg: GPU.
            switch prefix {
            case "Tp", "Te": return .cpu
            case "Tg": return .gpu
            case "TB": return .battery
            default: return .other
            }
        } else {
            // TC: CPU die / proximity / cores, TG: discrete or integrated GPU.
            switch prefix {
            case "TC": return .cpu
            case "TG": return .gpu
            case "TB": return .battery
            default: return .other
            }
        }
    }

    /// Average and maximum per group, over plausible readings only. Groups
    /// with no readings are absent.
    static func summarize(_ readings: [TemperatureReading],
                          appleSilicon: Bool) -> [SensorGroup: GroupSummary] {
        var values: [SensorGroup: [Double]] = [:]
        for reading in readings where isPlausible(reading.celsius) {
            values[group(forKey: reading.key, appleSilicon: appleSilicon), default: []].append(reading.celsius)
        }
        return values.mapValues { list in
            GroupSummary(average: list.reduce(0, +) / Double(list.count),
                         maximum: list.max() ?? 0,
                         sensorCount: list.count)
        }
    }
}
