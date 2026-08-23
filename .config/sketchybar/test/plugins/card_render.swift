import Cocoa

// Renderizza una "card" quadrata stile Apple Weather widget: sfondo con
// angoli molto arrotondati (colore dinamico, passato dal chiamante), testo
// su più righe con parole in bold bianco alternate a parole in grigio
// regular; ogni run può forzare un font/colore custom (serve per i glifi
// icona, stessi font/colori usati dal widget meteo di produzione). Il
// contenuto arriva da stdin come JSON, così lo script chiamante resta
// responsabile solo dei dati, non del rendering pixel-perfect.
//
// Uso: card_render <output.png> <side_points> <scale>
// stdin: {"background":"0xff315478","lines":[[{"t":"19°","b":true},
//         {"t":" ora","b":false}], [{"t":"☔︎","font":"Apple Symbols",
//         "color":"0xff80deff"}, {"t":" pioggia","b":true}]]}

struct Run: Codable {
    let t: String
    let b: Bool?
    let font: String?
    let color: String?
}

struct Card: Codable {
    let background: String
    let lines: [[Run]]
}

func parseHexColor(_ s: String) -> NSColor {
    var hex = s
    if hex.hasPrefix("0x") { hex.removeFirst(2) }
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    let a = CGFloat((value >> 24) & 0xFF) / 255.0
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: hex.count > 6 ? a : 1.0)
}

guard CommandLine.arguments.count >= 4,
      let side = Double(CommandLine.arguments[2]),
      let scale = Double(CommandLine.arguments[3]) else {
    FileHandle.standardError.write("uso: card_render <output.png> <side_points> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let card = try? JSONDecoder().decode(Card.self, from: stdinData) else {
    FileHandle.standardError.write("JSON non valido su stdin\n".data(using: .utf8)!)
    exit(1)
}
let lines = card.lines

let pixelSide = Int((side * scale).rounded())
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSide,
    pixelsHigh: pixelSide,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Coordinate "dall'alto verso il basso": più intuitivo per impaginare righe
// di testo. Il context di un bitmap rep non è flipped di default, quindi
// ribaltiamo la CTM una volta sola qui.
ctx.translateBy(x: 0, y: side)
ctx.scaleBy(x: 1, y: -1)

let cornerRadius = side * 0.22
let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                           xRadius: cornerRadius, yRadius: cornerRadius)
parseHexColor(card.background).setFill()
bgPath.fill()

let padding = side * 0.13
let maxTextWidth = side - padding * 2
let boldColor = NSColor.white
let grayColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)

func resolveFont(_ run: Run, fontSize: CGFloat) -> NSFont {
    if let name = run.font, let custom = NSFont(name: name, size: fontSize) {
        return custom
    }
    return NSFont.systemFont(ofSize: fontSize, weight: (run.b ?? false) ? .bold : .medium)
}

func resolveColor(_ run: Run) -> NSColor {
    if let hex = run.color { return parseHexColor(hex) }
    return (run.b ?? false) ? boldColor : grayColor
}

func makeAttributed(_ lineRuns: [Run], fontSize: CGFloat) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for run in lineRuns {
        attributed.append(NSAttributedString(string: run.t, attributes: [
            .font: resolveFont(run, fontSize: fontSize),
            .foregroundColor: resolveColor(run),
        ]))
    }
    return attributed
}

// Auto-fit: parte da una taglia di base e la restringe finché la riga più
// larga entra nel riquadro di testo, così la card regge contenuti di
// lunghezza variabile (es. città o parole italiane più lunghe dell'inglese)
// senza mai uscire dai bordi arrotondati.
let baseFontSize = side * 0.155
let minFontSize = side * 0.07
var fontSize = baseFontSize
while fontSize > minFontSize {
    let widestLine = lines.map { makeAttributed($0, fontSize: fontSize).size().width }.max() ?? 0
    if widestLine <= maxTextWidth { break }
    fontSize -= 1
}

let lineHeight = fontSize * 1.22
let totalTextHeight = CGFloat(lines.count) * lineHeight
let startY = (side - totalTextHeight) / 2 + fontSize * 0.15

for (i, lineRuns) in lines.enumerated() {
    let attributed = makeAttributed(lineRuns, fontSize: fontSize)
    // Testo disegnato "dritto" in un context flippato: va ri-flippato localmente.
    ctx.saveGState()
    let y = startY + CGFloat(i) * lineHeight
    ctx.translateBy(x: 0, y: y + fontSize)
    ctx.scaleBy(x: 1, y: -1)
    attributed.draw(at: NSPoint(x: padding, y: 0))
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: outputPath))
