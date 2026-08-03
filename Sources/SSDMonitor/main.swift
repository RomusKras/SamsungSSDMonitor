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
    guard let units = dataUnits else { return L10n.unknownValue }
    let bytes = Double(units) * 512_000.0
    return String(format: "%.2f TB", bytes / 1_000_000_000_000.0)
}

func formatHours(_ hours: Int?) -> String {
    guard let hours else { return L10n.unknownValue }
    return L10n.hours(hours, days: hours / 24)
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let intervalOptions: [(title: String, seconds: TimeInterval)] =
        zip(L10n.intervalTitles, [10, 30, 60, 120, 300] as [TimeInterval])
            .map { (title: $0.0, seconds: $0.1) }

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
            showError(L10n.smartctlMissing)
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
        let parent = NSMenuItem(title: L10n.refreshInterval, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        refreshInterval = seconds
        refresh()
    }

    private func showError(_ message: String) {
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.trianglebadge.exclamationmark", accessibilityDescription: L10n.driveMissingAccessibility)
        let attributed = NSAttributedString(string: L10n.noDriveTitle, attributes: [.foregroundColor: NSColor.systemRed])
        statusItem.button?.attributedTitle = attributed

        let menu = NSMenu()
        menu.addItem(disabledItem(message))
        if let lastSeenAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            menu.addItem(disabledItem(L10n.lastSeen(formatter.string(from: lastSeenAt))))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(intervalSubmenuItem())
        menu.addItem(NSMenuItem(title: L10n.refreshNow, action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q"))
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
            showError(L10n.driveNotDetected)
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
        let titleText = temp.map { "\($0)°C" } ?? L10n.unknownValue
        let attributed = NSAttributedString(string: " " + titleText, attributes: [.foregroundColor: color])
        statusItem.button?.attributedTitle = attributed

        // Menu
        let menu = NSMenu()
        menu.addItem(disabledItem(report.modelName ?? "Samsung SSD"))
        menu.addItem(disabledItem("S/N: \(report.serialNumber ?? L10n.unknownValue)   FW: \(report.firmwareVersion ?? L10n.unknownValue)"))
        menu.addItem(NSMenuItem.separator())

        let usedPct = health?.percentageUsed.map { "\($0)%" } ?? L10n.unknownValue
        let passed = report.smartStatus?.passed
        let healthLine = passed == true ? L10n.healthPassed(usedPct)
            : (passed == false ? L10n.healthFailed(usedPct) : L10n.healthUnknown(usedPct))
        menu.addItem(disabledItem(L10n.health(healthLine)))

        let sensors = health?.temperatureSensors?.map { "\($0)°C" }.joined(separator: " / ") ?? L10n.unknownValue
        menu.addItem(disabledItem(L10n.temperature(titleText, warning: warningTemp, critical: criticalTemp, sensors: sensors)))

        let spare = health?.availableSpare.map { "\($0)%" } ?? L10n.unknownValue
        let spareThresh = health?.availableSpareThreshold.map { "\($0)%" } ?? L10n.unknownValue
        menu.addItem(disabledItem(L10n.spare(spare, threshold: spareThresh)))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(disabledItem(L10n.written(formatTB(dataUnits: health?.dataUnitsWritten))))
        menu.addItem(disabledItem(L10n.read(formatTB(dataUnits: health?.dataUnitsRead))))
        menu.addItem(disabledItem(L10n.powerOnTime(formatHours(health?.powerOnHours))))
        menu.addItem(disabledItem(L10n.powerCycles(health?.powerCycles.map(String.init) ?? L10n.unknownValue)))
        menu.addItem(disabledItem(L10n.unsafeShutdowns(health?.unsafeShutdowns.map(String.init) ?? L10n.unknownValue)))
        menu.addItem(disabledItem(L10n.errors(
            media: health?.mediaErrors.map(String.init) ?? L10n.unknownValue,
            log: health?.numErrLogEntries.map(String.init) ?? L10n.unknownValue)))

        menu.addItem(NSMenuItem.separator())
        let critText = critWarning == 0 ? L10n.noCriticalWarning : "0x\(String(critWarning, radix: 16))"
        menu.addItem(disabledItem(L10n.criticalWarning(critText)))

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        menu.addItem(disabledItem(L10n.updated(formatter.string(from: Date()))))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(intervalSubmenuItem())
        let refreshItem = NSMenuItem(title: L10n.refreshNow, action: #selector(refreshNow), keyEquivalent: "r")
        let quitItem = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
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
