import AppKit
import SwiftUI
import IOKit.ps
import CoreWLAN

private enum Metrics {
    static let panelSize = NSSize(width: 310, height: 50)
    static let topMargin: CGFloat = 0
    static let outerRadius: CGFloat = 0
    static let contentRightInset: CGFloat = 8
    static let batteryWidth: CGFloat = 68
    static let weatherWidth: CGFloat = 112
    static let dateTimeWidth: CGFloat = 116
    static let healthWidth: CGFloat = 146
    static let iconWidth: CGFloat = 24
    static let calendarHealthSpacing: CGFloat = 18
    static let healthWorkoutsSpacing: CGFloat = 12
    static let computeWiFiSpacing: CGFloat = 12
    static let wifiBatterySpacing: CGFloat = 6
    static let batteryWeatherSpacing: CGFloat = 6
    static let weatherDateSpacing: CGFloat = 6

    static var weatherRightInset: CGFloat {
        contentRightInset + dateTimeWidth + weatherDateSpacing
    }

    static var wifiIconRightInset: CGFloat {
        weatherRightInset + weatherWidth + batteryWeatherSpacing
            + batteryWidth + wifiBatterySpacing
    }

    static var computeIconRightInset: CGFloat {
        wifiIconRightInset + iconWidth + computeWiFiSpacing
    }
}

private struct BatterySnapshot {
    let percentage: Int
    let isCharging: Bool

    static func read() -> BatterySnapshot {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatterySnapshot(percentage: 0, isCharging: false)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let percentage = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return BatterySnapshot(
                percentage: min(max(percentage, 0), 100),
                isCharging: isCharging
            )
        }

        return BatterySnapshot(percentage: 0, isCharging: false)
    }
}

private final class BatteryModel: ObservableObject {
    @Published private(set) var percentage = 0
    @Published private(set) var isCharging = false
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        let snapshot = BatterySnapshot.read()
        percentage = snapshot.percentage
        isCharging = snapshot.isCharging
    }
}

private struct WiFiSnapshot {
    let signalLevel: Int

    static func read() -> WiFiSnapshot {
        guard
            let interface = CWWiFiClient.shared().interface(),
            interface.powerOn()
        else {
            return WiFiSnapshot(signalLevel: 0)
        }

        let rssi = interface.rssiValue()
        guard rssi < 0 else { return WiFiSnapshot(signalLevel: 0) }

        if rssi >= -60 { return WiFiSnapshot(signalLevel: 3) }
        if rssi >= -75 { return WiFiSnapshot(signalLevel: 2) }
        return WiFiSnapshot(signalLevel: 1)
    }
}

private final class WiFiModel: ObservableObject {
    @Published private(set) var signalLevel = 0
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        signalLevel = WiFiSnapshot.read().signalLevel
    }
}

private struct ComputeSnapshot {
    let cpu: Int
    let gpu: Int
    let ram: Int
    let diskFreeBytes: Int64

