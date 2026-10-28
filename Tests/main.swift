import Foundation

var failures = 0

func check(_ actual: AutoOffAction, _ expected: AutoOffAction, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// threshold 0 disables the feature entirely
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: false, threshold: 0),
      .none, "threshold 0 disables")

// suspend just below threshold, on battery
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 19, onAC: false, threshold: 20),
      .suspend, "suspend below threshold on battery")

// no suspend exactly at threshold (strict less-than)
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 20, onAC: false, threshold: 20),
      .none, "no suspend at exactly threshold")

// never suspend on AC
check(AutoOffPolicy.decide(intent: true, suspended: false, percent: 5, onAC: true, threshold: 20),
      .none, "no suspend on AC")

// never suspend when the user hasn't turned Awayke on
check(AutoOffPolicy.decide(intent: false, suspended: false, percent: 5, onAC: false, threshold: 20),
      .none, "no suspend when intent off")

// resume at threshold + hysteresis, on AC
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 25, onAC: true, threshold: 20),
      .resume, "resume at threshold+hysteresis on AC")

// no resume below hysteresis band
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 24, onAC: true, threshold: 20),
      .none, "no resume below hysteresis")

// resume requires AC even when charge is high
check(AutoOffPolicy.decide(intent: true, suspended: true, percent: 30, onAC: false, threshold: 20),
      .none, "no resume on battery")

// a manual override suppresses suspend for the rest of the discharge
check(AutoOffPolicy.decide(intent: true, suspended: false, overridden: true, percent: 5, onAC: false, threshold: 20),
      .none, "override suppresses suspend")

// the override does not block a later resume once back on AC
check(AutoOffPolicy.decide(intent: true, suspended: true, overridden: true, percent: 25, onAC: true, threshold: 20),
      .resume, "override does not block resume")

func checkBool(_ actual: Bool, _ expected: Bool, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// the override survives while still discharging
checkBool(AutoOffPolicy.shouldKeepOverride(true, onAC: false), true, "override survives on battery")

// reaching AC ends the override, re-arming auto-off for the next discharge
checkBool(AutoOffPolicy.shouldKeepOverride(true, onAC: true), false, "override ends on AC")

// nothing to keep when there was no override
checkBool(AutoOffPolicy.shouldKeepOverride(false, onAC: false), false, "no override stays no override")

// A lid session started while open waits for a close, then expires on open.
let openStart = LidSessionTracker()
openStart.start(lidClosed: false)
checkBool(openStart.isWaitingForClose, true, "open-start lid session waits for close")
checkBool(openStart.handle(lidClosed: false), false, "open state does not immediately expire")
checkBool(openStart.handle(lidClosed: true), false, "lid close arms session end")
checkBool(openStart.isWaitingForClose, false, "closed session now waits for open")
checkBool(openStart.handle(lidClosed: false), true, "lid reopen expires session")
checkBool(openStart.handle(lidClosed: false), false, "lid session expires only once")

// Starting while already closed (for example through an external display)
// should expire on the next open without requiring another close first.
let closedStart = LidSessionTracker()
closedStart.start(lidClosed: true)
checkBool(closedStart.handle(lidClosed: false), true, "closed-start session expires on open")

let cancelled = LidSessionTracker()
cancelled.start(lidClosed: false)
cancelled.cancel()
checkBool(cancelled.handle(lidClosed: true), false, "cancelled lid session ignores close")
checkBool(cancelled.handle(lidClosed: false), false, "cancelled lid session ignores open")

// If IOKit has not produced its initial reading yet, conservatively wait for
// a complete close/open cycle rather than treating the current state as closed.
let unknownStart = LidSessionTracker()
unknownStart.start(lidClosed: nil)
checkBool(unknownStart.isWaitingForClose, true, "unknown-start session waits for close")
checkBool(unknownStart.handle(lidClosed: true), false, "unknown-start close arms session end")
checkBool(unknownStart.handle(lidClosed: false), true, "unknown-start reopen expires session")

// MARK: - Sensors

func checkValue<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name): got \(actual), expected \(expected)")
    }
}

