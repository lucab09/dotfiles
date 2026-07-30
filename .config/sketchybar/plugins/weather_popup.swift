import Cocoa
import SwiftUI

private let stateURL = URL(fileURLWithPath: "/tmp/sketchybar_weather_state.json")
private let panelBlack = Color.black
private let surface = Color(red: 31 / 255, green: 31 / 255, blue: 34 / 255)
private let surfaceHover = Color(red: 47 / 255, green: 47 / 255, blue: 51 / 255)
private let primaryText = Color(red: 245 / 255, green: 242 / 255, blue: 247 / 255)
private let secondaryText = Color(red: 202 / 255, green: 196 / 255, blue: 208 / 255)
private let subtleText = Color(red: 145 / 255, green: 140 / 255, blue: 151 / 255)
private let accent = Color(red: 255 / 255, green: 64 / 255, blue: 73 / 255)

struct WeatherState: Decodable {
    let city: String?
    let temperature: Double?
    let apparentTemperature: Double?
    let condition: String?
    let icon: String?
    let humidity: Int?
    let windSpeed: Double?
    let windGusts: Double?
    let windDirection: String?
    let pressure: Int?
    let cloudCover: Int?
    let precipitation: Double?
    let tempMax: Double?
    let tempMin: Double?
    let precipitationProbability: Int?
    let uvIndex: Double?
    let sunrise: String?
    let sunset: String?
    let aqi: Int?
    let aqiColor: String?
    let pm10: Double?
    let pm25: Double?
    let nitrogenDioxide: Double?
    let ozone: Double?
    let grassPollen: Double?
    let birchPollen: Double?
    let olivePollen: Double?

    enum CodingKeys: String, CodingKey {
        case city, temperature, condition, icon, humidity, pressure, precipitation, sunrise, sunset, aqi, ozone
        case apparentTemperature = "apparent_temperature"
        case windSpeed = "wind_speed"
        case windGusts = "wind_gusts"
        case windDirection = "wind_direction"
        case cloudCover = "cloud_cover"
        case tempMax = "temp_max"
        case tempMin = "temp_min"
        case precipitationProbability = "precipitation_probability"
        case uvIndex = "uv_index"
        case aqiColor = "aqi_color"
        case pm10
        case pm25 = "pm2_5"
        case nitrogenDioxide = "nitrogen_dioxide"
        case grassPollen = "grass_pollen"
        case birchPollen = "birch_pollen"
        case olivePollen = "olive_pollen"
    }

    static func load() -> WeatherState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(WeatherState.self, from: data)
    }
}

final class WeatherPopupApp: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var hoverTimer: Timer?
    private var anchorRect: NSRect = .zero
    private var launchedAt = Date()
    private var didEnterPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        showPanel()
    }

    private func showPanel() {
        let state = WeatherState.load()
        let content = WeatherPopupView(state: state)
        let size = NSSize(width: 392, height: 404)
        let launchMouse = NSEvent.mouseLocation
        anchorRect = NSRect(x: launchMouse.x - 130, y: launchMouse.y - 30, width: 260, height: 70)
        launchedAt = Date()
        let frame = panelFrame(size: size, mouse: launchMouse)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        panel.orderFrontRegardless()
        self.panel = panel

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.closeIfMouseLeftHoverArea()
        }
    }

    private func panelFrame(size: NSSize, mouse: CGPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(frame.minX + 18, mouse.x - 72), frame.maxX - size.width - 18)
        let y = frame.maxY - size.height - 46
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func closeIfMouseLeftHoverArea() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let panelFrame = panel.frame.insetBy(dx: -8, dy: -8)
        if panelFrame.contains(mouse) {
            didEnterPanel = true
            return
        }

        if didEnterPanel {
            close()
            return
        }

        let gracePeriod: TimeInterval = 0.9
        if Date().timeIntervalSince(launchedAt) > gracePeriod && !anchorRect.contains(mouse) {
            close()
        }
    }

    private func close() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel?.close()
        NSApp.terminate(nil)
    }
}

struct WeatherConditionIcon: View {
    let name: String?

