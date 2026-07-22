import Foundation

// No `import WhistleCore`: compiled in-module with the WhistleCore sources.

/// Fuzzes `LocationPayload.from(jsonString:)` — the decode applied to the inner
/// payload of a kind-445 MLS message after decryption. A malicious but
/// authenticated group member can put arbitrary bytes here, so this parser sees
/// untrusted input despite the encrypted transport. Must never crash.
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    let json = String(decoding: data, as: UTF8.self)
    _ = try? LocationPayload.from(jsonString: json)
    return 0
}
