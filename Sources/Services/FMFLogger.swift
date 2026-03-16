import os.log

/// Centralised os.Logger channels for Famstr.
enum FMFLogger {
    private static let subsystem = "org.findmyfam"

    static let identity = Logger(subsystem: subsystem, category: "identity")
    static let relay    = Logger(subsystem: subsystem, category: "relay")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let mls      = Logger(subsystem: subsystem, category: "mls")
    static let group    = Logger(subsystem: subsystem, category: "group")
    static let marmot   = Logger(subsystem: subsystem, category: "marmot")
}