    static func read() -> ComputeSnapshot {
        let diskFreeBytes = availableDiskBytes()
        let command = #"""
        GPU=$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | sed -n 's/.*"Device Utilization %"=\([0-9][0-9]*\).*/\1/p' | head -1)
        CPU=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub(/%/, "", $3); gsub(/%/, "", $5); printf "%.0f", $3 + $5; exit}')
        FREE=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/ {gsub(/%/, "", $2); print $2; exit}')
        printf '%s %s %s\n' "${CPU:-0}" "${GPU:-0}" "$((100-${FREE:-100}))"
        """#

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let values = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { Int($0) }
            guard values.count == 3 else {
                return ComputeSnapshot(cpu: 0, gpu: 0, ram: 0, diskFreeBytes: diskFreeBytes)
            }
            return ComputeSnapshot(
                cpu: min(max(values[0], 0), 100),
                gpu: min(max(values[1], 0), 100),
                ram: min(max(values[2], 0), 100),
                diskFreeBytes: diskFreeBytes
            )
        } catch {
            return ComputeSnapshot(cpu: 0, gpu: 0, ram: 0, diskFreeBytes: diskFreeBytes)
        }
    }

    private static func availableDiskBytes() -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
            let freeBytes = attributes[.systemFreeSize] as? NSNumber
        else { return 0 }
        return max(freeBytes.int64Value, 0)
    }
}

private final class ComputeModel: ObservableObject {
    @Published private(set) var cpu = 0
    @Published private(set) var gpu = 0
    @Published private(set) var ram = 0
    @Published private(set) var diskFreeBytes: Int64 = 0
    private var timer: Timer?
    private var refreshInFlight = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 3,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = ComputeSnapshot.read()
            DispatchQueue.main.async {
                self?.cpu = snapshot.cpu
                self?.gpu = snapshot.gpu
                self?.ram = snapshot.ram
                self?.diskFreeBytes = snapshot.diskFreeBytes
                self?.refreshInFlight = false
            }
        }
    }
}

private final class DateTimeModel: ObservableObject {
    @Published private(set) var text = "--/--/-- --:--"
    private let formatter: DateFormatter
    private var timer: Timer?

    init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "dd/MM/yy HH:mm"
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 15,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        text = formatter.string(from: Date())
    }
}

private struct CalendarPayload: Decodable {
    let hasEvent: Bool
    let title: String?
    let color: String?
    let remainingMinutes: Int?
    let inProgress: Bool?
    let meetingURL: String?

    enum CodingKeys: String, CodingKey {
        case title, color
        case hasEvent = "has_event"
        case remainingMinutes = "remaining_minutes"
        case inProgress = "in_progress"
        case meetingURL = "meeting_url"
    }
}

private final class CalendarStatusModel: ObservableObject {
    @Published private(set) var hasEvent = false
    @Published private(set) var title = "Nessun evento"
    @Published private(set) var colorHex = "0xffcac4d0"
    @Published private(set) var remainingMinutes = 0
    @Published private(set) var inProgress = false
    @Published private(set) var hasMeetingLink = false
    private let stateURL = URL(fileURLWithPath: "/tmp/sketchybar_calendar_state.json")
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        guard
            let data = try? Data(contentsOf: stateURL),
            let payload = try? JSONDecoder().decode(CalendarPayload.self, from: data)
        else { return }

        hasEvent = payload.hasEvent
        title = payload.title ?? "Nessun evento"
        colorHex = payload.color ?? "0xffcac4d0"
        remainingMinutes = payload.remainingMinutes ?? 0
        inProgress = payload.inProgress ?? false
        hasMeetingLink = !(payload.meetingURL ?? "").isEmpty
    }
}

private struct CalendarStatusWidget: View {
    @ObservedObject var model: CalendarStatusModel
    private let neutral = Color(red: 0.79, green: 0.77, blue: 0.81)

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.hasEvent ? eventColor : neutral.opacity(0.38))

            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(neutral)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard model.hasEvent else { return "Nessun evento" }
        let duration = model.remainingMinutes < 60
            ? "\(model.remainingMinutes)m"
            : "\(model.remainingMinutes / 60)h \(model.remainingMinutes % 60)m"
        let text: String
        if model.inProgress {
            text = model.hasMeetingLink ? model.title : "\(model.title) · \(duration)"
        } else {
            text = "\(model.title) · tra \(duration)"
        }
        // Il gruppo di sinistra adotta la larghezza del contenuto: senza un
        // limite un titolo lunghissimo spingerebbe il resto della barra.
        return text.count > 52 ? text.prefix(51).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    private var eventColor: Color {
        let raw = model.colorHex.lowercased().replacingOccurrences(of: "0x", with: "")
        let rgbString = raw.count == 8 ? String(raw.dropFirst(2)) : raw
        guard let value = UInt64(rgbString, radix: 16), rgbString.count == 6 else { return neutral }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

private struct WeatherPayload: Decodable {
    let city: String?
    let temperature: Double?
    let icon: String?
}

private final class WeatherStatusModel: ObservableObject {
    @Published private(set) var city = "--"
    @Published private(set) var temperature: Double?
    @Published private(set) var icon: String?
    private let stateURL = URL(fileURLWithPath: "/tmp/sketchybar_weather_state.json")
    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    private var updateProcess: Process?

    func start() {
        refresh()
        requestWeatherUpdate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
        updateTimer = Timer.scheduledTimer(
            timeInterval: 900,
            target: self,
            selector: #selector(requestWeatherUpdate),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        guard
            let data = try? Data(contentsOf: stateURL),
            let payload = try? JSONDecoder().decode(WeatherPayload.self, from: data)
        else { return }
        city = payload.city ?? "--"
        temperature = payload.temperature
        icon = payload.icon
    }

    @objc private func requestWeatherUpdate() {
        guard updateProcess?.isRunning != true else { return }
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sketchybar/plugins/weather.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return }

        let process = Process()
        process.executableURL = scriptURL
        var environment = ProcessInfo.processInfo.environment
        environment["NAME"] = "weather"
        environment["SENDER"] = "swift_bar"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateProcess = nil
                self?.refresh()
            }
        }
        do {
            try process.run()
            updateProcess = process
        } catch {
            updateProcess = nil
        }
    }
}

private struct WeatherStatusWidget: View {
    @ObservedObject var model: WeatherStatusModel
    private let textColor = Color(red: 0.79, green: 0.77, blue: 0.81)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(conditionColor)
                .frame(width: 18, height: 20)

            Text(temperatureLabel)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(textColor)

            Text(model.city)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meteo, \(temperatureLabel), \(model.city)")
    }

    private var temperatureLabel: String {
        guard let temperature = model.temperature else { return "--°" }
        return "\(Int(temperature.rounded()))°"
    }

    private var symbolName: String {
        switch model.icon {
        case "sunny": return "sun.max"
        case "partly_cloudy_day": return "cloud.sun"
        case "bedtime": return "moon.stars"
        case "partly_cloudy_night": return "cloud.moon"
        case "rainy", "weather_mix": return "cloud.rain"
        case "weather_snowy", "cloudy_snowing": return "cloud.snow"
        case "foggy": return "cloud.fog"
        case "thunderstorm": return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    private var conditionColor: Color {
        switch model.icon {
        case "sunny": return Color(red: 1.00, green: 0.80, blue: 0.30)
        case "partly_cloudy_day": return Color(red: 1.00, green: 0.82, blue: 0.40)
        case "bedtime", "partly_cloudy_night": return Color(red: 0.72, green: 0.76, blue: 1.00)
        case "rainy", "weather_mix": return Color(red: 0.50, green: 0.87, blue: 1.00)
        case "weather_snowy", "cloudy_snowing": return Color(red: 0.73, green: 0.92, blue: 1.00)
        case "thunderstorm": return Color(red: 0.75, green: 0.57, blue: 1.00)
        default: return textColor
        }
    }
}

private struct HealthPayload: Decodable {
    struct Sleep: Decodable {
        let performance: Int?
        let efficiency: Int?
        let consistency: Int?
        let asleepHours: Double?

        enum CodingKeys: String, CodingKey {
            case performance, efficiency, consistency
            case asleepHours = "asleep_hours"
        }
    }

    struct Recovery: Decodable {
        let score: Int?
    }

    struct Strain: Decodable {
        let score: Double?
    }

    struct Workout: Decodable, Identifiable {
        let sport: String
        let start: String?
        let end: String?
        let minutes: Int?
        let strain: Double?
        let avgHr: Int?
        let maxHr: Int?
        let kcal: Int?
        let distanceKm: Double?

        var id: String { (start ?? "") + "|" + sport }

        enum CodingKeys: String, CodingKey {
            case sport, start, end, minutes, strain, kcal
            case avgHr = "avg_hr"
            case maxHr = "max_hr"
            case distanceKm = "distance_km"
        }

        var startDate: Date? {
            guard let start else { return nil }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: start) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: start)
        }
    }

    struct Workouts: Decodable {
        let weekStart: String?
        let count: Int?
        let totalStrain: Double?
        let totalKcal: Int?
        let totalMinutes: Int?
        let items: [Workout]?

        enum CodingKeys: String, CodingKey {
            case count, items
            case weekStart = "week_start"
            case totalStrain = "total_strain"
            case totalKcal = "total_kcal"
            case totalMinutes = "total_minutes"
        }
    }

    let sleep: Sleep?
    let recovery: Recovery?
    let strain: Strain?
    let workouts: Workouts?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case sleep, recovery, strain, workouts
        case updatedAt = "updated_at"
    }
}

private final class HealthStatusModel: ObservableObject {
    @Published private(set) var sleepPerformance: Int?
    @Published private(set) var recoveryScore: Int?
    @Published private(set) var dayStrain: Double?
    @Published private(set) var asleepHours: Double?
    @Published private(set) var weeklyWorkoutCount: Int?
    @Published private(set) var weeklyWorkoutMinutes: Int?
    @Published private(set) var weeklyWorkoutStrain: Double?
    @Published private(set) var workouts: [HealthPayload.Workout] = []
    private let stateURL = URL(fileURLWithPath: "/tmp/sketchybar_health_state.json")
    private var refreshTimer: Timer?

    func start() {
        refresh()
        // Sola lettura del file di stato: a scaricarlo da WHOOP e a scriverlo
        // ci pensa il LaunchAgent whoop_archive.sh (ogni 30 minuti), che è anche
        // l'unico a rinnovare i token.
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        guard
            let data = try? Data(contentsOf: stateURL),
            let payload = try? JSONDecoder().decode(HealthPayload.self, from: data)
        else { return }
        sleepPerformance = payload.sleep?.performance
        recoveryScore = payload.recovery?.score
        dayStrain = payload.strain?.score
        asleepHours = payload.sleep?.asleepHours
        weeklyWorkoutCount = payload.workouts?.count
        weeklyWorkoutMinutes = payload.workouts?.totalMinutes
        weeklyWorkoutStrain = payload.workouts?.totalStrain
        workouts = payload.workouts?.items ?? []
    }
}

private struct HealthStatusWidget: View {
    @ObservedObject var model: HealthStatusModel

    private static let neutral = Color(red: 0.79, green: 0.77, blue: 0.81)
    private static let green = Color(red: 0.65, green: 0.89, blue: 0.63)
    private static let yellow = Color(red: 0.98, green: 0.89, blue: 0.69)
    private static let red = Color(red: 0.95, green: 0.55, blue: 0.66)
    private static let strainBlue = Color(red: 0.50, green: 0.87, blue: 1.00)

    var body: some View {
        HStack(spacing: 10) {
            metric(
                icon: "bed.double.fill",
                value: model.sleepPerformance.map { "\($0)" },
                color: sleepColor
            )
            metric(
                icon: "heart.fill",
                value: model.recoveryScore.map { "\($0)" },
                color: recoveryColor
            )
            metric(
                icon: "bolt.fill",
                value: model.dayStrain.map { strain in
                    String(format: strain < 10 ? "%.1f" : "%.0f", strain)
                },
                color: model.dayStrain == nil ? Self.neutral : Self.strainBlue
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func metric(icon: String, value: String?, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(value == nil ? Self.neutral.opacity(0.5) : color)

            Text(value ?? "--")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(value == nil ? Self.neutral : color)
        }
    }

    private var sleepColor: Color {
        guard let value = model.sleepPerformance else { return Self.neutral }
        switch value {
        case ..<60: return Self.red
        case ..<85: return Self.yellow
        default: return Self.green
        }
    }

    private var recoveryColor: Color {
        guard let value = model.recoveryScore else { return Self.neutral }
        switch value {
        case ..<34: return Self.red
        case ..<67: return Self.yellow
        default: return Self.green
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let sleep = model.sleepPerformance { parts.append("sonno \(sleep) percento") }
        if let recovery = model.recoveryScore { parts.append("recupero \(recovery) percento") }
        if let strain = model.dayStrain { parts.append(String(format: "sforzo %.1f", strain)) }
        return parts.isEmpty ? "Dati salute non disponibili" : parts.joined(separator: ", ")
    }
}

/// Icona "workout" WHOOP: due tracciati stroke su viewBox 24×24, ridisegnati
/// come Path per restare nitidi a qualunque scala (come BatteryLevelIcon).
private struct WorkoutMarkIcon: View {
    var color: Color = .white
    var lineWidth: CGFloat = 1.7

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 24
            let sy = size.height / 24
            let stroke = StrokeStyle(
                lineWidth: lineWidth * sx,
                lineCap: .round,
                lineJoin: .round
            )

            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * sx, y: y * sy)
            }

            var path = Path()
            path.move(to: p(2.01792, 20.3051))
            path.addCurve(to: p(10.3797, 20.1645),
                          control1: p(3.14656, 21.9196), control2: p(8.05942, 23.1871))
            path.addCurve(to: p(20.3991, 19.1134),
                          control1: p(12.8894, 21.3649), control2: p(17.0289, 20.9928))
            path.addCurve(to: p(21.5827, 18.0593),
                          control1: p(20.8678, 18.8521), control2: p(21.3112, 18.5222))
            path.addCurve(to: p(21.0919, 13.4251),
                          control1: p(22.1957, 17.0143), control2: p(22.2102, 15.5644))
            path.addCurve(to: p(14.5201, 3.04212),
                          control1: p(19.2274, 8.77072), control2: p(15.874, 4.68513))
            path.addCurve(to: p(11.3872, 2.08279),
                          control1: p(14.2421, 2.78865), control2: p(12.4687, 2.42868))
            path.addCurve(to: p(8.95612, 3.23862),
                          control1: p(10.9095, 1.93477), control2: p(10.02, 1.83664))
            path.addCurve(to: p(9.06767, 6.63346),
                          control1: p(8.45176, 3.90329), control2: p(6.16059, 5.5357))
            path.addCurve(to: p(11.9038, 6.58404),
                          control1: p(9.51805, 6.74806), control2: p(9.84912, 6.95939))
            path.addCurve(to: p(13.3103, 7.41041),
                          control1: p(12.1714, 6.53761), control2: p(12.8395, 6.58404))
            path.addLine(to: p(14.2936, 8.81662))
            path.addCurve(to: p(14.4627, 9.25682),
                          control1: p(14.3851, 8.94752), control2: p(14.4445, 9.09813))
            path.addCurve(to: p(15.4651, 13.5826),
                          control1: p(14.635, 10.7557), control2: p(14.6294, 12.6323))
            path.addCurve(to: p(8.2595, 14.6951),
                          control1: p(14.1743, 12.6492), control2: p(10.8011, 11.5406))

            path.move(to: p(2.00189, 12.94))
            path.addCurve(to: p(10.4179, 12.5216),
                          control1: p(3.21009, 11.791), control2: p(6.71197, 9.97592))

            context.stroke(path, with: .color(color), style: stroke)
        }
    }
}

private struct WeeklyWorkoutsIcon: View {
    let count: Int?

    // Palette del badge: pill sabbia (#F0E7DA), icona e numero viola scuro (#2D1C42).
    private static let pill = Color(red: 0.941, green: 0.906, blue: 0.855)
    private static let accent = Color(red: 0.176, green: 0.110, blue: 0.259)
    private static let accentMuted = Color(red: 0.176, green: 0.110, blue: 0.259)

    var body: some View {
        let available = count != nil
        let tint = available ? Self.accent : Self.accentMuted

        HStack(spacing: 7) {
            WorkoutMarkIcon(color: tint)
                .frame(width: 16, height: 16)

            Text(count.map { "\($0)" } ?? "--")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint)
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Self.pill))
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            count.map { "\($0) allenamenti questa settimana" } ?? "Allenamenti non disponibili"
        )
    }
}

private struct BatteryLevelIcon: View, Animatable {
    var level: CGFloat
    let accent: Color

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 24
            let sy = size.height / 24
            let stroke = StrokeStyle(
                lineWidth: 1.5 * sx,
                lineCap: .round,
                lineJoin: .round
            )

            var body = Path()
            body.move(to: CGPoint(x: 2 * sx, y: 12 * sy))
            body.addCurve(
                to: CGPoint(x: 2.879 * sx, y: 6.879 * sy),
                control1: CGPoint(x: 2 * sx, y: 9.172 * sy),
                control2: CGPoint(x: 2 * sx, y: 7.757 * sy)
            )
            body.addCurve(
                to: CGPoint(x: 8 * sx, y: 6 * sy),
                control1: CGPoint(x: 3.757 * sx, y: 6 * sy),
                control2: CGPoint(x: 5.172 * sx, y: 6 * sy)
            )
            body.addLine(to: CGPoint(x: 13 * sx, y: 6 * sy))
            body.addCurve(
                to: CGPoint(x: 18.121 * sx, y: 6.879 * sy),
                control1: CGPoint(x: 15.828 * sx, y: 6 * sy),
                control2: CGPoint(x: 17.243 * sx, y: 6 * sy)
            )
            body.addCurve(
                to: CGPoint(x: 19 * sx, y: 12 * sy),
                control1: CGPoint(x: 19 * sx, y: 7.757 * sy),
                control2: CGPoint(x: 19 * sx, y: 9.172 * sy)
            )
            body.addCurve(
                to: CGPoint(x: 18.121 * sx, y: 17.121 * sy),
                control1: CGPoint(x: 19 * sx, y: 14.828 * sy),
                control2: CGPoint(x: 19 * sx, y: 16.243 * sy)
            )
            body.addCurve(
                to: CGPoint(x: 13 * sx, y: 18 * sy),
                control1: CGPoint(x: 17.243 * sx, y: 18 * sy),
                control2: CGPoint(x: 15.828 * sx, y: 18 * sy)
            )
            body.addLine(to: CGPoint(x: 8 * sx, y: 18 * sy))
            body.addCurve(
                to: CGPoint(x: 2.879 * sx, y: 17.121 * sy),
                control1: CGPoint(x: 5.172 * sx, y: 18 * sy),
                control2: CGPoint(x: 3.757 * sx, y: 18 * sy)
            )
            body.addCurve(
                to: CGPoint(x: 2 * sx, y: 12 * sy),
                control1: CGPoint(x: 2 * sx, y: 16.243 * sy),
                control2: CGPoint(x: 2 * sx, y: 14.828 * sy)
            )
            body.closeSubpath()

            let clampedLevel = min(max(level, 0), 1)
            var fillContext = context
            fillContext.clip(to: body)
            let fillRect = CGRect(
                x: 2.75 * sx,
                y: 6.75 * sy,
                width: 15.5 * sx * clampedLevel,
                height: 10.5 * sy
            )
            fillContext.fill(Path(fillRect), with: .color(accent.opacity(0.82)))
            context.stroke(body, with: .color(accent), style: stroke)

            var terminal = Path()
            terminal.move(to: CGPoint(x: 19 * sx, y: 9.5 * sy))
            terminal.addLine(to: CGPoint(x: 20.027 * sx, y: 9.671 * sy))
            terminal.addCurve(
                to: CGPoint(x: 21.308 * sx, y: 10.007 * sy),
                control1: CGPoint(x: 20.709 * sx, y: 9.785 * sy),
                control2: CGPoint(x: 21.049 * sx, y: 9.842 * sy)
            )
            terminal.addCurve(
                to: CGPoint(x: 21.880 * sx, y: 10.682 * sy),
                control1: CGPoint(x: 21.562 * sx, y: 10.169 * sy),
                control2: CGPoint(x: 21.761 * sx, y: 10.404 * sy)
            )
            terminal.addCurve(
                to: CGPoint(x: 22 * sx, y: 12 * sy),
                control1: CGPoint(x: 22 * sx, y: 10.964 * sy),
                control2: CGPoint(x: 22 * sx, y: 11.309 * sy)
            )
            terminal.addCurve(
                to: CGPoint(x: 21.880 * sx, y: 13.318 * sy),
                control1: CGPoint(x: 22 * sx, y: 12.691 * sy),
                control2: CGPoint(x: 22 * sx, y: 13.036 * sy)
            )
            terminal.addCurve(
                to: CGPoint(x: 21.308 * sx, y: 13.993 * sy),
                control1: CGPoint(x: 21.761 * sx, y: 13.596 * sy),
                control2: CGPoint(x: 21.562 * sx, y: 13.831 * sy)
            )
            terminal.addCurve(
                to: CGPoint(x: 20.027 * sx, y: 14.329 * sy),
                control1: CGPoint(x: 21.049 * sx, y: 14.159 * sy),
                control2: CGPoint(x: 20.709 * sx, y: 14.215 * sy)
            )
            terminal.addLine(to: CGPoint(x: 19 * sx, y: 14.5 * sy))
            context.stroke(terminal, with: .color(accent), style: stroke)
        }
    }
}

private struct BatteryWidget: View {
    @ObservedObject var model: BatteryModel

    private var statusColor: Color {
        switch model.percentage {
        case ..<20: return Color(red: 0.95, green: 0.55, blue: 0.66)
        case ...75: return Color(red: 0.98, green: 0.89, blue: 0.69)
        default: return Color(red: 0.65, green: 0.89, blue: 0.63)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            BatteryLevelIcon(
                level: CGFloat(model.percentage) / 100,
                accent: statusColor
            )
                .frame(width: 24, height: 24)

            Text("\(model.percentage)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(statusColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.65), value: model.percentage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Batteria \(model.percentage) percento")
    }
}

private struct WiFiSignalIcon: View {
    let signalLevel: Int

    private var statusColor: Color {
        switch signalLevel {
        case 3: return Color(red: 0.65, green: 0.89, blue: 0.63)
        case 2: return Color(red: 0.98, green: 0.89, blue: 0.69)
        case 1: return Color(red: 0.95, green: 0.55, blue: 0.66)
        default: return Color(red: 0.79, green: 0.77, blue: 0.81)
        }
    }

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 24
            let scaleY = size.height / 24
            let bars = [
                CGRect(x: 4, y: 12, width: 3, height: 7),
                CGRect(x: 10.5, y: 8, width: 3, height: 11),
                CGRect(x: 17, y: 5, width: 3, height: 14)
            ]

            for (index, bar) in bars.enumerated() {
                let rect = CGRect(
                    x: bar.minX * scaleX,
                    y: bar.minY * scaleY,
                    width: bar.width * scaleX,
                    height: bar.height * scaleY
                )
                let path = Path(roundedRect: rect, cornerRadius: 1.5 * scaleX)

                let isFilled = index < signalLevel
                if isFilled {
                    context.fill(path, with: .color(statusColor.opacity(0.84)))
                }
                context.stroke(
                    path,
                    with: .color(statusColor.opacity(
                        signalLevel == 0 ? 0.60 : (isFilled ? 0.95 : 0.38)
                    )),
                    lineWidth: 1.5 * scaleX
                )
            }
        }
        .accessibilityLabel(signalLevel == 0 ? "Wi-Fi non connesso" : "Segnale Wi-Fi livello \(signalLevel) di 3")
    }
}

private struct ComputeIcon: View {
    private let color = Color(red: 0.79, green: 0.77, blue: 0.81)

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 24
            let sy = size.height / 24
            let stroke = StrokeStyle(
                lineWidth: 1.5 * sx,
                lineCap: .round,
                lineJoin: .round
            )

            var outer = Path()
            outer.addRoundedRect(
                in: CGRect(x: 4 * sx, y: 4 * sy, width: 16 * sx, height: 16 * sy),
                cornerSize: CGSize(width: 4 * sx, height: 4 * sy)
            )
            context.stroke(outer, with: .color(color), style: stroke)

            var core = Path()
            core.move(to: CGPoint(x: 7.732 * sx, y: 16.268 * sy))
            core.addCurve(
                to: CGPoint(x: 12 * sx, y: 17 * sy),
                control1: CGPoint(x: 8.464 * sx, y: 17 * sy),
                control2: CGPoint(x: 9.643 * sx, y: 17 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 14 * sx, y: 16.972 * sy),
                control1: CGPoint(x: 12.790 * sx, y: 17 * sy),
                control2: CGPoint(x: 13.447 * sx, y: 17 * sy)
            )
            core.addLine(to: CGPoint(x: 16.972 * sx, y: 14 * sy))
            core.addCurve(
                to: CGPoint(x: 17 * sx, y: 12 * sy),
                control1: CGPoint(x: 17 * sx, y: 13.447 * sy),
                control2: CGPoint(x: 17 * sx, y: 12.790 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 16.268 * sx, y: 7.732 * sy),
                control1: CGPoint(x: 17 * sx, y: 9.643 * sy),
                control2: CGPoint(x: 17 * sx, y: 8.464 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 12 * sx, y: 7 * sy),
                control1: CGPoint(x: 15.536 * sx, y: 7 * sy),
                control2: CGPoint(x: 14.357 * sx, y: 7 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 7.732 * sx, y: 7.732 * sy),
                control1: CGPoint(x: 9.643 * sx, y: 7 * sy),
                control2: CGPoint(x: 8.464 * sx, y: 7 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 7 * sx, y: 12 * sy),
                control1: CGPoint(x: 7 * sx, y: 8.464 * sy),
                control2: CGPoint(x: 7 * sx, y: 9.643 * sy)
            )
            core.addCurve(
                to: CGPoint(x: 7.732 * sx, y: 16.268 * sy),
                control1: CGPoint(x: 7 * sx, y: 14.357 * sy),
                control2: CGPoint(x: 7 * sx, y: 15.536 * sy)
            )
            core.closeSubpath()
            context.stroke(core, with: .color(color), style: stroke)

            let pins: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (8, 2, 8, 4), (12, 2, 12, 4), (16, 2, 16, 4),
                (8, 20, 8, 22), (12, 20, 12, 22), (16, 20, 16, 22),
                (2, 8, 4, 8), (2, 12, 4, 12), (2, 16, 4, 16),
                (20, 8, 22, 8), (20, 12, 22, 12), (20, 16, 22, 16)
            ]
            var pinPath = Path()
            for pin in pins {
                pinPath.move(to: CGPoint(x: pin.0 * sx, y: pin.1 * sy))
                pinPath.addLine(to: CGPoint(x: pin.2 * sx, y: pin.3 * sy))
            }
            context.stroke(pinPath, with: .color(color), style: stroke)
        }
        .accessibilityLabel("Stato compute")
    }
}

// MARK: - Compute popup

private struct ComputePopupView: View {
    @ObservedObject var model: ComputeModel

    var body: some View {
        DesignSystemCard(title: "Compute", subtitle: "Utilizzo in tempo reale") {
            DesignSystemCardRow(
                icon: "cpu",
                iconTint: Color(red: 0.94, green: 0.37, blue: 0.22),
                title: "CPU",
                value: "\(model.cpu)% utilizzata"
            )
            DesignSystemCardRow(
                icon: "square.stack.3d.up.fill",
                iconTint: Color(red: 0.39, green: 0.52, blue: 0.96),
                title: "GPU",
                value: "\(model.gpu)% utilizzata"
            )
            DesignSystemCardRow(
                icon: "memorychip.fill",
                iconTint: Color(red: 0.40, green: 0.69, blue: 0.44),
                title: "Memoria",
                value: "\(model.ram)% utilizzata"
            )
            DesignSystemCardRow(
                icon: "internaldrive.fill",
                iconTint: Color(red: 0.73, green: 0.62, blue: 0.95),
                title: "SSD",
                value: "\(diskFreeLabel) disponibili",
                actionTitle: "Pulisci",
                action: openMoleInTerminal
            )
        }
        .frame(width: 320, height: 352)
    }

    private var diskFreeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: model.diskFreeBytes,
            countStyle: .file
        )
    }

    private func openMoleInTerminal() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            tell application "Terminal"
                activate
                do script "/opt/homebrew/bin/mole"
            end tell
            """
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - Workouts popup

