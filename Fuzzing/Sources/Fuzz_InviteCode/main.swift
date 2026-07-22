import Foundation
import WhistleCore

/// Fuzzes the invite-code decode path: an attacker-supplied string arriving via
/// deep link / QR / pasteboard, base64-decoded then JSON-decoded into an
/// `InviteCode`. We only assert it never crashes — a `throw` is the correct
/// outcome for garbage input.
@_cdecl("LLVMFuzzerTestOneInput")
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)
    let input = String(decoding: data, as: UTF8.self)
    _ = try? InviteCode.decode(from: input)
    // Also exercise the URL entry point (whistle://invite/<code> and raw).
    if let url = URL(string: input) {
        _ = try? InviteCode.from(url: url)
    }
    return 0
}
