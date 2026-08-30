import AppKit
import SwiftUI

// MARK: - Card design system

/// Contenitore riusabile per i popup: intestazione, accessorio opzionale a
/// destra dell'intestazione e lista di righe con CTA opzionale.
struct DesignSystemCard<HeaderAccessory: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let subtitleAction: (() -> Void)?
    let headerAccessory: HeaderAccessory
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        subtitleAction: (() -> Void)? = nil,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleAction = subtitleAction
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(CardTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 12)
                    headerAccessory
                }

                if let subtitle, !subtitle.isEmpty {
                    if let subtitleAction {
                        Button(action: subtitleAction) {
                            Text(subtitle)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(CardTheme.secondaryText)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .cardCursor(.pointingHand)
                        .accessibilityLabel(subtitle)
                    } else {
                        Text(subtitle)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(CardTheme.secondaryText)
                    }
                }
            }

            VStack(spacing: 6) {
                content
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                CardGlassBackground()
                Color.black.opacity(0.56)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(CardTheme.border, lineWidth: 1)
            }
        }
        .padding(1)
    }
}

private extension View {
    /// Tracking AppKit esplicito: i pannelli non attivanti non inoltrano in
    /// modo affidabile gli hover SwiftUI alle Button ospitate.
    func cardCursor(_ cursor: NSCursor) -> some View {
        overlay(CardCursorArea(cursor: cursor))
    }
}

private struct CardCursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CardCursorView {
        CardCursorView(cursor: cursor)
    }

    func updateNSView(_ nsView: CardCursorView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CardCursorView: NSView {
    var cursor: NSCursor
    private var cursorTrackingArea: NSTrackingArea?

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Il view osserva il puntatore, senza intercettare click o toggle.
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        cursorTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension DesignSystemCard where HeaderAccessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        subtitleAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleAction: subtitleAction,
            headerAccessory: { EmptyView() },
            content: content
        )
    }
}

/// Riga del design system: icona circolare a sinistra, titolo e valore su due
/// righe, e una CTA opzionale a destra.
struct DesignSystemCardRow: View {
    let icon: String
    let appIconPath: String?
    let iconTint: Color
    let title: String
    let value: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let toggleState: Binding<Bool>?
    let toggleAccessibilityLabel: String?

    init(
        icon: String,
        appIconPath: String? = nil,
        iconTint: Color = CardTheme.primaryText,
        title: String,
        value: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        toggleState: Binding<Bool>? = nil,
        toggleAccessibilityLabel: String? = nil
    ) {
        self.icon = icon
        self.appIconPath = appIconPath
        self.iconTint = iconTint
        self.title = title
        self.value = value
        self.actionTitle = actionTitle
        self.action = action
        self.toggleState = toggleState
        self.toggleAccessibilityLabel = toggleAccessibilityLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            if let appIconPath {
                Image(nsImage: nativeAppIcon(at: appIconPath))
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(iconTint.opacity(0.13)))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(CardTheme.primaryText)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(CardTheme.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if let toggleState {
                Toggle("", isOn: toggleState)
                    .toggleStyle(CardToggleStyle())
                    .labelsHidden()
                    .cardCursor(.pointingHand)
                    .accessibilityLabel(toggleAccessibilityLabel ?? title)
            } else if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(CardTheme.actionText)
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(Capsule().fill(CardTheme.actionBackground))
                }
                .buttonStyle(.plain)
                .cardCursor(.pointingHand)
                .accessibilityLabel("\(actionTitle), \(title)")
            }
        }
        .frame(minHeight: 56)
    }
}

private func nativeAppIcon(at path: String) -> NSImage {
    let image = NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(forFile: path)
    image.isTemplate = false
    return image
}

enum CardTheme {
    static let border = Color.white.opacity(0.14)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.68)
    static let actionBackground = Color(red: 0.77, green: 1.00, blue: 0.25)
    static let actionText = Color(red: 0.12, green: 0.16, blue: 0.04)
}

/// Switch del design system. Lo stile nativo di macOS ignora `.tint` nei
/// pannelli non attivanti, quindi il colore dello stato acceso è disegnato
/// esplicitamente con il colore delle CTA.
struct CardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? CardTheme.actionBackground : Color.white.opacity(0.18))

                Circle()
                    .fill(configuration.isOn ? CardTheme.actionText : Color.white.opacity(0.88))
                    .padding(3)
                    .offset(x: configuration.isOn ? 9 : -9)
            }
            .frame(width: 46, height: 28)
        }
        .buttonStyle(.plain)
        .cardCursor(.pointingHand)
    }
}

private struct CardGlassBackground: NSViewRepresentable {
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
