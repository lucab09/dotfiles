import AppKit
import SwiftUI
import IOKit.ps
import CoreWLAN

private enum Metrics {
    /// Larghezza della colonna verticale sul bordo destro: yabai la tiene
    /// libera con `right_padding` = sidebarWidth + windowGap.
    static let sidebarWidth: CGFloat = 64
    /// Il gutter di yabai (`window_gap`/padding): sopra e sotto la colonna
    /// lasciamo lo stesso respiro che separa le finestre dai bordi.
    static let windowGap: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let iconWidth: CGFloat = 24
    static let circleSize: CGFloat = 38
    /// Distanza tra la colonna e i popup che si aprono alla sua sinistra.
    static let popupGap: CGFloat = 8
    /// Il popup si allinea poco sopra al punto cliccato, così il suo bordo
    /// superiore cade all'altezza del widget che l'ha aperto.
    static let popupAnchorLift: CGFloat = 24

    /// Font standard per i label testuali della barra.
    static let barLabel: Font = .system(size: 13, weight: .medium, design: .rounded)
    static let caption: Font = .system(size: 11, weight: .semibold, design: .rounded)
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
    /// RSSI in dBm, `nil` quando la scheda è spenta o non associata.
    let rssi: Int?

    static func read() -> WiFiSnapshot {
        guard
            let interface = CWWiFiClient.shared().interface(),
            interface.powerOn()
        else {
            return WiFiSnapshot(rssi: nil)
        }

        // `rssiValue()` vale 0 quando non c'è associazione a una rete.
        let rssi = interface.rssiValue()
        return WiFiSnapshot(rssi: rssi < 0 ? rssi : nil)
    }
}

/// Traduzione RSSI → tacche allineata all'icona Wi-Fi di sistema.
///
/// Le soglie precedenti (-60 / -75) erano più severe di quelle di macOS:
/// con un segnale intorno ai -65 dBm il menu di sistema mostra la tacca piena
/// mentre la barra ne disegnava due su tre. -67 dBm è la soglia classica
/// "buono per voce e video", ed è il punto in cui l'icona di sistema inizia a
/// scalare.
private enum WiFiSignal {
    static let fullThreshold = -67
    static let mediumThreshold = -78
    /// Si scende di tacca solo dopo aver superato la soglia di 3 dB: senza
    /// questo margine l'icona sfarfalla di continuo, perché l'RSSI oscilla di
    /// qualche dB anche stando fermi.
    static let hysteresis = 3

    static func level(rssi: Int, previous: Int) -> Int {
        func threshold(_ base: Int, keeping level: Int) -> Int {
            previous >= level ? base - hysteresis : base
        }
        if rssi >= threshold(fullThreshold, keeping: 3) { return 3 }
        if rssi >= threshold(mediumThreshold, keeping: 2) { return 2 }
        return 1
    }
}

private final class WiFiModel: ObservableObject {
    @Published private(set) var signalLevel = 0
    private var timer: Timer?
    /// Ultime letture grezze: la mediana scarta il singolo campione anomalo,
    /// che altrimenti terrebbe la tacca sbagliata per cinque secondi.
    private var samples: [Int] = []
    private let sampleWindow = 3

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
        guard let rssi = WiFiSnapshot.read().rssi else {
            samples.removeAll()
            signalLevel = 0
            return
        }

        samples.append(rssi)
        if samples.count > sampleWindow { samples.removeFirst() }
        let median = samples.sorted()[samples.count / 2]
        signalLevel = WiFiSignal.level(rssi: median, previous: signalLevel)
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
    /// L'orologio verticale impila ore e minuti: due righe corte stanno nella
    /// colonna meglio di un "HH:mm" schiacciato.
    @Published private(set) var hour = "--"
    @Published private(set) var minute = "--"
    /// "SAB", "12", "SET" e "2026" sotto l'ora, una riga ciascuno.
    @Published private(set) var weekday = "--"
    @Published private(set) var day = "--"
    @Published private(set) var month = "--"
    @Published private(set) var year = "----"
    private let hourFormatter: DateFormatter
    private let minuteFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter
    private let dayFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let yearFormatter: DateFormatter
    private var timer: Timer?

    init() {
        let locale = Locale(identifier: "it_IT")
        func make(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = format
            return formatter
        }
        hourFormatter = make("HH")
        minuteFormatter = make("mm")
        weekdayFormatter = make("EEE")
        dayFormatter = make("d")
        monthFormatter = make("MMM")
        yearFormatter = make("yyyy")
    }

