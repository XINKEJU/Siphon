import Foundation

/// Centralised locale-aware formatting. Every user-visible number, date, byte
/// count and relative time goes through this formatter so the selected MDM
/// language drives CLDR output instead of mixing the system locale with the
/// UI language.
public enum LocaleFormatter {
    private static var locale: Locale {
        Locale(identifier: MDMI18n.shared.language)
    }

    public static func string(from number: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    public static func string(from number: Int64) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    public static func string(from number: Double, fractionDigits: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f.string(from: NSNumber(value: number)) ?? String(format: "%.\(fractionDigits)f", number)
    }

    public static func bytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    public static func speed(_ bytesPerSec: Int64) -> String {
        bytes(bytesPerSec) + "/s"
    }

    public static func date(_ date: Date, style: DateFormatter.Style = .medium) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = style
        f.timeStyle = .none
        return f.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    public static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    public static func eta(downloaded: Int64, total: Int64, speed: Int64) -> String {
        guard speed > 0, total > downloaded else { return "—" }
        let seconds = TimeInterval(total - downloaded) / Double(speed)
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return f.string(from: seconds) ?? "—"
    }
}
