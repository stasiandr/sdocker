import Foundation

func format(bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func format(duration seconds: TimeInterval) -> String {
    if seconds < 1 { return String(format: "%.1fs", seconds) }
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let total = Int(seconds.rounded())
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \(total / 60 % 60)m"
}

func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: .now)
}

extension ISO8601DateFormatter {
    /// Parses RFC 3339 with or without fractional seconds (Docker emits nanoseconds).
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        // Trim nanoseconds to milliseconds, which is all the formatter understands.
        if let dot = string.firstIndex(of: "."),
           let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = string[string.index(after: dot)..<zone].prefix(3)
            if let date = fractional.date(from: string[..<dot] + "." + digits + string[zone...]) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// A message to show for an error, or nil when it only means a task was cancelled
/// (the view that started it went away).
func message(for error: Error) -> String? {
    if error is CancellationError { return nil }
    if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
    return error.localizedDescription
}

/// CPU percentage with enough precision to show near-idle load.
func percent(_ value: Double) -> String {
    value > 0 && value < 1 ? String(format: "%.2f%%", value) : String(format: "%.1f%%", value)
}
