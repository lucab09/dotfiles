import Cocoa
import CoreText

// Renderizza la card orologio: ora grande in bold in alto, sotto una riga
// mese (sx, normale) / giorno (dx, normale), poi una riga anno (sx, light) /
// settimana "W34" (dx, light) — stesso font della riga anno. Layout fisso
// (non uno stack di righe come card_render), quindi un renderer dedicato.
//
// Uso: clock_card_render <output.png> <side_points> <scale>
// stdin: {"background":"0xff2d6cdf","time":"23:41","month":"Agosto",
//         "day":"23","year":"2026","week":"W34"}

struct ClockCard: Codable {
    let background: String
    let time: String
    let month: String
    let day: String
    let year: String
    let week: String
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
    return NSColor(srgbRed: r, green: g, blue: b, alpha: hex.count > 6 ? a : 1.0)
}

guard CommandLine.arguments.count >= 4,
      let side = Double(CommandLine.arguments[2]),
      let scale = Double(CommandLine.arguments[3]) else {
    FileHandle.standardError.write("uso: clock_card_render <output.png> <side_points> <scale>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let card = try? JSONDecoder().decode(ClockCard.self, from: stdinData) else {
    FileHandle.standardError.write("JSON non valido su stdin\n".data(using: .utf8)!)
    exit(1)
}

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

// Coordinate "dall'alto verso il basso" (stesso trucco di card_render).
ctx.translateBy(x: 0, y: side)
ctx.scaleBy(x: 1, y: -1)

let cornerRadius = side * 0.22
let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                           xRadius: cornerRadius, yRadius: cornerRadius)
parseHexColor(card.background).setFill()
bgPath.fill()

let padding = side * 0.13
let maxWidth = side - padding * 2
let white = NSColor.white
let lightGray = NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)

// Disegna una stringa con l'origine (x,yTop) = angolo in alto a sinistra
// del suo bounding box, in coordinate "dall'alto". Ritorna l'altezza riga.
@discardableResult
func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, yTop: CGFloat, rightAlign: Bool = false) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let attributed = NSAttributedString(string: text, attributes: attrs)
    let size = attributed.size()
    let drawX = rightAlign ? x - size.width : x
    ctx.saveGState()
    ctx.translateBy(x: 0, y: yTop + size.height)
    ctx.scaleBy(x: 1, y: -1)
    attributed.draw(at: NSPoint(x: drawX, y: 0))
    ctx.restoreGState()
    return size.height
}

// Auto-fit largo quanto basta per "mese"/"anno" più lunghi (es. "Settembre").
func fittedFont(_ text: String, baseSize: CGFloat, minSize: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat) -> NSFont {
    var size = baseSize
    while size > minSize {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        if width <= maxWidth { break }
        size -= 1
    }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

let timeFont = fittedFont(card.time, baseSize: side * 0.30, minSize: side * 0.16, weight: .bold, maxWidth: maxWidth)
let rowFontSize = side * 0.115
let smallFontSize = side * 0.09
// Metà larghezza disponibile per lato (sx/dx condividono la riga).
let halfWidth = (maxWidth - side * 0.04) / 2
let monthFont = fittedFont(card.month, baseSize: rowFontSize, minSize: side * 0.06, weight: .regular, maxWidth: halfWidth)
let dayFont = fittedFont(card.day, baseSize: rowFontSize, minSize: side * 0.06, weight: .regular, maxWidth: halfWidth)
let yearFont = fittedFont(card.year, baseSize: smallFontSize, minSize: side * 0.05, weight: .light, maxWidth: halfWidth)
let weekFont = fittedFont("W" + card.week, baseSize: smallFontSize, minSize: side * 0.05, weight: .light, maxWidth: halfWidth)

func height(_ text: String, font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().height
}

// La "line box" di un font ha margini interni (ascender/discendente) più
// grandi del vero inchiostro visibile — per cifre e testo senza discendenti
// questo crea un padding visivo asimmetrico anche quando il codice usa lo
// stesso valore di padding sopra e sotto. Qui misuriamo il bounding box
// REALE dei glyph via CoreText e correggiamo lo scarto, così il padding
// percepito sopra/sotto è identico.
func inkTopGap(_ text: String, font: NSFont) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let inkAscent = CTLineGetImageBounds(line, nil).maxY
    return ascent + leading - inkAscent
}
func inkBottomGap(_ text: String, font: NSFont) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let inkDescent = -CTLineGetImageBounds(line, nil).minY
    return descent - inkDescent
}

// Ora ancorata in alto (stesso padding standard della card), il blocco
// mese/anno + giorno/settimana ancorato in basso: il vuoto residuo finisce
// in mezzo, non sopra né sotto.
let gap2 = side * 0.035
let row1Height = max(height(card.month, font: monthFont), height(card.day, font: dayFont))
let row2Height = max(height(card.year, font: yearFont), height("W" + card.week, font: weekFont))
let bottomBlockHeight = row1Height + gap2 + row2Height

drawText(card.time, font: timeFont, color: white, x: padding, yTop: padding - inkTopGap(card.time, font: timeFont))

var y = side - padding - bottomBlockHeight + inkBottomGap(card.year, font: yearFont)

let rowHeight = max(
    drawText(card.month, font: monthFont, color: white, x: padding, yTop: y),
    drawText(card.day, font: dayFont, color: white, x: side - padding, yTop: y, rightAlign: true)
)
y += rowHeight + gap2

drawText(card.year, font: yearFont, color: lightGray, x: padding, yTop: y)
drawText("W" + card.week, font: weekFont, color: lightGray, x: side - padding, yTop: y, rightAlign: true)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: outputPath))
