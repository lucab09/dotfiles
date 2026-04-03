import AppKit
import SwiftUI
import Foundation

// MARK: - Catppuccin Mocha

private let cBase    = Color(red: 30/255,  green: 32/255,  blue: 48/255)
private let cSurf    = Color(red: 49/255,  green: 50/255,  blue: 68/255)
private let cText    = Color(red: 205/255, green: 214/255, blue: 244/255)
private let cSub     = Color(red: 166/255, green: 173/255, blue: 200/255)
private let cGreen   = Color(red: 166/255, green: 227/255, blue: 161/255)
private let cOverlay = Color(red: 108/255, green: 112/255, blue: 134/255)

// MARK: - State

final class NetworkState: ObservableObject {
    @Published var ssid: String = "WiFi"
    @Published var wifiEnabled: Bool = true
    @Published var tailscaleActive: Bool = false
    @Published var nordActive: Bool = false
    @Published var awsActive: Bool = false
    @Published var corpActive: Bool = false
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

// MARK: - Detection

struct DetectedState {
    var ssid = "WiFi"; var wifi = true
    var tailscale = false; var nord = false; var aws = false; var corp = false
}

func detectNetwork() -> DetectedState {
    var d = DetectedState()
    let cached = (try? String(contentsOfFile: "/tmp/sketchybar_ssid_cache", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    d.ssid = cached.isEmpty ? "WiFi" : cached
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
    d.corp = d.ssid == "qbc-ent"
    return d
}

// MARK: - IPC Server (Unix socket)

final class IPCServer {
    var onToggle: ((CGFloat) -> Void)?
    var onState:  ((String, Bool, Bool, Bool, Bool, Bool) -> Void)?

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
                d["aws"]       == "1",
                d["corp"]      == "1"
            )}
        }
    }
}

// MARK: - Cursor helper

extension View {
    func handCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - SwiftUI Views

private let popupWidth: CGFloat = 280

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(cSub)
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

struct WiFiRow: View {
    @ObservedObject var state: NetworkState
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.wifiEnabled ? "wifi" : "wifi.slash")
                .frame(width: 20)
                .foregroundColor(cText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wi-Fi")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(cText)
                if state.wifiEnabled {
                    Text(state.ssid)
                        .font(.system(size: 12))
                        .foregroundColor(cSub)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.wifiEnabled },
                set: { v in
                    state.wifiEnabled = v
                    DispatchQueue.global().async { sh("networksetup -setairportpower en0 \(v ? "on" : "off") 2>/dev/null") }
                }
            ))
            .toggleStyle(.switch)
            .tint(cGreen)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SettingsLinkRow: View {
    @State private var hovered = false
    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").frame(width: 20).foregroundColor(cSub)
                Text("Network Settings").font(.system(size: 13)).foregroundColor(cSub)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundColor(cOverlay)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(hovered ? cSurf : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovered = $0 }
        .handCursor()
    }
}

struct VPNRow: View {
    let icon: String?           // SF Symbol name, nil se si usa appIconPath
    let appIconPath: String?    // percorso app per icona nativa
    let activeIconColor: Color  // colore icona quando attiva
    let label: String
    let active: Bool
    let action: (() -> Void)?
    @State private var hovered = false

    init(icon: String? = nil, appIconPath: String? = nil,
         activeIconColor: Color = cGreen,
         label: String, active: Bool, action: (() -> Void)?) {
        self.icon = icon; self.appIconPath = appIconPath
        self.activeIconColor = activeIconColor
        self.label = label; self.active = active; self.action = action
    }

    @ViewBuilder private var iconView: some View {
        if let path = appIconPath {
            let nsImg = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: nsImg)
                .resizable().scaledToFit()
                .frame(width: 20, height: 20)
                .opacity(active ? 1.0 : 0.4)
        } else if let name = icon {
            Image(systemName: name)
                .frame(width: 20)
                .foregroundColor(active ? activeIconColor : cText.opacity(0.6))
        }
    }

    var body: some View {
        let hasAction = action != nil
        Button { action?() } label: {
            HStack(spacing: 10) {
                iconView
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(cText)
                Spacer()
                Circle()
                    .fill(active ? cGreen : cOverlay.opacity(0.5))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(hovered && hasAction ? cSurf : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!hasAction)
        .padding(.horizontal, 4)
        .onHover { v in
            if hasAction { withAnimation(.easeInOut(duration: 0.1)) { hovered = v } }
        }
        .handCursor()
    }
}

struct PopupDivider: View {
    var body: some View {
        Rectangle()
            .fill(cOverlay.opacity(0.25))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

struct NetworkPopupView: View {
    @ObservedObject var state: NetworkState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Settings")
            WiFiRow(state: state)
            SettingsLinkRow()

            PopupDivider()

            SectionHeader(title: "Configurations")
            VPNRow(appIconPath: "/Applications/AWS VPN Client/AWS VPN Client.app",
                   label: "AWS VPN", active: state.awsActive)
                  { sh("open -a 'AWS VPN Client' 2>/dev/null") }
            VPNRow(appIconPath: "/Applications/Tailscale.app",
                   label: "Tailscale", active: state.tailscaleActive)
                  { sh("open -a 'Tailscale' 2>/dev/null") }
            VPNRow(appIconPath: "/Applications/NordVPN.app",
                   label: "NordVPN", active: state.nordActive)
                  { sh("open -a 'NordVPN' 2>/dev/null") }
            VPNRow(icon: "building.2.fill",  label: "Corporate WiFi", active: state.corpActive,
                   action: nil)

            Spacer(minLength: 12)
        }
        .frame(width: popupWidth)
        .background(cBase)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cOverlay.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    var hosting: NSHostingView<NetworkPopupView>?
    var clickMonitor: Any?
    let state = NetworkState()
    let ipc = IPCServer()

    func applicationDidFinishLaunching(_ n: Notification) {
        ipc.onToggle = { [weak self] x in self?.toggle(anchorX: x) }
        ipc.onState  = { [weak self] ssid, wifi, ts, nord, aws, corp in
            guard let s = self?.state else { return }
            s.ssid = ssid; s.wifiEnabled = wifi
            s.tailscaleActive = ts; s.nordActive = nord; s.awsActive = aws; s.corpActive = corp
        }
        ipc.start()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let d = detectNetwork()
        state.ssid = d.ssid; state.wifiEnabled = d.wifi
        state.tailscaleActive = d.tailscale; state.nordActive = d.nord
        state.awsActive = d.aws; state.corpActive = d.corp
    }

    func buildPanel() {
        let h = NSHostingView(rootView: NetworkPopupView(state: state))
        h.frame = NSRect(x: 0, y: 0, width: popupWidth, height: 99999)
        h.layoutSubtreeIfNeeded()
        let height = max(h.fittingSize.height, 200)
        h.frame.size.height = height

        let p = NSPanel(contentRect: h.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false; p.hasShadow = true; p.backgroundColor = .clear
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
        let H = max(h.fittingSize.height, 200)
        let screen = NSScreen.main!
        // Bar: height=36, y_offset=6 in sketchybarrc
        let barBottom = screen.frame.height - 42
        let px = screen.frame.width - popupWidth - 10
        let py = barBottom - H - 8
        p.setFrame(NSRect(x: px, y: py, width: popupWidth, height: H), display: true)
        p.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel else { return }
            if !p.frame.contains(NSEvent.mouseLocation) { self.hide() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
