import Foundation

// MARK: - Localization

/// The UI is English by default and switches to Russian only when the user's
/// preferred system language is Russian. The binary is unbundled — there is no
/// `.lproj` for `NSLocalizedString` to read — so the strings live in code and
/// `Locale.preferredLanguages` is the signal.
///
/// The language is resolved once at launch: macOS restarts apps on a language
/// change anyway, and re-reading it on every menu rebuild would buy nothing.
enum L10n {
    static let isRussian: Bool = {
        guard let preferred = Locale.preferredLanguages.first else { return false }
        return Locale(identifier: preferred).language.languageCode?.identifier == "ru"
    }()

    private static func pick(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

    // Status bar item
    static let driveMissingAccessibility = pick("SSD not found", "SSD не найден")
    static let noDriveTitle = pick(" no drive", " нет диска")

    // Errors
    static let smartctlMissing = pick(
        "smartctl not found. Install it with: brew install smartmontools",
        "smartctl не найден. Установите: brew install smartmontools")
    static let driveNotDetected = pick("No Samsung SSD detected", "Samsung SSD не обнаружен")

    // Menu commands
    static let refreshInterval = pick("Refresh interval", "Интервал обновления")
    static let refreshNow = pick("Refresh now", "Обновить сейчас")
    static let quit = pick("Quit", "Выход")

    static let intervalTitles = isRussian
        ? ["10 секунд", "30 секунд", "1 минута", "2 минуты", "5 минут"]
        : ["10 seconds", "30 seconds", "1 minute", "2 minutes", "5 minutes"]

    // Timestamps
    static func lastSeen(_ time: String) -> String {
        pick("Last seen: \(time)", "Последний раз виден: \(time)")
    }

    static func updated(_ time: String) -> String {
        pick("Updated: \(time)", "Обновлено: \(time)")
    }

    static func hours(_ hours: Int, days: Int) -> String {
        pick("\(hours) h (\(days) d)", "\(hours) ч (\(days) дн.)")
    }

    static let unknownValue = "—"

    // Health
    static func healthPassed(_ wear: String) -> String { pick("OK, wear \(wear)", "OK, износ \(wear)") }
    static func healthFailed(_ wear: String) -> String { pick("WARNING, wear \(wear)", "ВНИМАНИЕ, износ \(wear)") }
    static func healthUnknown(_ wear: String) -> String { pick("wear \(wear)", "износ \(wear)") }
    static func health(_ line: String) -> String { pick("Health: \(line)", "Здоровье: \(line)") }

    // Metrics
    static func temperature(_ value: String, warning: Int, critical: Int, sensors: String) -> String {
        pick("Temperature: \(value) (thresholds \(warning)/\(critical)°C, sensors: \(sensors))",
             "Температура: \(value) (пороги \(warning)/\(critical)°C, датчики: \(sensors))")
    }

    static func spare(_ value: String, threshold: String) -> String {
        pick("Spare: \(value) (threshold \(threshold))",
             "Резерв (spare): \(value) (порог \(threshold))")
    }

    static func written(_ value: String) -> String { pick("Written: \(value)", "Записано: \(value)") }
    static func read(_ value: String) -> String { pick("Read: \(value)", "Прочитано: \(value)") }
    static func powerOnTime(_ value: String) -> String { pick("Power-on time: \(value)", "Наработка: \(value)") }
    static func powerCycles(_ value: String) -> String { pick("Power cycles: \(value)", "Циклы включения: \(value)") }
    static func unsafeShutdowns(_ value: String) -> String {
        pick("Unsafe shutdowns: \(value)", "Небезопасных выключений: \(value)")
    }

    static func errors(media: String, log: String) -> String {
        pick("Media errors: \(media)   Error log entries: \(log)",
             "Ошибок носителя: \(media)   Записей в логе ошибок: \(log)")
    }

    static let noCriticalWarning = pick("none", "нет")

    static func criticalWarning(_ value: String) -> String {
        pick("Critical warning: \(value)", "Критическое предупреждение: \(value)")
    }
}
