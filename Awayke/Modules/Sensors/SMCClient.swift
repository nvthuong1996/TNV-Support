//
//  SMCClient.swift
//  TNV Support
//
//  Read-only connection to the AppleSMC kernel user client, the source of
//  temperature and fan readings on both Intel and Apple Silicon Macs.
//  Reading needs no privileges outside the App Sandbox. Calls block, so use
//  this from a background queue only.
//

import Foundation
import IOKit

nonisolated struct SMCKeyInfo {
    let size: UInt32
    let type: String
}

nonisolated final class SMCClient {

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// Number of keys the SMC exposes, for enumeration with `key(at:)`.
    func keyCount() -> UInt32 {
        guard let value = value(forKey: "#KEY") else { return 0 }
        return UInt32(value)
    }

    func key(at index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = SMCCommand.readIndex
        input.data32 = index
        return call(input)?.key
    }

    func keyInfo(_ code: UInt32) -> SMCKeyInfo? {
        var input = SMCParamStruct()
        input.key = code
        input.data8 = SMCCommand.readKeyInfo
        guard let output = call(input) else { return nil }
        return SMCKeyInfo(size: output.keyInfo.dataSize, type: SMCValue.string(output.keyInfo.dataType))
    }

    func value(forKey code: UInt32, info: SMCKeyInfo) -> Double? {
        guard let bytes = readBytes(code, size: info.size) else { return nil }
        return SMCValue.decode(bytes, type: info.type)
    }

    /// Convenience for one-off reads. Prefer caching `keyInfo` for keys that
    /// are polled.
    func value(forKey key: String) -> Double? {
        let code = SMCValue.code(key)
        guard let info = keyInfo(code) else { return nil }
        return value(forKey: code, info: info)
    }

    private func readBytes(_ code: UInt32, size: UInt32) -> [UInt8]? {
        guard size > 0, size <= 32 else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = size
        input.data8 = SMCCommand.readBytes
        guard let output = call(input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            SMCCommand.handleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        // `result` is the SMC's own status; non-zero means e.g. key not found.
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }
}
