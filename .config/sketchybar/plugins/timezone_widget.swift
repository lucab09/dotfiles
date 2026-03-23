import AppKit
import CoreLocation
import Foundation

// MARK: - Data Model

struct Person: Codable {
    var name: String
    var location: String
    var timezone: String
    var photo: String
}

let configPath = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".config/sketchybar/timezone_people.json")

func loadPeople() -> [Person] {
    guard let data = try? Data(contentsOf: configPath),
          let decoded = try? JSONDecoder().decode([Person].self, from: data) else { return [] }
    return decoded
}

func savePeople(_ people: [Person]) {
    let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
    if let data = try? enc.encode(people) { try? data.write(to: configPath) }
}

func timeInfo(for timezone: String) -> (time: String, diff: String) {
    let tz = TimeZone(identifier: timezone) ?? TimeZone.current
    let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.timeZone = tz
    let timeStr = fmt.string(from: Date())
    let diffH = Double(tz.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600.0
    var diffStr: String
    if diffH == 0 { diffStr = "same time" }
    else {
        let sign = diffH > 0 ? "+" : ""
        diffStr = diffH.truncatingRemainder(dividingBy: 1) == 0
            ? "\(sign)\(Int(diffH))h"
            : "\(sign)\(String(format:"%.1f",diffH))h"
    }
    return (timeStr, diffStr)
}

// MARK: - Geocoder Autocomplete Field

struct GeoSuggestion {
    let displayName: String
    let timezone: String
}

class GeoAutocompleteField: NSTextField, NSTextFieldDelegate,
                            NSTableViewDelegate, NSTableViewDataSource {
    var suggestions: [GeoSuggestion] = []
    var onSelect: ((GeoSuggestion) -> Void)?
    private var overlayView: NSView?
    private var tableView: NSTableView!
    private let geocoder = CLGeocoder()
    private var debounceTimer: Timer?

    func setup() {
        delegate = self
        placeholderString = "Type any city in the world…"
        focusRingType = .none
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = stringValue.trimmingCharacters(in: .whitespaces)
        debounceTimer?.invalidate()
        if q.count < 2 { closePanel(); return }
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.search(q)
        }
    }

    private func search(_ query: String) {
        geocoder.cancelGeocode()
        geocoder.geocodeAddressString(query) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.suggestions = (placemarks ?? []).compactMap { p -> GeoSuggestion? in
                    guard let tz = p.timeZone else { return nil }
                    let city    = p.locality ?? p.name ?? ""
                    let country = p.country ?? ""
                    let display = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
                    return GeoSuggestion(displayName: display, timezone: tz.identifier)
                }
                if self.suggestions.isEmpty { self.closePanel() }
                else { self.showOverlay() }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(moveDown(_:))        { moveSelection(+1); return true }
        if sel == #selector(moveUp(_:))          { moveSelection(-1); return true }
        if sel == #selector(insertNewline(_:))   { confirmSelection(); return true }
        if sel == #selector(cancelOperation(_:)) { closePanel(); return true }
        return false
    }

    private func moveSelection(_ d: Int) {
        guard let tv = tableView else { return }
        let row = max(0, min(tv.selectedRow + d, suggestions.count - 1))
        tv.selectRowIndexes([row], byExtendingSelection: false)
        tv.scrollRowToVisible(row)
    }

    private func confirmSelection() {
        guard let tv = tableView, tv.selectedRow >= 0, tv.selectedRow < suggestions.count else { return }
        pick(suggestions[tv.selectedRow])
    }

    private func pick(_ s: GeoSuggestion) {
        stringValue = s.displayName
        closePanel()
        onSelect?(s)
    }

    private func showOverlay() {
        guard let cv = window?.contentView else { return }

        // Position overlay relative to content view
        let fieldInCV = cv.convert(bounds, from: self)
        let rowH: CGFloat = 30
        let overlayH = min(CGFloat(suggestions.count) * rowH, 200)
        let overlayW = fieldInCV.width
        let overlayY = fieldInCV.minY - overlayH - 2

        overlayView?.removeFromSuperview()

        let tv = NSTableView()
        tv.delegate = self; tv.dataSource = self
        tv.rowHeight = rowH
        tv.backgroundColor = NSColor(red:0x18/255,green:0x18/255,blue:0x2e/255,alpha:1)
        tv.selectionHighlightStyle = .regular
        tv.headerView = nil; tv.intercellSpacing = .zero
        let col = NSTableColumn(identifier: .init("c")); col.width = overlayW
        tv.addTableColumn(col)
        tv.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tableClicked)))
        tableView = tv

        let scroll = NSScrollView(frame: NSRect(x:0,y:0,width:overlayW,height:overlayH))
        scroll.documentView = tv; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false

        let container = NSView(frame: NSRect(x:fieldInCV.minX, y:overlayY, width:overlayW, height:overlayH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red:0x18/255,green:0x18/255,blue:0x2e/255,alpha:1).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.zPosition = 999
        container.addSubview(scroll)
        overlayView = container

        cv.addSubview(container, positioned: .above, relativeTo: nil)
        tv.reloadData()
        if !suggestions.isEmpty { tv.selectRowIndexes([0], byExtendingSelection:false) }
    }

    @objc private func tableClicked() { confirmSelection() }

    func closePanel() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }

    func numberOfRows(in tv: NSTableView) -> Int { suggestions.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let s = suggestions[row]
        let cell = NSTableCellView()
        let label = NSTextField(frame: NSRect(x:12,y:5,width:(col?.width ?? 300)-16,height:20))
        label.stringValue = "\(s.displayName)  —  \(s.timezone)"
        label.isEditable = false; label.isBordered = false; label.drawsBackground = false
        label.textColor = NSColor(red:0xcd/255,green:0xd6/255,blue:0xf4/255,alpha:1)
        label.font = NSFont.systemFont(ofSize: 12)
        cell.addSubview(label)
        return cell
    }
}

