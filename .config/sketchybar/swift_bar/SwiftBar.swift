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
    static let iconWidth: CGFloat = 24
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

    static func read() -> ComputeSnapshot {
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
            guard values.count == 3 else { return ComputeSnapshot(cpu: 0, gpu: 0, ram: 0) }
            return ComputeSnapshot(
                cpu: min(max(values[0], 0), 100),
                gpu: min(max(values[1], 0), 100),
                ram: min(max(values[2], 0), 100)
            )
        } catch {
            return ComputeSnapshot(cpu: 0, gpu: 0, ram: 0)
        }
    }
}

private final class ComputeModel: ObservableObject {
    @Published private(set) var cpu = 0
    @Published private(set) var gpu = 0
    @Published private(set) var ram = 0
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
        if model.inProgress {
            return model.hasMeetingLink ? model.title : "\(model.title) · \(duration)"
        }
        return "\(model.title) · tra \(duration)"
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

private struct ComputePopupView: View {
    @ObservedObject var model: ComputeModel

    var body: some View {
        VStack(spacing: 0) {
            statusRow("CPU", value: model.cpu)
            Divider().overlay(Color.white.opacity(0.07))
            statusRow("GPU", value: model.gpu)
            Divider().overlay(Color.white.opacity(0.07))
            statusRow("RAM", value: model.ram)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.135, green: 0.135, blue: 0.145))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
        .padding(1)
    }

    private func statusRow(_ name: String, value: Int) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.79, green: 0.77, blue: 0.81))
            Spacer()
            Text("\(value)%")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 1.00, green: 0.61, blue: 0.39))
        }
        .frame(height: 30)
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
    let onComputeClick: () -> Void
    let onWiFiClick: () -> Void
    let onCalendarClick: () -> Void
    let onWeatherClick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onCalendarClick) {
                CalendarStatusWidget(model: calendarModel)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .buttonStyle(.plain)

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
    private var panel: NSPanel?
    private var computePanel: NSPanel?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryModel.start()
        wifiModel.start()
        computeModel.start()
        dateTimeModel.start()
        calendarModel.start()
        weatherModel.start()

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
                onComputeClick: { [weak self] in self?.toggleComputePopup() },
                onWiFiClick: { [weak self] in self?.toggleWiFiPopup() },
                onCalendarClick: { [weak self] in self?.toggleCalendarPopup() },
                onWeatherClick: { [weak self] in self?.toggleWeatherPopup() }
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

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.closeComputePopupIfPointerIsOutside() }
        }
    }

    @objc private func screenConfigurationChanged() {
        positionPanel()
        positionComputePopup()
    }

    private func toggleComputePopup() {
        sendNetworkPopupCommand("hide")
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        if computePanel?.isVisible == true {
            computePanel?.orderOut(nil)
            return
        }

        if computePanel == nil {
            let size = NSSize(width: 178, height: 111)
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

    private func toggleWiFiPopup() {
        computePanel?.orderOut(nil)
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        guard let panel else { return }
        let anchorRight = panel.frame.maxX - Metrics.wifiIconRightInset
        sendNetworkPopupCommand("toggle \(anchorRight)")
    }

    private func toggleCalendarPopup() {
        computePanel?.orderOut(nil)
        sendNetworkPopupCommand("hide")
        hideWeatherPopup()
        sendCalendarPopupCommand("toggle")
    }

    private func toggleWeatherPopup() {
        computePanel?.orderOut(nil)
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