// The struct is handed to the kernel as raw bytes, so it must match the C
// SMCKeyData_t layout exactly.
checkValue(MemoryLayout<SMCParamStruct>.size, 80, "SMC struct is 80 bytes")
checkValue(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28, "SMC keyInfo offset")
checkValue(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40, "SMC result offset")
checkValue(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42, "SMC data8 offset")
checkValue(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44, "SMC data32 offset")
checkValue(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48, "SMC bytes offset")

checkValue(SMCValue.code("TC0P"), 0x5443_3050, "four-char code encodes")
checkValue(SMCValue.string(0x5443_3050), "TC0P", "four-char code decodes")

checkValue(SMCValue.decode([0x2F, 0x80], type: "sp78"), 47.5, "sp78 decodes")
checkValue(SMCValue.decode([0xFF, 0x00], type: "sp78"), -1.0, "sp78 is signed")
checkValue(SMCValue.decode([0x1C, 0x20], type: "fpe2"), 1800.0, "fpe2 decodes")
checkValue(SMCValue.decode([0x03], type: "ui8 "), 3.0, "ui8 decodes")
checkValue(SMCValue.decode([0x00, 0x00, 0x05, 0xDC], type: "ui32"), 1500.0, "ui32 is big-endian")
let floatBits = Float(1850.5).bitPattern
let floatBytes = (0..<4).map { UInt8((floatBits >> ($0 * 8)) & 0xFF) }
checkValue(SMCValue.decode(floatBytes, type: "flt "), 1850.5, "flt is little-endian")
checkValue(SMCValue.decode([0x2F], type: "sp78"), nil, "short value is rejected")
checkValue(SMCValue.decode([0x01, 0x02], type: "{fds"), nil, "unknown type is rejected")

checkValue(SensorCatalog.group(forKey: "Tp01", appleSilicon: true), .cpu, "Apple Silicon Tp is CPU")
checkValue(SensorCatalog.group(forKey: "Te05", appleSilicon: true), .cpu, "Apple Silicon Te is CPU")
checkValue(SensorCatalog.group(forKey: "Tg0f", appleSilicon: true), .gpu, "Apple Silicon Tg is GPU")
checkValue(SensorCatalog.group(forKey: "TB1T", appleSilicon: true), .battery, "TB is battery")
checkValue(SensorCatalog.group(forKey: "Ts0P", appleSilicon: true), .other, "unknown prefix is other")
checkValue(SensorCatalog.group(forKey: "TC0P", appleSilicon: false), .cpu, "Intel TC is CPU")
checkValue(SensorCatalog.group(forKey: "TG0D", appleSilicon: false), .gpu, "Intel TG is GPU")
// On Intel, Tp0P is the power supply, not the CPU.
checkValue(SensorCatalog.group(forKey: "Tp0P", appleSilicon: false), .other, "Intel Tp is not CPU")

let summaries = SensorCatalog.summarize([
    TemperatureReading(key: "Tp01", celsius: 50),
    TemperatureReading(key: "Tp05", celsius: 60),
    TemperatureReading(key: "Tp09", celsius: 0),
    TemperatureReading(key: "Tp0D", celsius: 200),
    TemperatureReading(key: "Tg0f", celsius: 40),
], appleSilicon: true)
checkValue(summaries[.cpu], GroupSummary(average: 55, maximum: 60, sensorCount: 2),
           "CPU summary skips implausible readings")
checkValue(summaries[.gpu], GroupSummary(average: 40, maximum: 40, sensorCount: 1), "GPU summary")
checkValue(summaries[.battery], nil, "missing group is absent")

if failures > 0 {
    print("\(failures) failing")
    exit(1)
} else {
    print("all passing")
    exit(0)
}