    private var conditionColor: Color {
        switch name {
        case "sunny":
            return Color(red: 255/255, green: 204/255, blue: 77/255)
        case "partly_cloudy_day":
            return Color(red: 255/255, green: 209/255, blue: 102/255)
        case "bedtime", "partly_cloudy_night":
            return Color(red: 183/255, green: 194/255, blue: 255/255)
        case "rainy", "weather_mix":
            return Color(red: 128/255, green: 222/255, blue: 255/255)
        case "weather_snowy", "cloudy_snowing":
            return Color(red: 185/255, green: 235/255, blue: 255/255)
        case "foggy":
            return Color(red: 202/255, green: 196/255, blue: 208/255)
        case "thunderstorm":
            return Color(red: 190/255, green: 145/255, blue: 255/255)
        default:
            return Color(red: 202/255, green: 196/255, blue: 208/255)
        }
    }

    var body: some View {
        if name == "sunny" {
            SunGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "weather_snowy" || name == "cloudy_snowing" {
            SnowGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "rainy" || name == "weather_mix" {
            RainGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "cloud" {
            CloudGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineJoin: .round))
        } else if name == "partly_cloudy_day" || name == "partly_cloudy_night" {
            PartlyCloudyGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "foggy" {
            FogGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "thunderstorm" {
            ThunderstormGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else if name == "bedtime" {
            MoonGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        } else {
            CloudGlyph()
                .stroke(conditionColor, style: StrokeStyle(lineWidth: 1.65, lineJoin: .round))
        }
    }

    private struct SunGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            let xOffset = rect.midX - 12 * scale
            let yOffset = rect.midY - 12 * scale
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }

            var path = Path()
            path.addEllipse(in: CGRect(x: xOffset + 6 * scale, y: yOffset + 6 * scale, width: 12 * scale, height: 12 * scale))
            path.move(to: point(22, 12)); path.addLine(to: point(23, 12))
            path.move(to: point(12, 2)); path.addLine(to: point(12, 1))
            path.move(to: point(12, 23)); path.addLine(to: point(12, 22))
            path.move(to: point(20, 20)); path.addLine(to: point(19, 19))
            path.move(to: point(20, 4)); path.addLine(to: point(19, 5))
            path.move(to: point(4, 20)); path.addLine(to: point(5, 19))
            path.move(to: point(4, 4)); path.addLine(to: point(5, 5))
            path.move(to: point(1, 12)); path.addLine(to: point(2, 12))
            return path
        }
    }

    private struct SnowGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            let xOffset = rect.midX - 12 * scale
            let yOffset = rect.midY - 12 * scale
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }
            func line(_ path: inout Path, _ a: CGPoint, _ b: CGPoint) {
                path.move(to: a)
                path.addLine(to: b)
            }

