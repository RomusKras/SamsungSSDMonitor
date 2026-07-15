import AppKit
import Foundation

// MARK: - smartctl JSON models

struct ScanOutput: Decodable {
    let devices: [ScanDevice]?
}

struct ScanDevice: Decodable {
    let name: String
    let type: String?
}

struct SmartctlReport: Decodable {
    let modelName: String?
    let serialNumber: String?
    let firmwareVersion: String?
    let temperature: TemperatureInfo?
    let smartStatus: SmartStatus?
    let nvmeSmartHealthInformationLog: HealthLog?
    let nvmeCompositeTemperatureThreshold: TempThreshold?
}

struct TemperatureInfo: Decodable { let current: Int? }
struct TempThreshold: Decodable { let warning: Int?; let critical: Int? }
struct SmartStatus: Decodable { let passed: Bool? }

struct HealthLog: Decodable {
    let criticalWarning: Int?
    let temperature: Int?
    let availableSpare: Int?
    let availableSpareThreshold: Int?
    let percentageUsed: Int?
    let dataUnitsRead: Int64?
    let dataUnitsWritten: Int64?
    let powerCycles: Int?
    let powerOnHours: Int?
    let unsafeShutdowns: Int?
    let mediaErrors: Int?
    let numErrLogEntries: Int?
    let temperatureSensors: [Int]?
}

// MARK: - smartctl runner

enum Smartctl {
    static let candidatePaths = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"]

    static var binaryPath: String? = {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs smartctl with a hard watchdog timeout so a wedged process (e.g. the
    /// enclosure vanishing mid I/O) can never hang a refresh cycle forever.
    static func run(_ args: [String], timeout: TimeInterval = 5) -> Data? {
        guard let bin = binaryPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return data.isEmpty ? nil : data
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Scans all attached NVMe controllers and returns the first one whose
    /// model name looks like a Samsung drive, re-detecting the IOService
    /// path fresh every call so unplug/replug and enclosure changes are
    /// picked up automatically.
    static func findSamsungReport() -> SmartctlReport? {
        guard let scanData = run(["--scan-open", "-j"]),
              let scan = try? decoder.decode(ScanOutput.self, from: scanData),
              let devices = scan.devices else { return nil }

        for device in devices where device.type == "nvme" {
            guard let reportData = run(["-a", "-j", device.name, "-d", "nvme"]),
                  let report = try? decoder.decode(SmartctlReport.self, from: reportData) else { continue }
            if let model = report.modelName?.lowercased(), model.contains("samsung") {
                return report
            }
        }
        return nil
    }
}

// MARK: - Formatting helpers

func formatTB(dataUnits: Int64?) -> String {
    guard let units = dataUnits else { return "—" }
    let bytes = Double(units) * 512_000.0
    return String(format: "%.2f TB", bytes / 1_000_000_000_000.0)
}

func formatHours(_ hours: Int?) -> String {
    guard let hours else { return "—" }
    let days = hours / 24
    return "\(hours) ч (\(days) дн.)"
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let intervalOptions: [(title: String, seconds: TimeInterval)] = [
        ("10 секунд", 10),
        ("30 секунд", 30),
        ("1 минута", 60),
        ("2 минуты", 120),
        ("5 минут", 300)
    ]

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isRefreshing = false
    private var lastSeenAt: Date?
    private var refreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.refreshIntervalDefaultsKey)
            return stored > 0 ? stored : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.refreshIntervalDefaultsKey)
            restartTimer()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "SSD")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " …"

