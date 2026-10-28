//
//  SensorReader.swift
//  TNV Support
//
//  Samples temperatures and fan speeds off the main thread. The first
//  sample enumerates every SMC key once to find the temperature sensors
//  this Mac has; later samples read only those keys.
//

import Foundation

/// Owns the SMC connection and the discovered keys. Only ever touched from
/// SensorReader's serial queue.
nonisolated final class SensorSampler: @unchecked Sendable {

    nonisolated private struct PolledKey {
        let name: String
        let code: UInt32
        let info: SMCKeyInfo
    }

    nonisolated private struct FanKeys {
        let index: Int
        let actual: PolledKey
        let minimum: PolledKey?
        let maximum: PolledKey?
    }

    private var smc: SMCClient?
    private var openFailed = false
    private var temperatureKeys: [PolledKey]?
    private var fanKeys: [FanKeys] = []

    func sample() -> SensorSnapshot {
        if smc == nil, !openFailed {
            smc = SMCClient()
            openFailed = (smc == nil)
        }
        guard let smc else { return .unavailable }

        if temperatureKeys == nil {
            discover(smc)
        }

        let temperatures = (temperatureKeys ?? []).compactMap { key -> TemperatureReading? in
            guard let celsius = smc.value(forKey: key.code, info: key.info),
                  SensorCatalog.isPlausible(celsius) else { return nil }
            return TemperatureReading(key: key.name, celsius: celsius)
        }

        let fans = fanKeys.compactMap { keys -> FanReading? in
            guard let rpm = smc.value(forKey: keys.actual.code, info: keys.actual.info) else { return nil }
            return FanReading(
                index: keys.index,
                rpm: max(0, rpm),
                minRPM: keys.minimum.flatMap { smc.value(forKey: $0.code, info: $0.info) },
                maxRPM: keys.maximum.flatMap { smc.value(forKey: $0.code, info: $0.info) }
            )
        }

        return SensorSnapshot(isAvailable: true, temperatures: temperatures, fans: fans)
    }

    private func discover(_ smc: SMCClient) {
        let temperatureMarker = UInt32(UInt8(ascii: "T"))
        var found: [PolledKey] = []

        for index in 0..<smc.keyCount() {
            guard let code = smc.key(at: index), code >> 24 == temperatureMarker,
                  let info = smc.keyInfo(code), SMCValue.isTemperatureType(info.type),
                  let celsius = smc.value(forKey: code, info: info),
                  SensorCatalog.isPlausible(celsius) else { continue }
            found.append(PolledKey(name: SMCValue.string(code), code: code, info: info))
        }
        temperatureKeys = found.sorted { $0.name < $1.name }

        // Fanless Macs (MacBook Air) report FNum = 0 or lack the key.
        let fanCount = min(Int(smc.value(forKey: "FNum") ?? 0), 10)
        fanKeys = (0..<fanCount).compactMap { index -> FanKeys? in
            guard let actual = polledKey("F\(index)Ac", smc) else { return nil }
            return FanKeys(index: index,
                           actual: actual,
                           minimum: polledKey("F\(index)Mn", smc),
                           maximum: polledKey("F\(index)Mx", smc))
        }
    }

    private func polledKey(_ name: String, _ smc: SMCClient) -> PolledKey? {
        let code = SMCValue.code(name)
        guard let info = smc.keyInfo(code) else { return nil }
        return PolledKey(name: name, code: code, info: info)
    }
}

final class SensorReader {

    private let queue = DispatchQueue(label: "TNVSupport.sensors", qos: .utility)
    private let sampler = SensorSampler()
    private var isReading = false

    /// Samples on a background queue and calls `completion` on the main
    /// thread. Dropped while a previous sample is still running - the first
    /// one includes key discovery and can take a few seconds.
    func read(completion: @escaping @MainActor (SensorSnapshot) -> Void) {
        guard !isReading else { return }
        isReading = true

        let sampler = self.sampler
        queue.async {
            let snapshot = sampler.sample()
            DispatchQueue.main.async { [weak self] in
                self?.isReading = false
                completion(snapshot)
            }
        }
    }
}