            var path = Path()
            line(&path, point(3, 7), point(6.5, 9))
            line(&path, point(21, 17), point(17.5, 15))
            line(&path, point(12, 12), point(6.5, 9))
            line(&path, point(12, 12), point(6.5, 15))
            line(&path, point(12, 12), point(12, 5))
            line(&path, point(12, 12), point(12, 18.5))
            line(&path, point(12, 12), point(17.5, 15))
            line(&path, point(12, 12), point(17.5, 9))
            line(&path, point(12, 2), point(12, 5))
            line(&path, point(12, 22), point(12, 18.5))
            line(&path, point(21, 7), point(17.5, 9))
            line(&path, point(3, 17), point(6.5, 15))
            line(&path, point(6.5, 9), point(3, 10))
            line(&path, point(6.5, 9), point(6, 5.5))
            line(&path, point(6.5, 15), point(3, 14))
            line(&path, point(6.5, 15), point(6, 18.5))
            line(&path, point(12, 5), point(9.5, 4))
            line(&path, point(12, 5), point(14.5, 4))
            line(&path, point(12, 18.5), point(14.5, 20))
            line(&path, point(12, 18.5), point(9.5, 20))
            line(&path, point(17.5, 15), point(18, 18.5))
            line(&path, point(17.5, 15), point(21, 14))
            line(&path, point(17.5, 9), point(21, 10))
            line(&path, point(17.5, 9), point(18, 5.5))
            return path
        }
    }

    private struct RainGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            p.line(&path, 12, 14, 12, 16)
            p.line(&path, 12, 20, 12, 22)
            p.line(&path, 8, 18, 8, 20)
            p.line(&path, 16, 18, 16, 20)
            p.addCloudTop(to: &path, leftEndY: 17.6073, rightStartY: 17.6073)
            return path
        }
    }

    private struct CloudGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            path.move(to: p.point(12, 4))
            path.addCurve(to: p.point(6, 10), control1: p.point(6, 4), control2: p.point(6, 8))
            path.addCurve(to: p.point(1, 15), control1: p.point(4.33333, 10), control2: p.point(1, 11))
            path.addCurve(to: p.point(6, 20), control1: p.point(1, 19), control2: p.point(4.33333, 20))
            path.addLine(to: p.point(18, 20))
            path.addCurve(to: p.point(23, 15), control1: p.point(19.6667, 20), control2: p.point(23, 19))
            path.addCurve(to: p.point(18, 10), control1: p.point(23, 11), control2: p.point(19.6667, 10))
            path.addCurve(to: p.point(12, 4), control1: p.point(18, 8), control2: p.point(18, 4))
            path.closeSubpath()
            return path
        }
    }

    private struct PartlyCloudyGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            path.move(to: p.point(6, 13))
            path.addCurve(to: p.point(1, 18), control1: p.point(4.33333, 13), control2: p.point(1, 14))
            path.addCurve(to: p.point(6, 23), control1: p.point(1, 22), control2: p.point(4.33333, 23))
            path.addLine(to: p.point(18, 23))
            path.addCurve(to: p.point(23, 18), control1: p.point(19.6667, 23), control2: p.point(23, 22))
            path.addCurve(to: p.point(18, 13), control1: p.point(23, 14), control2: p.point(19.6667, 13))
            path.addEllipse(in: p.rect(x: 9, y: 6, width: 6, height: 6))
            p.line(&path, 19, 9, 20, 9)
            p.line(&path, 12, 2, 12, 1)
            p.line(&path, 18.5, 3.5, 17.5, 4.5)
            p.line(&path, 5.5, 3.5, 6.5, 4.5)
            p.line(&path, 4, 9, 5, 9)
            return path
        }
    }

    private struct FogGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            p.line(&path, 9, 14, 15, 14)
            p.line(&path, 9, 22, 15, 22)
            p.line(&path, 7, 18, 17, 18)
            path.move(to: p.point(3.5, 17.3818))
            path.addCurve(to: p.point(1, 13), control1: p.point(2.1879, 16.7066), control2: p.point(1, 15.3879))
            path.addCurve(to: p.point(6, 8), control1: p.point(1, 9), control2: p.point(4.33333, 8))
            path.addCurve(to: p.point(12, 2), control1: p.point(6, 6), control2: p.point(6, 2))
            path.addCurve(to: p.point(18, 8), control1: p.point(18, 2), control2: p.point(18, 6))
            path.addCurve(to: p.point(23, 13), control1: p.point(19.6667, 8), control2: p.point(23, 9))
            path.addCurve(to: p.point(20.5, 17.3818), control1: p.point(23, 15.3879), control2: p.point(21.8121, 16.7066))
            return path
        }
    }

    private struct ThunderstormGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            path.move(to: p.point(11.5, 12))
            path.addLine(to: p.point(9, 17))
            path.addLine(to: p.point(15, 17))
            path.addLine(to: p.point(12.5, 22))
            p.addCloudTop(to: &path, leftEndY: 17.6073, rightStartY: 17.6073)
            return path
        }
    }

    private struct MoonGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let p = WeatherGlyphPointMapper(rect: rect)
            path.move(to: p.point(3, 11.5066))
            path.addCurve(to: p.point(12.4934, 21), control1: p.point(3, 16.7497), control2: p.point(7.25034, 21))
            path.addCurve(to: p.point(21, 15.7259), control1: p.point(16.2209, 21), control2: p.point(19.4466, 18.8518))
            path.addCurve(to: p.point(8.27411, 3), control1: p.point(12.4934, 15.7259), control2: p.point(8.27411, 11.5066))
            path.addCurve(to: p.point(3, 11.5066), control1: p.point(5.14821, 4.55344), control2: p.point(3, 7.77915))
            path.closeSubpath()
            return path
        }
    }

    private struct WeatherGlyphPointMapper {
        let scale: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat

        init(rect: CGRect) {
            scale = min(rect.width, rect.height) / 24
            xOffset = rect.midX - 12 * scale
            yOffset = rect.midY - 12 * scale
        }

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
        }

        func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: xOffset + x * scale, y: yOffset + y * scale, width: width * scale, height: height * scale)
        }

        func line(_ path: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: point(x1, y1))
            path.addLine(to: point(x2, y2))
        }

        func addCloudTop(to path: inout Path, leftEndY: CGFloat, rightStartY: CGFloat) {
            path.move(to: point(20, rightStartY))
            path.addCurve(to: point(23, 13), control1: point(21.4937, 17.0221), control2: point(23, 15.6889))
            path.addCurve(to: point(18, 8), control1: point(23, 9), control2: point(19.6667, 8))
            path.addCurve(to: point(12, 2), control1: point(18, 6), control2: point(18, 2))
            path.addCurve(to: point(6, 8), control1: point(6, 2), control2: point(6, 6))
            path.addCurve(to: point(1, 13), control1: point(4.33333, 8), control2: point(1, 9))
            path.addCurve(to: point(4, leftEndY), control1: point(1, 15.6889), control2: point(2.50628, 17.0221))
        }
    }
}

