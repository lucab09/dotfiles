import AppKit
import SwiftUI
import Foundation

// MARK: - Network colors

private let cGreen = Color(red: 166/255, green: 227/255, blue: 161/255)

// MARK: - State

final class NetworkState: ObservableObject {
    @Published var ssid: String = "WiFi"
    @Published var wifiEnabled: Bool = true
    @Published var tailscaleActive: Bool = false
    @Published var nordActive: Bool = false
    @Published var awsActive: Bool = false
}

// MARK: - Shell

@discardableResult
func sh(_ cmd: String) -> String {
    let t = Process(); let p = Pipe()
    t.launchPath = "/bin/sh"; t.arguments = ["-c", cmd]
    t.standardOutput = p; t.standardError = Pipe()
    try? t.run(); t.waitUntilExit()
    return (String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - SSID

// macOS oscura l'SSID (`<redacted>`) a chi non ha il permesso Location
// Services, quindi `ipconfig getsummary` e `networksetup -getairportnetwork`
// sono inutilizzabili. Il nome resta però leggibile nel CachedScanRecord che
// `scutil` espone come plist archiviato: ne estraiamo la prima stringa che
// somigli a un SSID, esattamente come faceva plugins/vpn.sh.

private let ssidCachePath = "/tmp/sketchybar_ssid_cache"
private let ssidCacheMaxAge: TimeInterval = 60

private func looksLikeSSID(_ s: String) -> Bool {
    guard (1...32).contains(s.count), !s.contains(":"), s != "$null", s != "root" else { return false }
    if s.range(of: "^[A-Z0-9][A-Z0-9_]*$", options: .regularExpression) != nil { return false }
    if s.range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil { return false }
    return true
}

private func scanRecordSSID() -> String {
    let dump = sh("printf 'open\\nshow State:/Network/Interface/en0/AirPort\\n' | scutil 2>/dev/null")
    guard let marker = dump.range(of: "CachedScanRecord : <data> 0x") else { return "" }
    let hex = dump[marker.upperBound...].prefix { $0.isHexDigit }
    var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
    var i = hex.startIndex
    while i < hex.endIndex {
        guard let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), j > i,
              let byte = UInt8(hex[i..<j], radix: 16) else { break }
        bytes.append(byte); i = j
    }
    guard !bytes.isEmpty,
          let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil),
          let objects = (plist as? [String: Any])?["$objects"] as? [Any] else { return "" }
    for case let candidate as String in objects where looksLikeSSID(candidate) { return candidate }
    return ""
}

