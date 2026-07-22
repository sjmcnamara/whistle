import Foundation

// No `import WhistleCore`: compiled in-module with the WhistleCore sources.

/// Fuzzes `JoinRequest.from(jsonString:)` — the decode applied to a join-request
/// rumor after unwrapping its NIP-59 gift wrap. An attacker can craft the
/// gift-wrapped rumor an admin's device decodes, so this is untrusted input on
/// the admission path. Must never crash.
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    let json = String(decoding: data, as: UTF8.self)
    _ = try? JoinRequest.from(jsonString: json)
    return 0
}
