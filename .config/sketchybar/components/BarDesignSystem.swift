import AppKit
import SwiftUI

// MARK: - Bar design system

/// Design system della barra verticale: colori, tipografia, misure e i
/// componenti di base (contenitore vetrato, divisore, stile dei testi).
/// I widget non definiscono font, colori o sfondi propri: li prendono da qui,
/// così tutta la colonna resta coerente. I popup usano invece `Card.swift`.

enum BarTheme {
    /// Colore unico dei testi: ora, data e valori sono tutti bianchi pieni.
    static let primaryText = Color.white

    /// Vetro dei contenitori: blur di sistema + velo bianco + bordo sottile.
    static let glassMaterial: Material = .ultraThinMaterial
    static let glassVeil = Color.white.opacity(0.06)
    /// Con un colore di stato il velo diventa quel colore, più presente.
    static let glassTintOpacity: Double = 0.22
    static let border = Color.white.opacity(0.22)
    static let borderWidth: CGFloat = 0.75
    static let divider = Color.white.opacity(0.22)

    /// Colori di stato: riservati alle icone, che portano il significato
    /// (carica, segnale, salute). I testi restano `primaryText`.
    enum Status {
        static let good = Color(red: 0.65, green: 0.89, blue: 0.63)
        static let warning = Color(red: 0.98, green: 0.89, blue: 0.69)
        static let critical = Color(red: 0.95, green: 0.55, blue: 0.66)
        static let neutral = Color(red: 0.79, green: 0.77, blue: 0.81)
    }

    /// Colori delle condizioni meteo, nella stessa gamma pastello degli
    /// stati. Come quelli, solo per le icone.
    enum Weather {
        static let sun = Color(red: 0.98, green: 0.89, blue: 0.69)
        static let night = Color(red: 0.71, green: 0.75, blue: 1.00)
        static let rain = Color(red: 0.45, green: 0.78, blue: 0.93)
        static let snow = Color(red: 0.54, green: 0.86, blue: 0.92)
        static let storm = Color(red: 0.80, green: 0.65, blue: 0.97)
        static let cloud = Status.neutral
    }
}

enum BarTypography {
    enum InterWeight: String {
        case medium = "Medium"
        case semiBold = "SemiBold"
    }

    /// Inter (brew cask `font-inter`, in ~/Library/Fonts). `Font.custom` cade
    /// sul font di sistema se manca, quindi la barra parte comunque.
    static func inter(_ size: CGFloat, _ weight: InterWeight) -> Font {
        .custom("Inter-\(weight.rawValue)", size: size)
    }
}

/// Gli unici stili di testo della barra.
enum BarTextStyle {
    /// Il dato principale di un contenitore: l'ora.
    case display
    /// Tutto il resto: righe della data, valori dei widget.
    case body

    var font: Font {
        switch self {
        case .display: return BarTypography.inter(21, .semiBold)
        case .body: return BarTypography.inter(15, .semiBold)
        }
    }
}

enum BarLayout {
    /// Larghezza dei contenitori impilati nella colonna.
    static let containerWidth: CGFloat = 52
    static let containerRadius: CGFloat = 16
    static let containerVerticalPadding: CGFloat = 11
    /// Spazio tra icona e valore dentro un contenitore.
    static let itemSpacing: CGFloat = 4
    static let dividerWidth: CGFloat = 22
    static let dividerVerticalPadding: CGFloat = 7
    /// Lato del riquadro delle icone disegnate (batteria, Wi-Fi, …).
    static let iconSize: CGFloat = 24
    static let accessoryIconSize: CGFloat = 10
}

extension View {
    /// Font, colore e comportamento di una riga di testo della barra. Cifre
    /// tabulari ovunque: i valori che cambiano non fanno ballare la riga.
    func barText(_ style: BarTextStyle) -> some View {
        font(style.font)
            .foregroundStyle(BarTheme.primaryText)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// Sfondo vetrato di un contenitore della barra, con la forma data.
    func barGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        background {
            shape.fill(BarTheme.glassMaterial)
            shape.fill(tint.map { $0.opacity(BarTheme.glassTintOpacity) } ?? BarTheme.glassVeil)
            shape.strokeBorder(BarTheme.border, lineWidth: BarTheme.borderWidth)
        }
    }

    /// Sfondo del contenitore standard (rettangolo arrotondato).
    func barContainerBackground() -> some View {
        barGlass(RoundedRectangle(cornerRadius: BarLayout.containerRadius, style: .continuous))
    }
}

/// Contenitore standard della colonna: larghezza fissa, contenuto impilato e
/// centrato, vetro arrotondato dietro.
struct BarContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: spacing) {
            content()
        }
        .frame(width: BarLayout.containerWidth)
        .padding(.vertical, BarLayout.containerVerticalPadding)
        .barContainerBackground()
    }
}

/// Linea sottile che separa due gruppi di righe in un contenitore.
struct BarDivider: View {
    var body: some View {
        Capsule()
            .fill(BarTheme.divider)
            .frame(width: BarLayout.dividerWidth, height: 1)
            .padding(.vertical, BarLayout.dividerVerticalPadding)
    }
}
