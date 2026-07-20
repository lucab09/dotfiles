import AppKit
import Contacts
import EventKit
import Foundation
import SwiftUI

// MARK: - Theme

private let panelBlack = Color.black
private let surface = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
private let surfaceHover = Color(red: 44 / 255, green: 44 / 255, blue: 47 / 255)
private let primaryText = Color.white
private let secondaryText = Color.white.opacity(0.62)
private let subtleText = Color.white.opacity(0.38)
private let accent = Color(red: 1.0, green: 0.27, blue: 0.25)

// MARK: - Calendar model

enum CalendarAuthorizationState {
    case notDetermined
    case loading
    case authorized
    case denied
    case restricted
    case failed(String)
}

struct CalendarAttendeeViewModel: Identifiable {
    let id: String
    let name: String
    let imageData: Data?

    var initials: String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

enum MeetingProvider: String {
    case googleMeet = "Google Meet"
    case zoom = "Zoom"
    case microsoftTeams = "Microsoft Teams"
}

struct MeetingLinkViewModel {
    let provider: MeetingProvider
    let url: URL
    let sourceField: String
}

struct CalendarEventViewModel: Identifiable {
    let id: String
    let eventIdentifier: String
    let externalIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let calendarColor: Color
    let attendees: [CalendarAttendeeViewModel]
    let meetingLink: MeetingLinkViewModel?

    var hasEnded: Bool { endDate < Date() }
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published var authorizationState: CalendarAuthorizationState = .notDetermined
    @Published var events: [CalendarEventViewModel] = []
    @Published var displayedDate = Date()

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private var storeObserver: NSObjectProtocol?
    private var accessRequestStarted = false
    private var contactsAccessRequestStarted = false
    private var lastKnownToday = Calendar.current.startOfDay(for: Date())

    init() {
        updateAuthorizationState()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    func prepareForExpansion() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            requestAccessIfNeeded()
        case .fullAccess:
            authorizationState = .authorized
            refresh()
        case .denied:
            authorizationState = .denied
        case .restricted:
            authorizationState = .restricted
        case .writeOnly:
            authorizationState = .denied
        default:
            authorizationState = .failed("Stato autorizzazione non supportato")
        }
    }

    func selectDate(_ date: Date) {
        guard !Calendar.current.isDate(date, inSameDayAs: displayedDate) else { return }
        displayedDate = date
        refresh()
    }

    func refreshIfDayChanged() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard today != lastKnownToday else { return }