// Il file di cache resta il punto di scambio con plugins/vpn.sh: se un giorno
// quello script tornasse a girare, i due processi si riusano il risultato
// invece di interrogare `scutil` a turno.
func currentSSID() -> String {
    let fm = FileManager.default
    if let modified = (try? fm.attributesOfItem(atPath: ssidCachePath))?[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) < ssidCacheMaxAge,
       let cached = try? String(contentsOfFile: ssidCachePath, encoding: .utf8) {
        let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    let detected = scanRecordSSID()
    let value = detected.isEmpty ? "WiFi" : detected
    try? value.write(toFile: ssidCachePath, atomically: true, encoding: .utf8)
    return value
}

// MARK: - Detection

struct DetectedState {
    var ssid = "WiFi"; var wifi = true
    var tailscale = false; var nord = false; var aws = false
}

func detectNetwork() -> DetectedState {
    var d = DetectedState()
    d.ssid = currentSSID()
    d.wifi = !sh("networksetup -getairportpower en0 2>/dev/null").lowercased().contains("off")
    let nc = sh("scutil --nc list 2>/dev/null").lowercased()
    d.tailscale = nc.contains("tailscale") && nc.contains("(connected)")
    d.nord = sh("defaults read com.nordvpn.macos isAppWasConnectedToVPN 2>/dev/null") == "1"
    let upLog   = "/Library/Application Support/AWSVPNClient/UpLog.txt"
    let downLog = "/Library/Application Support/AWSVPNClient/DownLog.txt"
    let fm = FileManager.default
    if let upDate = try? fm.attributesOfItem(atPath: upLog)[.modificationDate] as? Date,
       let dnDate = try? fm.attributesOfItem(atPath: downLog)[.modificationDate] as? Date {
        d.aws = upDate > dnDate
    } else {
        d.aws = fm.fileExists(atPath: upLog) && !fm.fileExists(atPath: downLog)
    }
    return d
}

// MARK: - IPC Server (Unix socket)

final class IPCServer {
    var onToggle: ((CGFloat) -> Void)?
    var onHide: (() -> Void)?
    var onState:  ((String, Bool, Bool, Bool, Bool) -> Void)?

    func start() {
        let path = "/tmp/network_popup.sock"
        try? FileManager.default.removeItem(atPath: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withCString { src in
                _ = Darwin.strncpy(dst.baseAddress!.assumingMemoryBound(to: Int8.self), src, 104)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 }
        }
        guard bound, Darwin.listen(fd, 5) == 0 else { return }

        DispatchQueue.global(qos: .background).async { [weak self] in
            while true {
                let c = Darwin.accept(fd, nil, nil); guard c >= 0 else { continue }
                var buf = [UInt8](repeating: 0, count: 2048)
                let n = Darwin.read(c, &buf, 2047); Darwin.close(c)
                guard n > 0 else { continue }
                let msg = String(bytes: buf[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self?.parse(msg)
            }
        }
    }

    private func parse(_ msg: String) {
        let parts = msg.components(separatedBy: " ")
        guard let cmd = parts.first else { return }
        if cmd == "toggle" {
            let x = CGFloat(Double(parts.dropFirst().first ?? "0") ?? 0)
            DispatchQueue.main.async { self.onToggle?(x) }
        } else if cmd == "hide" {
            DispatchQueue.main.async { self.onHide?() }
        } else if cmd == "state" {
            var d: [String: String] = [:]
            parts.dropFirst().forEach { kv in
                let p = kv.components(separatedBy: "="); if p.count == 2 { d[p[0]] = p[1] }
            }
            let ssid = (d["ssid"] ?? "WiFi").replacingOccurrences(of: "%20", with: " ")
            DispatchQueue.main.async { self.onState?(
                ssid,
                d["wifi"]      != "0",
                d["tailscale"] == "1",
                d["nord"]      == "1",
                d["aws"]       == "1"
            )}
        }
    }
}

// MARK: - SwiftUI Views

private let popupWidth: CGFloat = 320

struct NetworkPopupView: View {
    @ObservedObject var state: NetworkState

    var body: some View {
        DesignSystemCard(
            title: state.wifiEnabled ? state.ssid : "Wi-Fi",
            subtitle: "Impostazioni di Rete",
            subtitleAction: openNetworkSettings,
            headerAccessory: {
                Toggle("Wi-Fi", isOn: Binding(
                    get: { state.wifiEnabled },
                    set: setWiFiEnabled
                ))
                .toggleStyle(CardToggleStyle())
                .labelsHidden()
                .accessibilityLabel("Attiva o disattiva Wi-Fi")
            }
        ) {
            connectionRow(
                icon: "shield.lefthalf.filled",
                appIconPath: "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/AppIcon.icns",
                title: "AWS VPN",
                active: state.awsActive,
                toggleState: Binding(
                    get: { state.awsActive },
                    set: { enabled in
                        state.awsActive = enabled
                        setApplicationRunning(enabled, named: "AWS VPN Client")
                    }
                )
            )
            connectionRow(
                icon: "point.3.connected.trianglepath.dotted",
                appIconPath: "/Applications/Tailscale.app/Contents/Resources/AppIcon.icns",
                title: "Tailscale",
                active: state.tailscaleActive,
                toggleState: Binding(
                    get: { state.tailscaleActive },
                    set: { enabled in
                        state.tailscaleActive = enabled
                        setApplicationRunning(enabled, named: "Tailscale")
                    }
                )
            )
            connectionRow(
                icon: "lock.shield.fill",
                appIconPath: "/Applications/NordVPN.app/Contents/Resources/AppIconSideload.icns",
                title: "NordVPN",
                active: state.nordActive,
                toggleState: Binding(
                    get: { state.nordActive },
                    set: { enabled in
                        state.nordActive = enabled
                        setApplicationRunning(enabled, named: "NordVPN")
                    }
                )
            )
        }
        .frame(width: popupWidth)
    }

    private func connectionRow(
        icon: String,
        appIconPath: String,
        title: String,
        active: Bool,
        toggleState: Binding<Bool>? = nil
    ) -> some View {
        DesignSystemCardRow(
            icon: icon,
            appIconPath: appIconPath,
            iconTint: active ? cGreen : CardTheme.secondaryText,
            title: title,
            toggleState: toggleState,
            toggleAccessibilityLabel: "Attiva o chiudi \(title)"
        )
    }

    private func setApplicationRunning(_ shouldRun: Bool, named applicationName: String) {
        DispatchQueue.global().async {
            if shouldRun {
                sh("open -a '\(applicationName)' 2>/dev/null")
            } else {
                // Equivalente al comando Cmd+Q sull'app che gestisce il servizio.
                sh("osascript -e 'tell application \"\(applicationName)\" to quit' 2>/dev/null")
            }
        }
    }

    private func setWiFiEnabled(_ enabled: Bool) {
        state.wifiEnabled = enabled
        DispatchQueue.global().async {
            sh("networksetup -setairportpower en0 \(enabled ? "on" : "off") 2>/dev/null")
        }
    }

    private func openNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    var hosting: NSHostingView<NetworkPopupView>?
    var clickMonitor: Any?
    var anchorX: CGFloat?
    let state = NetworkState()
    let ipc = IPCServer()

    func applicationDidFinishLaunching(_ n: Notification) {
        ipc.onToggle = { [weak self] x in self?.toggle(anchorX: x) }
        ipc.onHide = { [weak self] in self?.hide() }
        ipc.onState  = { [weak self] ssid, wifi, ts, nord, aws in
            guard let s = self?.state else { return }
            s.ssid = ssid; s.wifiEnabled = wifi
            s.tailscaleActive = ts; s.nordActive = nord; s.awsActive = aws
        }
        ipc.start()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let d = detectNetwork()
        state.ssid = d.ssid; state.wifiEnabled = d.wifi
        state.tailscaleActive = d.tailscale; state.nordActive = d.nord
        state.awsActive = d.aws
    }

    func buildPanel() {
        let h = NSHostingView(rootView: NetworkPopupView(state: state))
        h.frame = NSRect(x: 0, y: 0, width: popupWidth, height: 0)
        h.layoutSubtreeIfNeeded()
        let height = max(h.fittingSize.height, 200)
        h.frame.size.height = height

        let p = NSPanel(contentRect: h.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false; p.hasShadow = true; p.backgroundColor = .clear
        // SwiftUI emette `onHover` soltanto se il pannello riceve mouseMoved.
        p.acceptsMouseMovedEvents = true
        p.isReleasedWhenClosed = false; p.contentView = h
        hosting = h; panel = p
    }

    func toggle(anchorX: CGFloat) {
        if panel == nil { buildPanel() }
        guard let p = panel else { return }
        p.isVisible ? hide() : show(anchorX: anchorX)
    }

    func show(anchorX: CGFloat) {
        guard let p = panel, let h = hosting else { return }
        self.anchorX = anchorX
        let H = max(h.fittingSize.height, 200)
        let screen = NSScreen.screens.first(where: {
            anchorX >= $0.frame.minX && anchorX <= $0.frame.maxX
        }) ?? NSScreen.main!
        // La barra Swift è alta 50 pt ed è aderente al bordo superiore.
        let barBottom = screen.frame.maxY - 50
        // Il popup si sviluppa verso sinistra: il bordo destro coincide
        // esattamente con il bordo destro dell'icona che lo ha aperto.
        let px = anchorX - popupWidth
        let py = barBottom - H - 6
        p.setFrame(NSRect(x: px, y: py, width: popupWidth, height: H), display: true)
        p.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel else { return }
            let clickPoint = NSEvent.mouseLocation
            // Il click sull'icona Wi-Fi della barra deve arrivare al comando
            // `toggle`: non chiudiamo qui il popup per poi riaprirlo subito.
            if self.isAnchorClick(clickPoint) { return }
            if !p.frame.contains(clickPoint) { self.hide() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func isAnchorClick(_ point: NSPoint) -> Bool {
        guard let anchorX,
              let screen = NSScreen.screens.first(where: {
                  anchorX >= $0.frame.minX && anchorX <= $0.frame.maxX
              }) else { return false }
        let barBottom = screen.frame.maxY - 50
        return point.x >= anchorX - 32 && point.x <= anchorX + 8
            && point.y >= barBottom && point.y <= screen.frame.maxY
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