// MARK: - Add Person Window

class AddWindow: NSWindow, NSWindowDelegate {
    var onSave: ((Person) -> Void)?
    private var nameField = NSTextField()
    private var cityField = GeoAutocompleteField()
    private var photoPreview = NSImageView()
    private var photoPath = ""
    private var selectedGeo: GeoSuggestion?

    convenience init() {
        let W: CGFloat = 380, H: CGFloat = 270
        let screen = NSScreen.main!
        self.init(
            contentRect: NSRect(
                x: (screen.frame.width - W)/2,
                y: (screen.frame.height - H)/2,
                width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        title = "Add Person"
        delegate = self
        isReleasedWhenClosed = false
        buildUI()
    }

    private func buildUI() {
        guard let cv = contentView else { return }
        let pad: CGFloat = 20, fw = cv.bounds.width - pad*2
        var y = cv.bounds.height - pad

        func label(_ t: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(frame: NSRect(x:pad,y:y,width:fw,height:16))
            l.stringValue = t; l.isEditable = false; l.isBordered = false
            l.drawsBackground = false
            l.font = NSFont.boldSystemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            return l
        }

        // Name
        y -= 18; cv.addSubview(label("NAME", y: y))
        y -= 30
        nameField = NSTextField(frame: NSRect(x:pad,y:y,width:fw,height:26))
        nameField.placeholderString = "John Doe"
        nameField.focusRingType = .none
        cv.addSubview(nameField)

        // City
        y -= 22; cv.addSubview(label("CITY / TIMEZONE", y: y))
        y -= 30
        cityField = GeoAutocompleteField(frame: NSRect(x:pad,y:y,width:fw,height:26))
        cityField.setup()
        cityField.onSelect = { [weak self] geo in self?.selectedGeo = geo }
        cv.addSubview(cityField)

        // Photo
        y -= 22; cv.addSubview(label("PHOTO (optional)", y: y))
        y -= 52
        photoPreview = NSImageView(frame: NSRect(x:pad,y:y,width:44,height:44))
        photoPreview.wantsLayer = true
        photoPreview.layer?.cornerRadius = 22
        photoPreview.layer?.masksToBounds = true
        photoPreview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        photoPreview.imageScaling = .scaleProportionallyUpOrDown
        cv.addSubview(photoPreview)

        let chooseBtn = NSButton(frame: NSRect(x:pad+54,y:y+10,width:130,height:24))
        chooseBtn.title = "Choose image…"
        chooseBtn.bezelStyle = .rounded
        chooseBtn.font = NSFont.systemFont(ofSize: 12)
        chooseBtn.target = self; chooseBtn.action = #selector(choosePhoto)
        cv.addSubview(chooseBtn)

        // Buttons
        let cancel = NSButton(frame: NSRect(x:pad,y:14,width:80,height:28))
        cancel.title = "Cancel"; cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(cancelAction)
        cv.addSubview(cancel)

        let save = NSButton(frame: NSRect(x:cv.bounds.width-pad-80,y:14,width:80,height:28))
        save.title = "Save"; save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.target = self; save.action = #selector(saveAction)
        cv.addSubview(save)
    }

    @objc func choosePhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url {
            photoPath = processPhoto(src: url.path, name: nameField.stringValue.isEmpty ? "person" : nameField.stringValue)
            let imgPath = photoPath.isEmpty ? url.path : photoPath
            if let img = NSImage(contentsOfFile: imgPath) { photoPreview.image = img }
        }
    }

    private func processPhoto(src: String, name: String) -> String {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/sketchybar/tz_photos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: .alphanumerics.inverted).joined()
        let dest = dir.appendingPathComponent("\(safe)_\(Int(Date().timeIntervalSince1970)).png").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/magick")
        proc.arguments = [src, "-resize","80x80^","-gravity","center","-extent","80x80",
                          "(", "+clone", "-alpha","extract", "-draw","fill white circle 40,40 40,0",
                          "-alpha","off", ")", "-compose","CopyOpacity","-composite", dest]
        try? proc.run(); proc.waitUntilExit()
        return FileManager.default.fileExists(atPath: dest) ? dest : src
    }