        if Smartctl.binaryPath == nil {
            showError("smartctl не найден. Установите: brew install smartmontools")
        }

        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func intervalSubmenuItem() -> NSMenuItem {
        let current = refreshInterval
        let submenu = NSMenu()
        for option in Self.intervalOptions {
            let item = NSMenuItem(title: option.title, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            item.state = (option.seconds == current) ? .on : .off
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Интервал обновления", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        refreshInterval = seconds
        refresh()
    }

    private func showError(_ message: String) {
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.trianglebadge.exclamationmark", accessibilityDescription: "SSD не найден")
        let attributed = NSAttributedString(string: " нет диска", attributes: [.foregroundColor: NSColor.systemRed])
        statusItem.button?.attributedTitle = attributed

        let menu = NSMenu()
        menu.addItem(disabledItem(message))
        if let lastSeenAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            menu.addItem(disabledItem("Последний раз виден: \(formatter.string(from: lastSeenAt))"))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(intervalSubmenuItem())
        menu.addItem(NSMenuItem(title: "Обновить сейчас", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = $0.target ?? self }
        statusItem.menu = menu
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func refresh() {
        // If a previous cycle is still running (e.g. smartctl stuck on a dying
        // device until the watchdog kills it), skip this tick instead of piling
        // up another concurrent smartctl invocation.
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = Smartctl.findSamsungReport()
            DispatchQueue.main.async {
                self?.isRefreshing = false
                self?.update(with: report)
            }
        }
    }

    private func update(with report: SmartctlReport?) {
        guard let report else {
            showError("Samsung SSD не обнаружен")
            return
        }
        lastSeenAt = Date()
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "SSD")

        let health = report.nvmeSmartHealthInformationLog
        let temp = report.temperature?.current ?? health?.temperature
        let warningTemp = report.nvmeCompositeTemperatureThreshold?.warning ?? 84
        let criticalTemp = report.nvmeCompositeTemperatureThreshold?.critical ?? 88
        let critWarning = health?.criticalWarning ?? 0

        // Status bar title + color
        var color: NSColor = .labelColor
        if critWarning != 0 || (temp ?? 0) >= criticalTemp {
            color = .systemRed
        } else if (temp ?? 0) >= warningTemp {
            color = .systemOrange
        }
        let titleText = temp.map { "\($0)°C" } ?? "—"
        let attributed = NSAttributedString(string: " " + titleText, attributes: [.foregroundColor: color])
        statusItem.button?.attributedTitle = attributed

        // Menu
        let menu = NSMenu()
        menu.addItem(disabledItem(report.modelName ?? "Samsung SSD"))
        menu.addItem(disabledItem("S/N: \(report.serialNumber ?? "—")   FW: \(report.firmwareVersion ?? "—")"))
        menu.addItem(NSMenuItem.separator())

        let usedPct = health?.percentageUsed.map { "\($0)%" } ?? "—"
        let passed = report.smartStatus?.passed
        let healthLine = passed == true ? "OK, износ \(usedPct)" : (passed == false ? "ВНИМАНИЕ, износ \(usedPct)" : "износ \(usedPct)")
        menu.addItem(disabledItem("Здоровье: \(healthLine)"))

        let sensors = health?.temperatureSensors?.map { "\($0)°C" }.joined(separator: " / ") ?? "—"
        menu.addItem(disabledItem("Температура: \(titleText) (пороги \(warningTemp)/\(criticalTemp)°C, датчики: \(sensors))"))

        let spare = health?.availableSpare.map { "\($0)%" } ?? "—"
        let spareThresh = health?.availableSpareThreshold.map { "\($0)%" } ?? "—"
        menu.addItem(disabledItem("Резерв (spare): \(spare) (порог \(spareThresh))"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(disabledItem("Записано: \(formatTB(dataUnits: health?.dataUnitsWritten))"))
        menu.addItem(disabledItem("Прочитано: \(formatTB(dataUnits: health?.dataUnitsRead))"))
        menu.addItem(disabledItem("Наработка: \(formatHours(health?.powerOnHours))"))
        menu.addItem(disabledItem("Циклы включения: \(health?.powerCycles.map(String.init) ?? "—")"))
        menu.addItem(disabledItem("Небезопасных выключений: \(health?.unsafeShutdowns.map(String.init) ?? "—")"))
        menu.addItem(disabledItem("Ошибок носителя: \(health?.mediaErrors.map(String.init) ?? "—")   Записей в логе ошибок: \(health?.numErrLogEntries.map(String.init) ?? "—")"))

        menu.addItem(NSMenuItem.separator())
        let critText = critWarning == 0 ? "нет" : "0x\(String(critWarning, radix: 16))"
        menu.addItem(disabledItem("Критическое предупреждение: \(critText)"))

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        menu.addItem(disabledItem("Обновлено: \(formatter.string(from: Date()))"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(intervalSubmenuItem())
        let refreshItem = NSMenuItem(title: "Обновить сейчас", action: #selector(refreshNow), keyEquivalent: "r")
        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        refreshItem.target = self
        quitItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
