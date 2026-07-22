import Foundation
import WhistleCore

/// Fuzzes `ChatPayload.from(jsonString:)` — the inner-payload decode for chat
/// messages carried in kind-445 MLS events. Untrusted post-decrypt input from
/// any group member. Must never crash.
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    let json = String(decoding: data, as: UTF8.self)
    _ = try? ChatPayload.from(jsonString: json)
    return 0
}