    @objc func saveAction() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { nameField.becomeFirstResponder(); return }
        guard let geo = selectedGeo else {
            cityField.becomeFirstResponder()
            let a = NSAlert()
            a.messageText = "Select a city"
            a.informativeText = "Type a city name and pick a result from the list."
            a.runModal()
            return
        }
        cityField.closePanel()
        let person = Person(name: name, location: geo.displayName, timezone: geo.timezone, photo: photoPath)
        close()
        onSave?(person)
    }

    @objc func cancelAction() {
        cityField.closePanel()
        close()
    }

    func windowWillClose(_ n: Notification) { cityField.closePanel() }
}

// MARK: - Person Row

class PersonRowView: NSView {
    var person: Person; var index: Int; weak var app: AppDelegate?
    init(frame: NSRect, person: Person, index: Int, app: AppDelegate) {
        self.person = person; self.index = index; self.app = app
        super.init(frame: frame); setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setup() {
        let sz: CGFloat = 40, mg: CGFloat = 14
        let photo = NSView(frame: NSRect(x:mg,y:(bounds.height-sz)/2,width:sz,height:sz))
        photo.wantsLayer = true
        photo.layer?.cornerRadius = sz/2; photo.layer?.masksToBounds = true

        if !person.photo.isEmpty, let img = NSImage(contentsOfFile: person.photo) {
            let iv = NSImageView(frame: photo.bounds)
            iv.image = img; iv.imageScaling = .scaleProportionallyUpOrDown
            photo.addSubview(iv)
        } else {
            let cols: [CGColor] = [
                NSColor(red:0x89/255,green:0xb4/255,blue:0xfa/255,alpha:1).cgColor,
                NSColor(red:0xa6/255,green:0xe3/255,blue:0xa1/255,alpha:1).cgColor,
                NSColor(red:0xf3/255,green:0x8b/255,blue:0xa8/255,alpha:1).cgColor,
                NSColor(red:0xfa/255,green:0xb3/255,blue:0x87/255,alpha:1).cgColor,
                NSColor(red:0xcb/255,green:0xa6/255,blue:0xf7/255,alpha:1).cgColor,
                NSColor(red:0x89/255,green:0xdc/255,blue:0xeb/255,alpha:1).cgColor,
            ]
            photo.layer?.backgroundColor = cols[abs(person.name.hashValue) % cols.count]
            let l = tf(String(person.name.prefix(1)).uppercased(), 17, true, .white)
            l.frame = photo.bounds; l.alignment = .center; photo.addSubview(l)
        }
        addSubview(photo)

        let tx = mg + sz + 10
        let nl = tf(person.name, 13, true, NSColor(red:0xcd/255,green:0xd6/255,blue:0xf4/255,alpha:1))
        nl.frame = NSRect(x:tx,y:bounds.height/2,width:160,height:20)
        addSubview(nl)

        let cl = tf(person.location, 11, false, NSColor(red:0x6c/255,green:0x70/255,blue:0x86/255,alpha:1))
        cl.frame = NSRect(x:tx,y:bounds.height/2-18,width:160,height:16)
        addSubview(cl)

        let (ts, ds) = timeInfo(for: person.timezone)
        let rx = bounds.width - 90
        let tl = tf(ts, 13, false, NSColor(red:0xcd/255,green:0xd6/255,blue:0xf4/255,alpha:1))
        tl.frame = NSRect(x:rx,y:bounds.height/2,width:76,height:20); tl.alignment = .right
        addSubview(tl)

        let dc = ds == "same time"
            ? NSColor(red:0xa6/255,green:0xe3/255,blue:0xa1/255,alpha:1)
            : NSColor(red:0x6c/255,green:0x70/255,blue:0x86/255,alpha:1)
        let dl = tf(ds, 11, false, dc)
        dl.frame = NSRect(x:rx,y:bounds.height/2-18,width:76,height:16); dl.alignment = .right
        addSubview(dl)

        let del = NSButton(frame: NSRect(x:bounds.width-18,y:(bounds.height-14)/2,width:14,height:14))
        del.title = "✕"; del.isBordered = false; del.bezelStyle = .inline
        del.font = NSFont.systemFont(ofSize: 9)
        del.contentTintColor = NSColor(red:0x6c/255,green:0x70/255,blue:0x86/255,alpha:1)
        del.target = self; del.action = #selector(deleteSelf)
        addSubview(del)

        let sep = NSView(frame: NSRect(x:mg,y:0,width:bounds.width-mg*2,height:0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor(white:1,alpha:0.07).cgColor
        addSubview(sep)
    }

    private func tf(_ s: String, _ size: CGFloat, _ bold: Bool, _ color: NSColor) -> NSTextField {
        let f = NSTextField(); f.stringValue = s
        f.isEditable = false; f.isBordered = false; f.drawsBackground = false
        f.textColor = color
        f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return f
    }

    @objc func deleteSelf() { app?.deletePerson(at: index) }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var people: [Person] = []
    var addWindow: AddWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        people = loadPeople()
        buildPanel()
    }

    func buildPanel() {
        let W: CGFloat = 380, rowH: CGFloat = 64, footH: CGFloat = 52
        let H = footH + max(1, CGFloat(people.count)) * rowH
        let screen = NSScreen.main!
        let x = screen.frame.width - W - 20
        let y = screen.frame.height - NSStatusBar.system.thickness - H - 4

        if panel == nil {
            panel = NSPanel(
                contentRect: NSRect(x:x,y:y,width:W,height:H),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.hasShadow = true
        }
        panel.backgroundColor = NSColor(red:0x1e/255,green:0x20/255,blue:0x30/255,alpha:0.97)
        panel.setFrame(NSRect(x:x,y:y,width:W,height:H), display:true)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        redraw(W:W, H:H, rowH:rowH, footH:footH)
        panel.makeKeyAndOrderFront(nil)
    }

    func redraw(W: CGFloat, H: CGFloat, rowH: CGFloat, footH: CGFloat) {
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        guard let cv = panel.contentView else { return }

        for (i, p) in people.enumerated() {
            let row = PersonRowView(
                frame: NSRect(x:0,y:H-CGFloat(i+1)*rowH,width:W,height:rowH),
                person: p, index: i, app: self)
            cv.addSubview(row)
        }

        let footer = NSView(frame: NSRect(x:0,y:0,width:W,height:footH))
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(white:1,alpha:0.04).cgColor
        cv.addSubview(footer)

        let btn = NSButton(frame: NSRect(x:14,y:12,width:120,height:28))
        btn.title = "＋  Add person"; btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12)
        btn.target = self; btn.action = #selector(showAdd)
        footer.addSubview(btn)
    }

    @objc func showAdd() {
        addWindow = AddWindow()
        addWindow?.onSave = { [weak self] person in
            self?.people.append(person)
            savePeople(self?.people ?? [])
            self?.buildPanel()
        }
        addWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func deletePerson(at index: Int) {
        guard index < people.count else { return }
        people.remove(at: index)
        savePeople(people)
        buildPanel()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