    func start() {
        refresh()
        scheduleNextTick()
    }

    /// Un timer one-shot allineato al secondo :00 successivo: l'orologio
    /// cambia insieme al minuto di sistema e si riallinea da solo dopo uno
    /// sleep, invece di derivare come farebbe un intervallo fisso.
    private func scheduleNextTick() {
        timer?.invalidate()
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60)
        let timer = Timer(fireAt: nextMinute, interval: 0, target: self, selector: #selector(tick), userInfo: nil, repeats: false)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        refresh()
        scheduleNextTick()
    }

    @objc func refresh() {
        let now = Date()
        hour = hourFormatter.string(from: now)
        minute = minuteFormatter.string(from: now)
        weekday = weekdayFormatter.string(from: now).uppercased()
        day = dayFormatter.string(from: now)
        month = monthFormatter.string(from: now).uppercased()
        year = yearFormatter.string(from: now)
    }
}

private struct CalendarPayload: Decodable {
    let hasEvent: Bool
    let title: String?
    let color: String?
    let remainingMinutes: Int?
    let inProgress: Bool?
    let meetingURL: String?
    let endsInMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case title, color
        case hasEvent = "has_event"
        case remainingMinutes = "remaining_minutes"
        case inProgress = "in_progress"
        case meetingURL = "meeting_url"
        case endsInMinutes = "ends_in_minutes"
    }
}

private final class CalendarStatusModel: ObservableObject {
    @Published private(set) var hasEvent = false
    @Published private(set) var title = "Nessun evento"
    @Published private(set) var colorHex = "0xffcac4d0"
    @Published private(set) var remainingMinutes = 0
    @Published private(set) var inProgress = false
    @Published private(set) var hasMeetingLink = false
    @Published private(set) var meetingURL: URL?
    @Published private(set) var endsInMinutes: Int?
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
        meetingURL = (payload.meetingURL?.isEmpty == false) ? URL(string: payload.meetingURL!) : nil
        hasMeetingLink = meetingURL != nil
        endsInMinutes = payload.endsInMinutes
    }
}

/// Evento in primo piano in formato colonna: esagono col colore del
/// calendario e sotto il tempo che manca. Il titolo completo, che in
/// verticale non ci starebbe, resta nel tooltip e nel popup.
private struct CalendarStatusWidget: View {
    @ObservedObject var model: CalendarStatusModel
    private let neutral = Color(red: 0.79, green: 0.77, blue: 0.81)

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: model.hasEvent ? "hexagon.fill" : "hexagon")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.hasEvent ? eventColor : neutral.opacity(0.5))

            Text(shortLabel)
                .font(Metrics.caption)
                .monospacedDigit()
                .foregroundStyle(neutral)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: BarLayout.containerWidth)
        .padding(.vertical, 9)
        .barContainerBackground()
        .contentShape(Rectangle())
        .help(fullLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fullLabel)
    }

    private var duration: String {
        let minutes = model.remainingMinutes
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    private var shortLabel: String {
        guard model.hasEvent else { return "—" }
        if model.inProgress && model.hasMeetingLink { return "ora" }
        return duration
    }

    private var fullLabel: String {
        guard model.hasEvent else { return "Nessun evento" }
        if model.inProgress {
            return model.hasMeetingLink ? model.title : "\(model.title) · \(duration)"
        }
        return "\(model.title) · tra \(duration)"
    }

    private var eventColor: Color {
        calendarColor(fromHex: model.colorHex, fallback: neutral)
    }
}

/// Verde "stato ok" della barra: lo stesso di batteria carica, Wi-Fi pieno e
/// metriche di salute in range.
private let barGreen = Color(red: 0.65, green: 0.89, blue: 0.63)

/// Converte i colori scritti da calendar_notch ("0xffrrggbb" o "rrggbb").
private func calendarColor(fromHex hex: String, fallback: Color) -> Color {
    let raw = hex.lowercased().replacingOccurrences(of: "0x", with: "")
    let rgbString = raw.count == 8 ? String(raw.dropFirst(2)) : raw
    guard let value = UInt64(rgbString, radix: 16), rgbString.count == 6 else { return fallback }
    return Color(
        red: Double((value >> 16) & 0xff) / 255,
        green: Double((value >> 8) & 0xff) / 255,
        blue: Double(value & 0xff) / 255
    )
}