private struct WorkoutsPopupView: View {
    @ObservedObject var model: HealthStatusModel

    private static let accent = Color(red: 0.39, green: 0.52, blue: 0.96)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEE d MMM · HH:mm"
        return formatter
    }()

    var body: some View {
        DesignSystemCard(title: "Allenamenti", subtitle: subtitle) {
            if model.workouts.isEmpty {
                DesignSystemCardRow(
                    icon: "zzz",
                    iconTint: Color(red: 0.60, green: 0.66, blue: 0.80),
                    title: "Nessun allenamento",
                    value: "Questa settimana"
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.workouts) { workout in
                            DesignSystemCardRow(
                                icon: Self.sportIcon(workout.sport),
                                iconTint: Self.accent,
                                title: workout.sport,
                                value: detail(workout)
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 360, height: 380)
    }

    private var subtitle: String {
        let count = model.weeklyWorkoutCount ?? 0
        guard count > 0 else { return "Settimana corrente" }
        let minutes = model.weeklyWorkoutMinutes ?? 0
        let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        let strain = model.weeklyWorkoutStrain ?? 0
        return "\(count) · \(duration) · strain \(String(format: "%.1f", strain))"
    }

    private func detail(_ workout: HealthPayload.Workout) -> String {
        var parts: [String] = []
        if let date = workout.startDate {
            parts.append(Self.dayFormatter.string(from: date))
        }
        if let minutes = workout.minutes { parts.append("\(minutes)m") }
        if let strain = workout.strain { parts.append("strain \(String(format: "%.1f", strain))") }
        if let avgHr = workout.avgHr { parts.append("\(avgHr) bpm") }
        if let km = workout.distanceKm { parts.append(String(format: "%.1f km", km)) }
        if let kcal = workout.kcal { parts.append("\(kcal) kcal") }
        return parts.joined(separator: "  ·  ")
    }

    private static func sportIcon(_ sport: String) -> String {
        let name = sport.lowercased()
        switch true {
        case name.contains("run"): return "figure.run"
        case name.contains("walk"): return "figure.walk"
        case name.contains("hik"): return "figure.hiking"
        case name.contains("cycl"), name.contains("bike"), name.contains("ride"):
            return "figure.outdoor.cycle"
        case name.contains("swim"): return "figure.pool.swim"
        case name.contains("weight"), name.contains("lift"), name.contains("strength"):
            return "dumbbell.fill"
        case name.contains("yoga"): return "figure.yoga"
        case name.contains("pilates"): return "figure.pilates"
        case name.contains("box"), name.contains("mma"), name.contains("martial"):
            return "figure.boxing"
        case name.contains("row"): return "figure.rower"
        case name.contains("hiit"), name.contains("functional"), name.contains("crossfit"):
            return "figure.highintensity.intervaltraining"
        case name.contains("elliptical"): return "figure.elliptical"
        case name.contains("ski"): return "figure.skiing.downhill"
        case name.contains("soccer"), name.contains("football"): return "figure.soccer"
        case name.contains("basket"): return "figure.basketball"
        case name.contains("tennis"), name.contains("padel"): return "figure.tennis"
        default: return "figure.mixed.cardio"
        }
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct BatteryBarView: View {
    @ObservedObject var batteryModel: BatteryModel
    @ObservedObject var wifiModel: WiFiModel
    @ObservedObject var dateTimeModel: DateTimeModel
    @ObservedObject var calendarModel: CalendarStatusModel
    @ObservedObject var weatherModel: WeatherStatusModel
    @ObservedObject var healthModel: HealthStatusModel
    let onComputeClick: () -> Void
    let onWiFiClick: () -> Void
    let onCalendarClick: () -> Void
    let onWeatherClick: () -> Void
    let onWorkoutsClick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Gruppo di sinistra: calendario e salute aderiscono al contenuto,
            // così le metriche restano a fianco del testo dell'evento invece di
            // essere spinte al centro da un frame elastico.
            HStack(spacing: 0) {
                Button(action: onCalendarClick) {
                    CalendarStatusWidget(model: calendarModel)
                }
                .buttonStyle(.plain)

                Spacer().frame(width: Metrics.calendarHealthSpacing)

                HealthStatusWidget(model: healthModel)
                    .frame(width: Metrics.healthWidth)

                Spacer().frame(width: Metrics.healthWorkoutsSpacing)

                Button(action: onWorkoutsClick) {
                    WeeklyWorkoutsIcon(count: healthModel.weeklyWorkoutCount)
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 24)

            Button(action: onComputeClick) {
                ComputeIcon()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer().frame(width: Metrics.computeWiFiSpacing)

            Button(action: onWiFiClick) {
                WiFiSignalIcon(signalLevel: wifiModel.signalLevel)
                    .frame(width: Metrics.iconWidth, height: Metrics.iconWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer().frame(width: Metrics.wifiBatterySpacing)

            BatteryWidget(model: batteryModel)
                .frame(width: Metrics.batteryWidth)

            Spacer().frame(width: Metrics.batteryWeatherSpacing)

            Button(action: onWeatherClick) {
                WeatherStatusWidget(model: weatherModel)
                    .frame(width: Metrics.weatherWidth)
            }
            .buttonStyle(.plain)

            Spacer().frame(width: Metrics.weatherDateSpacing)

            Text(dateTimeModel.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.79, green: 0.77, blue: 0.81))
                .frame(width: Metrics.dateTimeWidth, alignment: .center)
        }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(8)
            .background {
                ZStack {
                    GlassBackground()
                    Color.black.opacity(0.18)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.outerRadius, style: .continuous))
            }
    }
}

private final class BatteryBarApp: NSObject, NSApplicationDelegate {
    private let batteryModel = BatteryModel()
    private let wifiModel = WiFiModel()
    private let computeModel = ComputeModel()
    private let dateTimeModel = DateTimeModel()
    private let calendarModel = CalendarStatusModel()
    private let weatherModel = WeatherStatusModel()
    private let healthModel = HealthStatusModel()
    private var panel: NSPanel?
    private var computePanel: NSPanel?
    private var workoutsPanel: NSPanel?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryModel.start()
        wifiModel.start()
        computeModel.start()
        dateTimeModel.start()
        calendarModel.start()
        weatherModel.start()
        healthModel.start()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Metrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: BatteryBarView(
                batteryModel: batteryModel,
                wifiModel: wifiModel,
                dateTimeModel: dateTimeModel,
                calendarModel: calendarModel,
                weatherModel: weatherModel,
                healthModel: healthModel,
                onComputeClick: { [weak self] in self?.toggleComputePopup() },
                onWiFiClick: { [weak self] in self?.toggleWiFiPopup() },
                onCalendarClick: { [weak self] in self?.toggleCalendarPopup() },
                onWeatherClick: { [weak self] in self?.toggleWeatherPopup() },
                onWorkoutsClick: { [weak self] in self?.toggleWorkoutsPopup() }
            )
        )
        self.panel = panel

        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            batteryModel,
            selector: #selector(BatteryModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            wifiModel,
            selector: #selector(WiFiModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            computeModel,
            selector: #selector(ComputeModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            dateTimeModel,
            selector: #selector(DateTimeModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            calendarModel,
            selector: #selector(CalendarStatusModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            weatherModel,
            selector: #selector(WeatherStatusModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            healthModel,
            selector: #selector(HealthStatusModel.refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeComputePopupIfPointerIsOutside()
                self?.closeWorkoutsPopupIfPointerIsOutside()
            }
        }
    }

    @objc private func screenConfigurationChanged() {
        positionPanel()
        positionComputePopup()
        positionWorkoutsPopup()
    }

    private func toggleComputePopup() {
        sendNetworkPopupCommand("hide")
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        workoutsPanel?.orderOut(nil)
        if computePanel?.isVisible == true {
            computePanel?.orderOut(nil)
            return
        }

        if computePanel == nil {
            let size = NSSize(width: 320, height: 352)
            let popup = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            popup.isOpaque = false
            popup.backgroundColor = .clear
            popup.hasShadow = false
            popup.level = .statusBar
            popup.hidesOnDeactivate = false
            popup.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            popup.contentView = NSHostingView(rootView: ComputePopupView(model: computeModel))
            computePanel = popup
        }

        computeModel.refresh()
        positionComputePopup()
        computePanel?.orderFrontRegardless()
    }

    private func positionComputePopup() {
        guard let panel, let computePanel else { return }
        let gap: CGFloat = 6
        let anchorRight = panel.frame.maxX - Metrics.computeIconRightInset
        let frame = NSRect(
            x: anchorRight - computePanel.frame.width,
            y: panel.frame.minY - computePanel.frame.height - gap,
            width: computePanel.frame.width,
            height: computePanel.frame.height
        )
        computePanel.setFrame(frame, display: true)
    }

    private func toggleWorkoutsPopup() {
        sendNetworkPopupCommand("hide")
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        computePanel?.orderOut(nil)
        if workoutsPanel?.isVisible == true {
            workoutsPanel?.orderOut(nil)
            return
        }

        if workoutsPanel == nil {
            let size = NSSize(width: 360, height: 380)
            let popup = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            popup.isOpaque = false
            popup.backgroundColor = .clear
            popup.hasShadow = false
            popup.level = .statusBar
            popup.hidesOnDeactivate = false
            popup.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            popup.contentView = NSHostingView(rootView: WorkoutsPopupView(model: healthModel))
            workoutsPanel = popup
        }

        healthModel.refresh()
        positionWorkoutsPopup()
        workoutsPanel?.orderFrontRegardless()
    }

    private func positionWorkoutsPopup() {
        guard let panel, let workoutsPanel else { return }
        let gap: CGFloat = 6
        // La card degli allenamenti è nel cluster di sinistra: la ancoriamo al
        // bordo sinistro della barra, così non deve inseguire la larghezza
        // variabile del calendario.
        let frame = NSRect(
            x: panel.frame.minX + 8,
            y: panel.frame.minY - workoutsPanel.frame.height - gap,
            width: workoutsPanel.frame.width,
            height: workoutsPanel.frame.height
        )
        workoutsPanel.setFrame(frame, display: true)
    }

    private func toggleWiFiPopup() {
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        guard let panel else { return }
        let anchorRight = panel.frame.maxX - Metrics.wifiIconRightInset
        sendNetworkPopupCommand("toggle \(anchorRight)")
    }

    private func toggleCalendarPopup() {
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendNetworkPopupCommand("hide")
        hideWeatherPopup()
        sendCalendarPopupCommand("toggle")
    }

    private func toggleWeatherPopup() {
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendNetworkPopupCommand("hide")
        sendCalendarPopupCommand("hide")

        guard let panel else { return }
        let anchorRight = panel.frame.maxX - Metrics.weatherRightInset
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sketchybar/plugins/weather_popup_toggle.sh")
        let process = Process()
        process.executableURL = scriptURL
        var environment = ProcessInfo.processInfo.environment
        environment["WEATHER_POPUP_ANCHOR_X"] = "\(anchorRight)"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    private func hideWeatherPopup() {
        let popupPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sketchybar/plugins/weather_popup").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "^\(popupPath)$"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    private func sendNetworkPopupCommand(_ command: String) {
        sendSocketCommand(command, socketPath: "/tmp/network_popup.sock")
    }

    private func sendCalendarPopupCommand(_ command: String) {
        sendSocketCommand(command, socketPath: "/tmp/calendar_notch.sock")
    }

    private func sendSocketCommand(_ command: String, socketPath: String) {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socketPath]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            input.fileHandleForWriting.write(Data("\(command)\n".utf8))
            input.fileHandleForWriting.closeFile()
        } catch {
            input.fileHandleForWriting.closeFile()
        }
    }

    private func closeComputePopupIfPointerIsOutside() {
        guard let panel, let computePanel, computePanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        if !panel.frame.contains(pointer) && !computePanel.frame.contains(pointer) {
            computePanel.orderOut(nil)
        }
    }

    private func closeWorkoutsPopupIfPointerIsOutside() {
        guard let panel, let workoutsPanel, workoutsPanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        if !panel.frame.contains(pointer) && !workoutsPanel.frame.contains(pointer) {
            workoutsPanel.orderOut(nil)
        }
    }

    private func positionPanel() {
        guard let panel, let screen = targetScreen() else { return }
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - Metrics.panelSize.height - Metrics.topMargin,
            width: screen.frame.width,
            height: Metrics.panelSize.height
        )
        panel.setFrame(frame, display: true)
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }
}

private let application = NSApplication.shared
private let delegate = BatteryBarApp()
application.delegate = delegate
application.run()
