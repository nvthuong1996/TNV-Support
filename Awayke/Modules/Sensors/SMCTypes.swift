//
//  SMCTypes.swift
//  TNV Support
//
//  Wire format and value decoding for the AppleSMC user client. Pure - no
//  IOKit - so the layout and decoders can be checked by Tests/main.swift.
//

/// Mirrors the kernel's `SMCKeyData_t` (80 bytes). Field order, sizes and
/// the explicit padding must match the C struct exactly, because it is
/// passed to IOConnectCallStructMethod as raw bytes.
nonisolated struct SMCParamStruct {
    nonisolated struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    nonisolated struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    nonisolated struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    /// Swift packs the next field into KeyInfo's tail padding; C does not.
    /// This restores C's 12-byte KeyInfo footprint.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

nonisolated enum SMCCommand {
    /// IOConnectCallStructMethod selector for every SMC request.
    static let handleYPCEvent: UInt32 = 2

    // Values for SMCParamStruct.data8.
    static let readBytes: UInt8 = 5
    static let readIndex: UInt8 = 8
    static let readKeyInfo: UInt8 = 9
}

nonisolated enum SMCValue {

    /// "TC0P" -> 0x54433050. Keys and data types are four ASCII characters.
    static func code(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Data types a temperature key can use: signed 8.8 fixed point on Intel
    /// Macs, 32-bit float on Apple Silicon.
    static func isTemperatureType(_ type: String) -> Bool {
        type == "sp78" || type == "flt "
    }

    /// Decodes a raw SMC value. Integer and fixed-point types are big-endian;
    /// `flt ` is the host's native little-endian float. Returns nil for types
    /// this app does not read.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        func bigEndian(_ count: Int) -> UInt32? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        switch type {
        case "ui8 ":
            return bigEndian(1).map { Double($0) }
        case "ui16":
            return bigEndian(2).map { Double($0) }
        case "ui32":
            return bigEndian(4).map { Double($0) }
        case "sp78":
            return bigEndian(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        case "fp88":
            return bigEndian(2).map { Double($0) / 256 }
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        default:
            return nil
        }
    }
}