/// Pulsante "Partecipa" sotto l'evento: compare solo quando l'evento in
/// primo piano ha un link alla videochiamata (finestra gestita da
/// calendar_notch via `spotlightEvent`). In colonna diventa un cerchio con la
/// videocamera; a chiamata iniziata mostra i minuti alla fine. Usa il verde
/// di stato della barra, non il brand del provider: in mezzo a batteria e
/// Wi-Fi un verde Meet / blu Zoom / viola Teams stonava.
private struct CalendarJoinButton: View {
    @ObservedObject var model: CalendarStatusModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let endsIn {
                    Text("\(endsIn)m")
                        .font(Metrics.caption)
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(barGreen)
            .frame(width: Metrics.circleSize, height: Metrics.circleSize)
            .background(Circle().fill(barGreen.opacity(0.16)))
            .overlay(Circle().strokeBorder(barGreen.opacity(0.55), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var endsIn: Int? {
        model.inProgress ? model.endsInMinutes : nil
    }

    private var label: String {
        guard let endsIn else { return "Partecipa" }
        return "Termina tra \(endsIn)m"
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

/// Stato della pipeline vocale, scritto su /tmp da handy_task.sh e da
/// handy_capture.sh: la barra si limita a leggerlo.
private enum VoiceCaptureState: String {
    case idle
    case recording
    case processing
    case saved
}

private final class VoiceCaptureModel: ObservableObject {
    @Published private(set) var state: VoiceCaptureState = .idle
    private let stateURL = URL(fileURLWithPath: "/tmp/handy_capture_state")
    // Se il transcript è vuoto Handy non richiama l'hook esterno: senza queste
    // soglie l'icona resterebbe accesa per sempre in attesa di un task che non
    // arriverà mai.
    private static let recordingTimeout: TimeInterval = 300
    // Col modello in streaming la trascrizione avviene mentre parli: dopo lo
    // stop resta solo il flush finale, quindi 25s bastano con abbondanza.
    private static let processingTimeout: TimeInterval = 25
    private var refreshTimer: Timer?

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 0.4,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refresh() {
        guard let raw = try? String(contentsOf: stateURL, encoding: .utf8) else {
            if state != .idle { state = .idle }
            return
        }

        var next = VoiceCaptureState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .idle
        let timeout: TimeInterval? = {
            switch next {
            case .recording: return Self.recordingTimeout
            case .processing: return Self.processingTimeout
            case .idle, .saved: return nil
            }
        }()

        if let timeout,
           let modified = try? FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > timeout {
            next = .idle
        }

        if next != state { state = next }
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
        VStack(spacing: 10) {
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
        .frame(width: BarLayout.containerWidth)
        .padding(.vertical, 10)
        .barContainerBackground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func metric(icon: String, value: String?, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(value == nil ? Self.neutral.opacity(0.5) : color)

            Text(value ?? "--")
                .font(Metrics.barLabel)
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

        VStack(spacing: 3) {
            WorkoutMarkIcon(color: tint)
                .frame(width: 16, height: 16)

            Text(count.map { "\($0)" } ?? "--")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint)
        }
        .frame(width: Metrics.circleSize)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(Self.pill))
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            count.map { "\($0) allenamenti questa settimana" } ?? "Allenamenti non disponibili"
        )
    }
}

private struct VoiceCaptureIcon: View {
    let state: VoiceCaptureState

    private static let neutral = Color(red: 0.79, green: 0.77, blue: 0.81)
    private static let recording = Color(red: 0.96, green: 0.38, blue: 0.42)
    private static let processing = Color(red: 0.98, green: 0.78, blue: 0.35)
    private static let saved = Color(red: 0.55, green: 0.83, blue: 0.55)

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: state == .recording || state == .processing)
            .frame(width: Metrics.iconWidth, height: Metrics.iconWidth)
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        case .saved: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: return Self.neutral
        case .recording: return Self.recording
        case .processing: return Self.processing
        case .saved: return Self.saved
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Registra un task vocale"
        case .recording: return "Registrazione in corso, clicca per chiudere"
        case .processing: return "Trascrizione in corso"
        case .saved: return "Task creato"
        }
    }
}

/// Elemento di design system: cerchio con effetto vetro iOS.
/// Tre layer sovrapposti: blur material + velo bianco + bordo rim.
private struct BarCircle<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: Metrics.circleSize, height: Metrics.circleSize)
            .barGlass(Circle(), tint: tint == .clear ? nil : tint)
    }
}