        let wasShowingToday = calendar.isDate(displayedDate, inSameDayAs: lastKnownToday)
        lastKnownToday = today
        if wasShowingToday { displayedDate = today }
        refresh()
    }

    func refresh() {
        guard isAuthorized else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: displayedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        events = eventStore.events(matching: predicate)
            .map { event in
                let eventIdentifier = event.eventIdentifier ?? UUID().uuidString
                let externalIdentifier = event.calendarItemExternalIdentifier ?? eventIdentifier
                let nsColor = NSColor(cgColor: event.calendar.cgColor) ?? .systemBlue
                return CalendarEventViewModel(
                    id: "\(eventIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    eventIdentifier: eventIdentifier,
                    externalIdentifier: externalIdentifier,
                    title: event.title?.isEmpty == false ? event.title! : "Evento senza titolo",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.isEmpty == false ? event.location : nil,
                    calendarColor: Color(nsColor: nsColor),
                    attendees: attendeeViewModels(for: event),
                    meetingLink: meetingLink(for: event)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startDate < rhs.startDate
            }
    }

    private func meetingLink(for event: EKEvent) -> MeetingLinkViewModel? {
        var candidates: [(field: String, url: URL)] = []
        if let url = event.url { candidates.append(("url", url)) }
        candidates += detectedURLs(in: event.location).map { ("location", $0) }
        candidates += detectedURLs(in: event.structuredLocation?.title).map { ("structuredLocation", $0) }
        candidates += detectedURLs(in: event.notes).map { ("notes", $0) }

        for candidate in candidates {
            let host = (candidate.url.host ?? "").lowercased()
            let scheme = (candidate.url.scheme ?? "").lowercased()
            let provider: MeetingProvider?
            if host == "meet.google.com" || host.hasSuffix(".meet.google.com") {
                provider = .googleMeet
            } else if host == "zoom.us" || host.hasSuffix(".zoom.us") ||
                        host == "zoomgov.com" || host.hasSuffix(".zoomgov.com") ||
                        scheme.hasPrefix("zoom") {
                provider = .zoom
            } else if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") ||
                        host == "teams.live.com" || host.hasSuffix(".teams.live.com") ||
                        host == "teams.cloud.microsoft" || host.hasSuffix(".teams.cloud.microsoft") ||
                        scheme == "msteams" {
                provider = .microsoftTeams
            } else {
                provider = nil
            }

            if let provider {
                return MeetingLinkViewModel(provider: provider, url: candidate.url, sourceField: candidate.field)
            }
        }
        return nil
    }

    private func detectedURLs(in text: String?) -> [URL] {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    private func attendeeViewModels(for event: EKEvent) -> [CalendarAttendeeViewModel] {
        let attendees = (event.attendees ?? []).filter {
            !$0.isCurrentUser && $0.participantType == .person
        }
        guard !attendees.isEmpty else { return [] }

        requestContactsAccessIfNeeded()
        return attendees.enumerated().map { index, participant in
            let contact = matchingContact(for: participant)
            let participantName = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let contactName = contact.flatMap { CNContactFormatter.string(from: $0, style: .fullName) }
            let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            let name = contactName?.isEmpty == false
                ? contactName!
                : (participantName?.isEmpty == false ? participantName! : email)

            return CalendarAttendeeViewModel(
                id: "\(participant.url.absoluteString)-\(index)",
                name: name,
                imageData: contact?.thumbnailImageData
            )
        }
    }

    private func matchingContact(for participant: EKParticipant) -> CNContact? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        return try? contactStore
            .unifiedContacts(matching: participant.contactPredicate, keysToFetch: keys)
            .first
    }

    private func requestContactsAccessIfNeeded() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined,
              !contactsAccessRequestStarted else { return }
        contactsAccessRequestStarted = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            if (try? await contactStore.requestAccess(for: .contacts)) == true {
                refresh()
            }
        }
    }

    func openInCalendar(_ event: CalendarEventViewModel) {
        let uid = event.externalIdentifier
        let script = """
        on run argv
            set requestedUID to item 1 of argv
            tell application "Calendar"
                repeat with currentCalendar in calendars
                    set matchingEvents to (every event of currentCalendar whose uid is requestedUID)
                    if (count of matchingEvents) > 0 then
                        show item 1 of matchingEvents
                        activate
                        return "shown"
                    end if
                end repeat
                activate
            end tell
            return "not-found"
        end run
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--", uid]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    DispatchQueue.main.async { Self.openCalendarApplication() }
                }
            } catch {
                DispatchQueue.main.async { Self.openCalendarApplication() }
            }
        }
    }

    func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess
    }

    private func requestAccessIfNeeded() {
        guard !accessRequestStarted else { return }
        accessRequestStarted = true
        authorizationState = .loading

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                authorizationState = granted ? .authorized : .denied
                if granted { refresh() }
            } catch {
                authorizationState = .failed(error.localizedDescription)
            }
        }
    }

    private func updateAuthorizationState() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: authorizationState = .notDetermined
        case .fullAccess: authorizationState = .authorized
        case .denied, .writeOnly: authorizationState = .denied
        case .restricted: authorizationState = .restricted
        default: authorizationState = .failed("Stato autorizzazione non supportato")
        }
    }

    nonisolated private static func openCalendarApplication() {
        let url = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Presentation state

@MainActor
final class NotchPresentationState: ObservableObject {
    @Published var isExpanded = false
    @Published var notchHeight: CGFloat = 38
}

// MARK: - SwiftUI views

struct CalendarNotchView: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var presentation: NotchPresentationState
    let onHoverChanged: (Bool) -> Void

    @State private var weekOffset = 0
    @State private var weekNavigationDirection = 1

    var body: some View {
        ZStack(alignment: .top) {
            if presentation.isExpanded {
                panelBlack
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                // Il notch fisico fornisce già la superficie nera: a riposo
                // manteniamo soltanto l'area trasparente per il tracking hover.
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: presentation.isExpanded ? 24 : 0,
                bottomLeadingRadius: presentation.isExpanded ? 28 : 0,
                bottomTrailingRadius: presentation.isExpanded ? 28 : 0,
                topTrailingRadius: presentation.isExpanded ? 24 : 0,
                style: .continuous
            )
        )
        .onHover(perform: onHoverChanged)
    }

    private var expandedContent: some View {
        VStack(spacing: 14) {
            monthAndWeek
                .padding(.top, max(presentation.notchHeight + 8, 48))

            Divider()
                .overlay(Color.white.opacity(0.09))
                .padding(.horizontal, 22)

            eventContent
        }
        .padding(.bottom, 18)
    }

    private var monthAndWeek: some View {
        VStack(spacing: 12) {
            Text(monthTitle)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryText)

            HStack(spacing: 4) {
                weekNavigationButton(systemName: "chevron.left", offset: -1)

                ZStack {
                    weekDays
                        .id(weekOffset)
                        .transition(weekTransition)
                }
                .frame(maxWidth: .infinity)
                .clipped()

                weekNavigationButton(systemName: "chevron.right", offset: 1)
            }
            .padding(.horizontal, 12)
        }
    }

    private var weekDays: some View {
        HStack(spacing: 0) {
            ForEach(weekDates, id: \.self) { date in
                dayButton(for: date)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayButton(for date: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: model.displayedDate)

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                model.selectDate(date)
            }
        } label: {
            VStack(spacing: 5) {
                Text(weekdaySymbol(for: date))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isToday ? accent : subtleText)

                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? primaryText : (isToday ? accent : secondaryText))
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(accent)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func weekNavigationButton(systemName: String, offset: Int) -> some View {
        Button {
            weekNavigationDirection = offset
            withAnimation(.easeInOut(duration: 0.24)) {
                weekOffset += offset
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryText)
                .frame(width: 22, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offset < 0 ? "Settimana precedente" : "Settimana successiva")
    }

    private var weekTransition: AnyTransition {
        let incomingEdge: Edge = weekNavigationDirection > 0 ? .trailing : .leading
        let outgoingEdge: Edge = weekNavigationDirection > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incomingEdge).combined(with: .opacity),
            removal: .move(edge: outgoingEdge).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var eventContent: some View {
        switch model.authorizationState {
        case .notDetermined, .loading:
            stateView(icon: "calendar", title: "Accesso al calendario", message: "Autorizzazione in corso…") {
                ProgressView().controlSize(.small)
            }
        case .denied, .restricted:
            stateView(icon: "calendar.badge.exclamationmark", title: "Accesso non consentito", message: "Abilita Calendar in Privacy e sicurezza.") {
                Button("Apri Impostazioni") { model.openCalendarPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.16))
            }
        case .failed(let message):
            stateView(icon: "exclamationmark.triangle", title: "Calendario non disponibile", message: message) {
                EmptyView()
            }
        case .authorized:
            if model.events.isEmpty {
                stateView(icon: "calendar.badge.checkmark", title: emptyStateTitle, message: emptyStateMessage) {
                    EmptyView()
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 9) {
                        ForEach(model.events) { event in
                            EventRow(event: event) { model.openInCalendar(event) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 244)
            }
        }
    }

    private func stateView<Action: View>(icon: String, title: String, message: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(secondaryText)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.horizontal, 24)
    }

    private var emptyStateTitle: String {
        Calendar.current.isDateInToday(model.displayedDate) ? "Nessun evento oggi" : "Nessun evento"
    }

    private var emptyStateMessage: String {
        if Calendar.current.isDateInToday(model.displayedDate) { return "La giornata è libera." }
        return model.displayedDate
            .formatted(.dateTime.weekday(.wide).day().month(.wide))
            .capitalized
    }

    private var visibleWeekDate: Date {
        let today = Date()
        return Calendar.current.date(byAdding: .weekOfYear, value: weekOffset, to: today) ?? today
    }

    private var monthTitle: String {
        let month = visibleWeekDate.formatted(.dateTime.month(.wide)).capitalized
        let year = visibleWeekDate.formatted(.dateTime.year())
        return "\(month), \(year)"
    }

    private var weekDates: [Date] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: visibleWeekDate) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func weekdaySymbol(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.narrow)).uppercased()
    }
}

struct AttendeeAvatarStack: View {
    let attendees: [CalendarAttendeeViewModel]

    private var visibleAttendees: [CalendarAttendeeViewModel] {
        Array(attendees.prefix(attendees.count > 3 ? 2 : 3))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(visibleAttendees.enumerated()), id: \.element.id) { index, attendee in
                avatar(for: attendee)
                    .offset(x: CGFloat(index) * 16)
                    .zIndex(Double(visibleAttendees.count - index))
            }

            if attendees.count > visibleAttendees.count {
                Circle()
                    .fill(surfaceHover)
                    .overlay {
                        Text("+\(attendees.count - visibleAttendees.count)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(secondaryText)
                    }
                    .overlay { Circle().stroke(panelBlack, lineWidth: 2) }
                    .frame(width: 28, height: 28)
                    .offset(x: CGFloat(visibleAttendees.count) * 16)
            }
        }
        .frame(width: 58, height: 32, alignment: .leading)
    }

    @ViewBuilder
    private func avatar(for attendee: CalendarAttendeeViewModel) -> some View {
        if let data = attendee.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay { Circle().stroke(panelBlack, lineWidth: 2) }
        } else {
            Circle()
                .fill(surfaceHover)
                .overlay {
                    Text(attendee.initials)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                }
                .overlay { Circle().stroke(panelBlack, lineWidth: 2) }
                .frame(width: 28, height: 28)
        }
    }
}

struct EventRow: View {
    let event: CalendarEventViewModel
    let action: () -> Void
    @State private var isHovered = false
    @State private var isJoinHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if event.attendees.isEmpty {
                        Image(systemName: "calendar")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(event.calendarColor)
                            .frame(width: 58)
                    } else {
                        AttendeeAvatarStack(attendees: event.attendees)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(eventTime)
                            if let location = displayLocation {
                                Text("•")
                                Text(location).lineLimit(1)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryText)
                    }

                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(subtleText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            if let meeting = event.meetingLink {
                Button {
                    NSWorkspace.shared.open(meeting.url)
                } label: {
                    Text("Partecipa")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(meetingColor(for: meeting.provider).opacity(isJoinHovered ? 1 : 0.86))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isJoinHovered = $0 }
                .help("Partecipa con \(meeting.provider.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovered ? surfaceHover : surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .opacity(event.hasEnded ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }

    private var displayLocation: String? {
        event.meetingLink?.sourceField == "location" ? nil : event.location
    }

    private func meetingColor(for provider: MeetingProvider) -> Color {
        switch provider {
        case .googleMeet:
            return Color(red: 0 / 255, green: 172 / 255, blue: 71 / 255)
        case .zoom:
            return Color(red: 45 / 255, green: 140 / 255, blue: 255 / 255)
        case .microsoftTeams:
            return Color(red: 98 / 255, green: 100 / 255, blue: 167 / 255)
        }
    }

    private var eventTime: String {
        if event.isAllDay { return "Tutto il giorno" }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController: NSObject {
    private let model = CalendarModel()
    private let presentation = NotchPresentationState()
    private let sensorHeight: CGFloat = 6
    private let expandedWidth: CGFloat = 420
    private let expandedHeight: CGFloat = 450
    private let animationDuration = 0.22
    private let closeDelay = 0.25

    private var panel: NotchPanel?
    private var hostingView: NSHostingView<CalendarNotchView>?
    private var notchScreen: NSScreen?
    private var notchRect: NSRect = .zero
    private var closeWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var dayTimer: Timer?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenConfigurationChanged() }
        }
        dayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshIfDayChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        dayTimer?.invalidate()
    }

    func start() {
        guard updateNotchGeometry() else {
            NSApp.terminate(nil)
            return
        }
        buildPanelIfNeeded()
        movePanel(animated: false)
        panel?.orderFrontRegardless()
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }

        let rootView = CalendarNotchView(
            model: model,
            presentation: presentation,
            onHoverChanged: { [weak self] isInside in
                if isInside { self?.expand() } else { self?.scheduleCollapse() }
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.borderWidth = 0
        hosting.layer?.shadowOpacity = 0

        let newPanel = NotchPanel(
            contentRect: closedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.ignoresMouseEvents = false
        newPanel.contentView = hosting

        hostingView = hosting
        panel = newPanel
    }

    private func expand() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        guard !presentation.isExpanded else { return }

        model.prepareForExpansion()
        withAnimation(.easeInOut(duration: animationDuration)) {
            presentation.isExpanded = true
        }
        movePanel(animated: true)
    }

    private func scheduleCollapse() {
        closeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    private func collapse() {
        guard presentation.isExpanded else { return }
        withAnimation(.easeInOut(duration: animationDuration * 0.8)) {
            presentation.isExpanded = false
        }
        movePanel(animated: true)
    }

    private func movePanel(animated: Bool, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        let target = presentation.isExpanded ? expandedFrame : closedFrame
        guard animated else {
            panel.setFrame(target, display: true)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: {
            completion?()
        }
    }

    private func screenConfigurationChanged() {
        guard updateNotchGeometry() else {
            panel?.orderOut(nil)
            NSApp.terminate(nil)
            return
        }
        panel?.orderFrontRegardless()
        movePanel(animated: false)
    }

    @discardableResult
    private func updateNotchGeometry() -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return false }
        notchScreen = screen

        let topInset = screen.safeAreaInsets.top
        let leftEdge = screen.auxiliaryTopLeftArea?.maxX
        let rightEdge = screen.auxiliaryTopRightArea?.minX
        let fallbackWidth = min(220, screen.frame.width * 0.18)
        let minX: CGFloat
        let width: CGFloat

        if let leftEdge, let rightEdge, rightEdge > leftEdge {
            minX = leftEdge
            width = rightEdge - leftEdge
        } else {
            width = fallbackWidth
            minX = screen.frame.midX - width / 2
        }

        notchRect = NSRect(
            x: minX,
            y: screen.frame.maxY - topInset,
            width: width,
            height: topInset
        )
        presentation.notchHeight = topInset
        return true
    }

    private var closedFrame: NSRect {
        NSRect(
            x: notchRect.minX,
            y: notchRect.minY - sensorHeight,
            width: notchRect.width,
            height: notchRect.height + sensorHeight
        )
    }

    private var expandedFrame: NSRect {
        guard let screen = notchScreen else { return closedFrame }
        let width = min(expandedWidth, screen.frame.width - 24)
        let height = min(expandedHeight, screen.frame.height - 24)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }
}

// MARK: - App lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.panelController = NotchPanelController()
            self?.panelController?.start()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