struct WeatherPopupView: View {
    let state: WeatherState?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let state {
                metricGrid(state)
            } else {
                emptyState
            }
        }
        .padding(18)
        .frame(width: 392, height: 404, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(panelBlack.opacity(0.96))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            WeatherConditionIcon(name: state?.icon)
                .frame(width: 42, height: 42)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(state?.city?.isEmpty == false ? state!.city! : "Meteo")
                    .font(.custom("Google Sans Flex 18pt", size: 20))
                    .fontWeight(.semibold)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(state?.condition ?? "Dati non disponibili")
                    .font(.custom("Google Sans Flex 18pt", size: 12))
                    .foregroundStyle(secondaryText)
            }

            Spacer()

            if let temp = state?.temperature {
                Text("\(format(temp))°")
                    .font(.custom("Google Sans Flex 18pt", size: 32))
                    .fontWeight(.semibold)
                    .foregroundStyle(primaryText)
            }
        }
    }

    private func metricGrid(_ state: WeatherState) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            metric(
                "Percepita",
                value: degrees(state.apparentTemperature),
                icon: "thermometer.medium",
                gradient: apparentTemperatureGradient(state.apparentTemperature ?? state.temperature)
            )
            metric("Min / Max", value: minMax(state), icon: "arrow.up.and.down")
            metric("Pioggia", value: rain(state), icon: "cloud.rain", gradient: rainGradient(state))
            metric("Vento", value: wind(state), icon: "wind")
            metric("Umidità", value: percent(state.humidity), icon: "humidity")
            metric("UV", value: uv(state.uvIndex), icon: "sun.max")
            metric("Pressione", value: state.pressure.map { "\($0) hPa" } ?? "--", icon: "gauge.with.dots.needle.bottom.50percent")
            metric("Nuvole", value: percent(state.cloudCover), icon: "cloud")
            metric("PM2.5", value: micrograms(state.pm25), icon: "aqi.medium", gradient: pm25Gradient(state.pm25))
            metric("PM10", value: micrograms(state.pm10), icon: "aqi.medium")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud.slash")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(secondaryText)
            Text("Dati meteo non disponibili")
                .font(.custom("Google Sans Flex 18pt", size: 15))
                .fontWeight(.semibold)
                .foregroundStyle(primaryText)
            Text("Aspetta il prossimo aggiornamento di SketchyBar.")
                .font(.custom("Google Sans Flex 18pt", size: 12))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metric(_ title: String, value: String, icon: String, gradient: LinearGradient? = nil) -> some View {
        let isColored = gradient != nil
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isColored ? Color.white.opacity(0.86) : secondaryText)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("Google Sans Flex 18pt", size: 10))
                    .fontWeight(.semibold)
                    .foregroundStyle(isColored ? Color.white.opacity(0.68) : subtleText)
                Text(value)
                    .font(.custom("Google Sans Flex 18pt", size: 13))
                    .fontWeight(.semibold)
                    .foregroundStyle(isColored ? Color.white : primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surface)
            if let gradient {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(gradient)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.16))
            }
        }
        .overlay {
            if isColored {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func apparentTemperatureGradient(_ value: Double?) -> LinearGradient? {
        guard let value else { return nil }
        let clamped = min(42, max(-6, value))
        let normalized = (clamped + 6) / 48
        let thermalHue = 0.60 - normalized * 0.58 // freddo blu → caldo rosso
        let complementHue = (thermalHue + 0.50).truncatingRemainder(dividingBy: 1)
        let thermal = Color(hue: thermalHue, saturation: 0.72, brightness: 0.96)
        let complement = Color(hue: complementHue, saturation: 0.58, brightness: 0.78)
        let glow = Color(hue: thermalHue, saturation: 0.88, brightness: 1.0)
        return LinearGradient(
            colors: [glow.opacity(0.94), thermal.opacity(0.82), complement.opacity(0.76)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func rainGradient(_ state: WeatherState) -> LinearGradient? {
        let probability = Double(state.precipitationProbability ?? 0) / 100
        let millimeters = min(1, (state.precipitation ?? 0) / 8)
        let intensity = max(probability, millimeters)
        guard intensity > 0.02 else { return nil }

        let alpha = 0.34 + min(1, intensity) * 0.52
        return LinearGradient(
            colors: [
                Color(red: 128/255, green: 222/255, blue: 255/255).opacity(alpha),
                Color(red: 41/255, green: 171/255, blue: 226/255).opacity(alpha * 0.92),
                Color(red: 43/255, green: 111/255, blue: 218/255).opacity(alpha * 0.78)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func pm25Gradient(_ value: Double?) -> LinearGradient? {
        guard let value else { return nil }
        if value <= 25 {
            let intensity = min(1, max(0.25, value / 25))
            return LinearGradient(
                colors: [
                    Color(red: 181/255, green: 244/255, blue: 197/255).opacity(0.48 + intensity * 0.18),
                    Color(red: 91/255, green: 214/255, blue: 145/255).opacity(0.44 + intensity * 0.20),
                    Color(red: 37/255, green: 143/255, blue: 99/255).opacity(0.36 + intensity * 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        let exceedance = min(1, (value - 25) / 35)
        return LinearGradient(
            colors: [
                Color(red: 255/255, green: 184/255, blue: 77/255).opacity(0.70 + exceedance * 0.16),
                Color(red: 245/255, green: 109/255, blue: 61/255).opacity(0.72 + exceedance * 0.18),
                Color(red: 203/255, green: 53/255, blue: 79/255).opacity(0.64 + exceedance * 0.24)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func chip(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.custom("Google Sans Flex 18pt", size: 10))
                .fontWeight(.semibold)
                .foregroundStyle(subtleText)
            Text(value)
                .font(.custom("Google Sans Flex 18pt", size: 11))
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(surfaceHover)
        }
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func degrees(_ value: Double?) -> String { value.map { "\(format($0))°" } ?? "--" }
    private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "--" }
    private func micrograms(_ value: Double?) -> String { value.map { "\(format($0))" } ?? "--" }
    private func grains(_ value: Double?) -> String { value.map { "\(format($0))" } ?? "--" }

    private func minMax(_ state: WeatherState) -> String {
        guard let min = state.tempMin, let max = state.tempMax else { return "--" }
        return "\(format(min))° / \(format(max))°"
    }

    private func rain(_ state: WeatherState) -> String {
        if let probability = state.precipitationProbability {
            return "\(probability)%"
        }
        if let precipitation = state.precipitation {
            return "\(format(precipitation)) mm"
        }
        return "--"
    }

    private func wind(_ state: WeatherState) -> String {
        guard let speed = state.windSpeed else { return "--" }
        let direction = state.windDirection?.isEmpty == false ? " \(state.windDirection!)" : ""
        if let gusts = state.windGusts, gusts > speed + 4 {
            return "\(format(speed)) / \(format(gusts)) km/h\(direction)"
        }
        return "\(format(speed)) km/h\(direction)"
    }

    private func uv(_ value: Double?) -> String {
        guard let value else { return "--" }
        let label: String
        if value < 3 { label = "basso" }
        else if value < 6 { label = "medio" }
        else if value < 8 { label = "alto" }
        else { label = "molto alto" }
        return "\(format(value)) · \(label)"
    }

    private func time(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "--" }
        return String(iso.suffix(5))
    }

    private func color(hex: String?) -> Color? {
        guard let hex else { return nil }
        let raw = hex.replacingOccurrences(of: "0xff", with: "").replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.custom("Google Sans Flex 18pt", size: 11))
                .fontWeight(.semibold)
                .foregroundStyle(secondaryText)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(surface)
        }
    }
}

let app = NSApplication.shared
let appDelegate = WeatherPopupApp()
app.setActivationPolicy(.accessory)
app.delegate = appDelegate
app.run()