/// Wi-Fi nel contenitore del design system: solo le tacche, colorate per
/// qualità del segnale. Il nome della rete sta nel popup.
private struct WiFiWidget: View {
    let signalLevel: Int

    var body: some View {
        BarContainer {
            WiFiSignalIcon(signalLevel: signalLevel)
                .frame(width: BarLayout.iconSize, height: BarLayout.iconSize)
        }
        .contentShape(RoundedRectangle(cornerRadius: BarLayout.containerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signalLevel == 0 ? "Wi-Fi non connesso" : "Segnale Wi-Fi livello \(signalLevel) di 3")
    }
}

/// Batteria nel contenitore del design system: icona col livello (colorata
/// per stato) e sotto la percentuale, col fulmine quando è in carica.
private struct BatteryWidget: View {
    @ObservedObject var model: BatteryModel
    @State private var animLevel: CGFloat = 0

    var body: some View {
        BarContainer(spacing: BarLayout.itemSpacing) {
            BatteryLevelIcon(level: animLevel, accent: statusColor)
                .frame(width: BarLayout.iconSize, height: BarLayout.iconSize)

            HStack(spacing: 2) {
                Text("\(model.percentage)")
                    .barText(.body)
                if model.isCharging {
                    ChargingBoltIcon(accent: statusColor)
                        .frame(width: BarLayout.accessoryIconSize, height: BarLayout.accessoryIconSize)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.isCharging
                ? "Batteria \(model.percentage) percento, in carica"
                : "Batteria \(model.percentage) percento"
        )
        .onAppear {
            animLevel = CGFloat(model.percentage) / 100
            if model.isCharging { startChargingAnimation() }
        }
        .onChange(of: model.isCharging) { _, isCharging in
            isCharging ? startChargingAnimation() : stopChargingAnimation()
        }
        .onChange(of: model.percentage) { _, _ in
            if !model.isCharging {
                withAnimation(.easeInOut(duration: 0.65)) {
                    animLevel = CGFloat(model.percentage) / 100
                }
            }
        }
    }

    private func startChargingAnimation() {
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            animLevel = 1.0
        }
    }

    private func stopChargingAnimation() {
        withAnimation(.easeInOut(duration: 0.65)) {
            animLevel = CGFloat(model.percentage) / 100
        }
    }

    private var statusColor: Color {
        switch model.percentage {
        case ..<20: return BarTheme.Status.critical
        case ...75: return BarTheme.Status.warning
        default: return BarTheme.Status.good
        }
    }
}

/// Meteo nel contenitore del design system, come la batteria: icona della
/// condizione (colorata) e sotto la temperatura; la città sta nel tooltip.
private struct WeatherWidget: View {
    @ObservedObject var model: WeatherStatusModel

    var body: some View {
        BarContainer(spacing: BarLayout.itemSpacing) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(conditionColor)
                .frame(width: BarLayout.iconSize, height: BarLayout.iconSize)

            Text(temperatureLabel)
                .barText(.body)
        }
        .contentShape(RoundedRectangle(cornerRadius: BarLayout.containerRadius, style: .continuous))
        .help(model.city == "--" ? temperatureLabel : "\(temperatureLabel) \(model.city)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meteo, \(temperatureLabel), \(model.city)")
    }

    private var temperatureLabel: String {
        model.temperature.map { "\(Int($0.rounded()))°" } ?? "--°"
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
        case "sunny", "partly_cloudy_day": return BarTheme.Weather.sun
        case "bedtime", "partly_cloudy_night": return BarTheme.Weather.night
        case "rainy", "weather_mix": return BarTheme.Weather.rain
        case "weather_snowy", "cloudy_snowing": return BarTheme.Weather.snow
        case "thunderstorm": return BarTheme.Weather.storm
        default: return BarTheme.Weather.cloud
        }
    }
}

/// Orologio in cima alla colonna: ore e minuti impilati in stile display,
/// sotto giorno della settimana, numero, mese e anno in stile body.
private struct ClockWidget: View {
    @ObservedObject var model: DateTimeModel

    var body: some View {
        BarContainer {
            Text(model.hour).barText(.display)
            Text(model.minute).barText(.display)

            BarDivider()

            Text(model.weekday).barText(.body)
            Text(model.day).barText(.body)
            Text(model.month).barText(.body)
            Text(model.year).barText(.body)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.hour):\(model.minute), \(model.weekday) \(model.day) \(model.month) \(model.year)")
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

/// Fulmine "in carica": stesso tracciato dell'icona SVG 24×24, ridisegnato
/// come Path per restare nitido accanto al valore della batteria.
private struct ChargingBoltIcon: View {
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 24
            let sy = size.height / 24
            let stroke = StrokeStyle(
                lineWidth: 1.5 * sx,
                lineCap: .round,
                lineJoin: .round
            )

            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * sx, y: y * sy)
            }

            var bolt = Path()
            bolt.move(to: p(5.22576, 11.3294))
            bolt.addLine(to: p(12.224, 2.34651))
            bolt.addCurve(to: p(13.7972, 3.01707),
                          control1: p(12.7713, 1.64397), control2: p(13.7972, 2.08124))
            bolt.addLine(to: p(13.7972, 9.96994))
            bolt.addCurve(to: p(14.6958, 10.985),
                          control1: p(13.7972, 10.5305), control2: p(14.1995, 10.985))
            bolt.addLine(to: p(18.0996, 10.985))
            bolt.addCurve(to: p(18.7742, 12.6706),
                          control1: p(18.8729, 10.985), control2: p(19.2851, 12.0149))
            bolt.addLine(to: p(11.776, 21.6535))
            bolt.addCurve(to: p(10.2028, 20.9829),
                          control1: p(11.2287, 22.356), control2: p(10.2028, 21.9188))
            bolt.addLine(to: p(10.2028, 14.0301))
            bolt.addCurve(to: p(9.3042, 13.015),
                          control1: p(10.2028, 13.4695), control2: p(9.80048, 13.015))
            bolt.addLine(to: p(5.90035, 13.015))
            bolt.addCurve(to: p(5.22576, 11.3294),
                          control1: p(5.12711, 13.015), control2: p(4.71494, 11.9851))
            bolt.closeSubpath()

            context.fill(bolt, with: .color(accent.opacity(0.82)))
            context.stroke(bolt, with: .color(accent), style: stroke)
        }
    }
}

private struct WiFiSignalIcon: View {
    let signalLevel: Int

    private var statusColor: Color {
        switch signalLevel {
        case 3: return BarTheme.Status.good
        case 2: return BarTheme.Status.warning
        case 1: return BarTheme.Status.critical
        default: return BarTheme.Status.neutral
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
    @ObservedObject var voiceCaptureModel: VoiceCaptureModel
    let onComputeClick: () -> Void
    let onWiFiClick: () -> Void
    let onCalendarClick: () -> Void
    let onCalendarJoinClick: () -> Void
    let onWeatherClick: () -> Void
    let onWorkoutsClick: () -> Void
    let onVoiceCaptureClick: () -> Void

    /// Colonna sul bordo destro: in alto l'orologio e le informazioni della
    /// giornata (agenda, salute, allenamenti, nota vocale), in fondo lo stato
    /// del sistema. Lo Spacer in mezzo tiene i due gruppi ai capi opposti,
    /// così lo sguardo trova l'ora sempre nello stesso angolo.
    var body: some View {
        VStack(spacing: Metrics.sectionSpacing) {
            ClockWidget(model: dateTimeModel)

            Button(action: onCalendarClick) {
                CalendarStatusWidget(model: calendarModel)
            }
            .buttonStyle(.plain)

            if calendarModel.hasMeetingLink {
                CalendarJoinButton(model: calendarModel, action: onCalendarJoinClick)
            }

            HealthStatusWidget(model: healthModel)

            Button(action: onWorkoutsClick) {
                WeeklyWorkoutsIcon(count: healthModel.weeklyWorkoutCount)
            }
            .buttonStyle(.plain)

            Button(action: onVoiceCaptureClick) {
                BarCircle {
                    VoiceCaptureIcon(state: voiceCaptureModel.state)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: Metrics.sectionSpacing)

            Button(action: onWeatherClick) {
                WeatherWidget(model: weatherModel)
            }
            .buttonStyle(.plain)

            BatteryWidget(model: batteryModel)

            Button(action: onWiFiClick) {
                WiFiWidget(signalLevel: wifiModel.signalLevel)
            }
            .buttonStyle(.plain)

            Button(action: onComputeClick) {
                BarCircle {
                    ComputeIcon()
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Metrics.windowGap)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: calendarModel.hasMeetingLink)
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
    private let voiceCaptureModel = VoiceCaptureModel()
    /// Un pannello per schermo, indicizzato sul display ID: la barra deve
    /// comparire su tutti i monitor, non solo su quello col notch.
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    /// Barra su cui è avvenuto l'ultimo click: i popup si ancorano a quella,
    /// così si aprono sullo schermo con cui l'utente sta interagendo.
    private weak var activeBarPanel: NSPanel?
    /// Altezza del puntatore all'ultimo click sulla colonna: i popup si
    /// aprono alla sua sinistra, allineati al widget che li ha richiesti.
    private var popupAnchorY: CGFloat?
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
        voiceCaptureModel.start()

        rebuildPanels()

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
        rebuildPanels()
        positionComputePopup()
        positionWorkoutsPopup()
    }

    private func toggleComputePopup() {
        updateActiveBarPanel()
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
        guard let panel = anchorPanel, let computePanel else { return }
        computePanel.setFrame(popupFrame(size: computePanel.frame.size, beside: panel), display: true)
    }

    private func toggleWorkoutsPopup() {
        updateActiveBarPanel()
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
        guard let panel = anchorPanel, let workoutsPanel else { return }
        workoutsPanel.setFrame(popupFrame(size: workoutsPanel.frame.size, beside: panel), display: true)
    }

    private func toggleWiFiPopup() {
        updateActiveBarPanel()
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendCalendarPopupCommand("hide")
        hideWeatherPopup()
        guard let panel = anchorPanel else { return }
        sendNetworkPopupCommand("toggle \(popupRightEdge(of: panel)) \(popupTop(in: panel))")
    }

    /// Apre il link alla videochiamata dell'evento in primo piano. Chiude prima
    /// l'agenda: restare aperta sopra la finestra della call è solo d'intralcio.
    private func joinCurrentMeeting() {
        guard let url = calendarModel.meetingURL else { return }
        sendCalendarPopupCommand("hide")
        NSWorkspace.shared.open(url)
    }

    private func toggleCalendarPopup() {
        updateActiveBarPanel()
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendNetworkPopupCommand("hide")
        hideWeatherPopup()
        guard let panel = anchorPanel else { return }
        // Bordo destro e bordo superiore del popup: calendar_notch lo tiene
        // dentro lo schermo se l'agenda è più alta dello spazio disponibile.
        sendCalendarPopupCommand("toggle \(popupRightEdge(of: panel)) \(popupTop(in: panel))")
    }

    private func toggleWeatherPopup() {
        updateActiveBarPanel()
        computePanel?.orderOut(nil)
        workoutsPanel?.orderOut(nil)
        sendNetworkPopupCommand("hide")
        sendCalendarPopupCommand("hide")

        guard let panel = anchorPanel else { return }
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sketchybar/plugins/weather_popup_toggle.sh")
        let process = Process()
        process.executableURL = scriptURL
        var environment = ProcessInfo.processInfo.environment
        environment["WEATHER_POPUP_ANCHOR_X"] = "\(popupRightEdge(of: panel))"
        environment["WEATHER_POPUP_ANCHOR_Y"] = "\(popupTop(in: panel))"
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

    /// Delega tutto a handy_task.sh: la barra non conosce né Handy né il DB dei
    /// task, così la stessa logica resta riusabile da una shortcut da tastiera.
    private func toggleVoiceCapture() {
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sketchybar/plugins/handy_task.sh")
        let process = Process()
        process.executableURL = scriptURL
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        // Il file di stato viene scritto dallo script: anticipiamo la lettura
        // per non aspettare il tick del timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.voiceCaptureModel.refresh()
        }
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
        guard let panel = anchorPanel, let computePanel, computePanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        if !panel.frame.contains(pointer) && !computePanel.frame.contains(pointer) {
            computePanel.orderOut(nil)
        }
    }

    private func closeWorkoutsPopupIfPointerIsOutside() {
        guard let panel = anchorPanel, let workoutsPanel, workoutsPanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        if !panel.frame.contains(pointer) && !workoutsPanel.frame.contains(pointer) {
            workoutsPanel.orderOut(nil)
        }
    }

    /// I popup si aprono a sinistra della colonna: questo è il loro bordo
    /// destro, per quelli ancorati in processi separati (rete, meteo, agenda).
    private func popupRightEdge(of panel: NSPanel) -> CGFloat {
        panel.frame.minX - Metrics.popupGap
    }

    /// Bordo superiore desiderato per un popup: poco sopra al click, così la
    /// card parte all'altezza del widget. Chi conosce l'altezza del proprio
    /// popup la usa per restare dentro lo schermo (`popupFrame`).
    private func popupTop(in panel: NSPanel) -> CGFloat {
        let pointerY = popupAnchorY ?? panel.frame.maxY
        return min(pointerY + Metrics.popupAnchorLift, panel.frame.maxY - Metrics.windowGap)
    }

    private func popupFrame(size: NSSize, beside panel: NSPanel) -> NSRect {
        let bottomLimit = panel.frame.minY + Metrics.windowGap
        let top = max(popupTop(in: panel), bottomLimit + size.height)
        return NSRect(
            x: popupRightEdge(of: panel) - size.width,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func makeBarPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: barFrame(for: NSScreen.main ?? NSScreen.screens[0]),
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
        // Tutte le copie condividono gli stessi model: il contenuto resta
        // allineato su ogni schermo senza duplicare timer o letture di sistema.
        panel.contentView = NSHostingView(
            rootView: BatteryBarView(
                batteryModel: batteryModel,
                wifiModel: wifiModel,
                dateTimeModel: dateTimeModel,
                calendarModel: calendarModel,
                weatherModel: weatherModel,
                healthModel: healthModel,
                voiceCaptureModel: voiceCaptureModel,
                onComputeClick: { [weak self] in self?.toggleComputePopup() },
                onWiFiClick: { [weak self] in self?.toggleWiFiPopup() },
                onCalendarClick: { [weak self] in self?.toggleCalendarPopup() },
                onCalendarJoinClick: { [weak self] in self?.joinCurrentMeeting() },
                onWeatherClick: { [weak self] in self?.toggleWeatherPopup() },
                onWorkoutsClick: { [weak self] in self?.toggleWorkoutsPopup() },
                onVoiceCaptureClick: { [weak self] in self?.toggleVoiceCapture() }
            )
        )
        return panel
    }

    /// Allinea l'insieme dei pannelli agli schermi collegati: riusa quelli già
    /// esistenti, ne crea per i monitor nuovi e chiude quelli rimasti orfani
    /// dopo lo scollegamento di un display.
    private func rebuildPanels() {
        var live: [CGDirectDisplayID: NSPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen) else { continue }
            let panel = panels[id] ?? makeBarPanel()
            panel.setFrame(barFrame(for: screen), display: true)
            panel.orderFrontRegardless()
            live[id] = panel
        }
        for (id, panel) in panels where live[id] == nil {
            if activeBarPanel === panel { activeBarPanel = nil }
            panel.orderOut(nil)
        }
        panels = live
    }

    /// Colonna a tutta altezza aderente al bordo destro. Lo schermo intero e
    /// non il `visibleFrame`: menu bar e Dock sono nascosti, e la colonna
    /// deve restare ferma quando compaiono.
    private func barFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.maxX - Metrics.sidebarWidth,
            y: screen.frame.minY,
            width: Metrics.sidebarWidth,
            height: screen.frame.height
        )
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// La barra a cui ancorare i popup: quella cliccata per ultima, altrimenti
    /// quella dello schermo attivo.
    private var anchorPanel: NSPanel? {
        if let activeBarPanel { return activeBarPanel }
        if let main = NSScreen.main, let id = displayID(of: main), let panel = panels[id] { return panel }
        for screen in NSScreen.screens {
            if let id = displayID(of: screen), let panel = panels[id] { return panel }
        }
        return nil
    }

    /// Il click su un'icona arriva sempre dalla barra sotto al puntatore.
    private func updateActiveBarPanel() {
        let pointer = NSEvent.mouseLocation
        if let panel = panels.values.first(where: { $0.frame.contains(pointer) }) {
            activeBarPanel = panel
            popupAnchorY = pointer.y
        }
    }
}

private let application = NSApplication.shared
private let delegate = BatteryBarApp()
application.delegate = delegate
application.run()
