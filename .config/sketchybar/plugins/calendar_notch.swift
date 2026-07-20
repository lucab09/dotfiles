import AppKit
import Contacts
import CryptoKit
import EventKit
import Foundation
import Network
import Security
import SwiftUI

// MARK: - Theme

private let panelBlack = Color.black
private let surface = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
private let surfaceHover = Color(red: 44 / 255, green: 44 / 255, blue: 47 / 255)
private let primaryText = Color.white
private let secondaryText = Color.white.opacity(0.62)
private let subtleText = Color.white.opacity(0.38)
private let accent = Color(red: 1.0, green: 0.27, blue: 0.25)

// MARK: - Google OAuth

enum GoogleOAuthScope {
    static let contactsReadonly = "https://www.googleapis.com/auth/contacts.readonly"
}

struct GoogleOAuthConfiguration: Decodable {
    let clientID: String
    let clientSecret: String
    let authorizationURL: URL
    let tokenURL: URL
    let redirectURIs: [URL]

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Calendar Notch/google-oauth-client.json")

    private struct Document: Decodable {
        let installed: Installed
    }

    private struct Installed: Decodable {
        let clientID: String
        let clientSecret: String
        let authURI: URL
        let tokenURI: URL
        let redirectURIs: [URL]

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case authURI = "auth_uri"
            case tokenURI = "token_uri"
            case redirectURIs = "redirect_uris"
        }
    }

    static func load(from url: URL = fileURL) throws -> GoogleOAuthConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GoogleOAuthError.configurationMissing(url.path)
        }

        do {
            let installed = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)).installed
            guard !installed.clientID.isEmpty,
                  !installed.clientSecret.isEmpty,
                  installed.authURI.scheme?.lowercased() == "https",
                  installed.tokenURI.scheme?.lowercased() == "https",
                  installed.redirectURIs.contains(where: { redirectURL in
                      let host = redirectURL.host?.lowercased()
                      return redirectURL.scheme == "http" && (host == "localhost" || host == "127.0.0.1")
                  }) else {
                throw GoogleOAuthError.invalidConfiguration
            }
            return GoogleOAuthConfiguration(
                clientID: installed.clientID,
                clientSecret: installed.clientSecret,
                authorizationURL: installed.authURI,
                tokenURL: installed.tokenURI,
                redirectURIs: installed.redirectURIs
            )
        } catch let error as GoogleOAuthError {
            throw error
        } catch {
            throw GoogleOAuthError.invalidConfiguration
        }
    }
}

struct GoogleOAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String
    var grantedScopes: [String]?

    var isUsable: Bool {
        expiresAt.timeIntervalSinceNow > 60
    }

    func hasGrantedScope(_ scope: String) -> Bool {
        grantedScopes?.contains(scope) == true
    }
}

enum GoogleOAuthError: LocalizedError {
    case configurationMissing(String)
    case invalidConfiguration
    case keychain(OSStatus)
    case randomGeneration
    case listener(String)
    case callbackInvalid
    case stateMismatch
    case authorizationDenied(String)
    case browserOpenFailed
    case invalidResponse
    case tokenExchange(String)
    case missingRefreshToken
    case userInfo(String)
    case accountNotConnected(String)
    case accountMismatch(expected: String, actual: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .configurationMissing(let path):
            return "Configurazione Google OAuth non trovata in \(path)."
        case .invalidConfiguration:
            return "Configurazione Google OAuth non valida."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "errore \(status)"
            return "Portachiavi non disponibile: \(message)."
        case .randomGeneration:
            return "Impossibile generare i parametri di sicurezza OAuth."
        case .listener(let message):
            return "Callback OAuth non disponibile: \(message)."
        case .callbackInvalid:
            return "Callback OAuth non valida."
        case .stateMismatch:
            return "La risposta OAuth non corrisponde alla richiesta originale."
        case .authorizationDenied(let message):
            return message.isEmpty ? "Autorizzazione Google annullata." : message
        case .browserOpenFailed:
            return "Impossibile aprire il browser per Google OAuth."
        case .invalidResponse:
            return "Risposta Google non valida."
        case .tokenExchange(let message):
            return message.isEmpty ? "Scambio token Google non riuscito." : message
        case .missingRefreshToken:
            return "Refresh token Google non disponibile: ripeti l’autorizzazione."
        case .userInfo(let message):
            return message.isEmpty ? "Impossibile leggere l’account Google." : message
        case .accountNotConnected(let email):
            return "L’account Google \(email) non è collegato."
        case .accountMismatch(let expected, let actual):
            return "Hai autorizzato \(actual), ma era richiesto \(expected)."
        case .cancelled:
            return "Autorizzazione Google annullata."
        }
    }
}

struct KeychainTokenStore {
    static let service = "com.lucab09.sketchybar.calendar-notch.google-oauth"
    private static let legacyAccount = "default"

    func load(email: String) throws -> GoogleOAuthToken? {
        try migrateLegacyTokenIfNeeded()
        return try loadRaw(account: normalizedEmail(email))
    }

    func loadAll() throws -> [GoogleOAuthToken] {
        try migrateLegacyTokenIfNeeded()

        var query = serviceQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw status == errSecSuccess ? GoogleOAuthError.invalidResponse : GoogleOAuthError.keychain(status)
        }

        var tokensByEmail: [String: GoogleOAuthToken] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != Self.legacyAccount,
                  let token = try loadRaw(account: account) else { continue }
            tokensByEmail[normalizedEmail(token.email)] = token
        }
        return tokensByEmail.values.sorted {
            $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
        }
    }

    func save(_ token: GoogleOAuthToken) throws {
        let account = normalizedEmail(token.email)
        let query = itemQuery(account: account)
        let data = try JSONEncoder().encode(token)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GoogleOAuthError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw GoogleOAuthError.keychain(updateStatus)
        }
    }

    func delete(email: String) throws {
        try deleteRaw(account: normalizedEmail(email))
    }

    func deleteAll() throws {
        let status = SecItemDelete(serviceQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.keychain(status)
        }
    }

    private func migrateLegacyTokenIfNeeded() throws {
        guard let token = try loadRaw(account: Self.legacyAccount) else { return }
        try save(token)
        try deleteRaw(account: Self.legacyAccount)
    }

    private func loadRaw(account: String) throws -> GoogleOAuthToken? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GoogleOAuthError.keychain(status)
        }
        guard let token = try? JSONDecoder().decode(GoogleOAuthToken.self, from: data) else {
            try? deleteRaw(account: account)
            throw GoogleOAuthError.invalidResponse
        }
        return token
    }

    private func deleteRaw(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.keychain(status)
        }
    }

    private var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]
    }

    private func itemQuery(account: String) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] = account
        return query
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

final class LoopbackOAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "calendar-notch.google-oauth-loopback")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?
    private var started = false
    private var completed = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleOAuthError.listener(error.localizedDescription)
        }
    }

    deinit {
        listener.cancel()
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.started else {
                    continuation.resume(throwing: GoogleOAuthError.listener("listener già avviato"))
                    return
                }
                self.started = true
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.receiveRequest(on: connection, buffer: Data())
                }
                self.listener.start(queue: self.queue)
            }
        }
        guard let url = URL(string: "http://localhost:\(port)") else {
            throw GoogleOAuthError.listener("redirect URI non valido")
        }
        return url
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pendingCallback {
                    self.pendingCallback = nil
                    continuation.resume(with: pending)
                } else if self.completed {
                    continuation.resume(throwing: GoogleOAuthError.cancelled)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.finish(with: .failure(GoogleOAuthError.cancelled))
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                finish(with: .failure(GoogleOAuthError.listener("porta non disponibile")))
                return
            }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case .failed(let error):
            finish(with: .failure(GoogleOAuthError.listener(error.localizedDescription)))
        case .cancelled:
            if !completed { finish(with: .failure(GoogleOAuthError.cancelled)) }
        default:
            break
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = buffer
            if let data { requestData.append(data) }

            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                self.handleRequest(requestData, connection: connection)
            } else if let error {
                connection.cancel()
                self.finish(with: .failure(GoogleOAuthError.listener(error.localizedDescription)))
            } else {
                self.receiveRequest(on: connection, buffer: requestData)
            }
        }
    }

    private func handleRequest(_ data: Data, connection: NWConnection) {
        let callbackURL: URL? = {
            guard let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { return nil }
            return URL(string: "http://localhost\(parts[1])")
        }()

        let succeeded = callbackURL != nil
        let title = succeeded ? "Autorizzazione completata" : "Autorizzazione non riuscita"
        let message = succeeded
            ? "Puoi chiudere questa pagina e tornare al widget del notch."
            : "Chiudi questa pagina e riprova dal widget del notch."
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system;padding:40px;background:#111;color:#fff">
        <h2>\(title)</h2><p>\(message)</p></body></html>
        """
        let response = """
        HTTP/1.1 \(succeeded ? "200 OK" : "400 Bad Request")\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        finish(with: callbackURL.map(Result.success) ?? .failure(GoogleOAuthError.callbackInvalid))
    }

    private func finish(with result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        listener.cancel()

        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: result.failure ?? GoogleOAuthError.cancelled)
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingCallback = result
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@MainActor
final class GoogleOAuthManager: ObservableObject {
    private let tokenStore = KeychainTokenStore()
    private let session: URLSession
    private var authorizationTask: Task<GoogleOAuthToken, Error>?
    private var authorizationExpectedEmail: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func storedTokens() throws -> [GoogleOAuthToken] {
        try tokenStore.loadAll()
    }

    func contactEnabledTokens() throws -> [GoogleOAuthToken] {
        try storedTokens().filter { $0.hasGrantedScope(GoogleOAuthScope.contactsReadonly) }
    }

    func hasStoredToken(for email: String? = nil) -> Bool {
        guard let tokens = try? storedTokens() else { return false }
        guard let email else { return !tokens.isEmpty }
        return tokens.contains { emailsMatch($0.email, email) }
    }

    func validAccessToken(for email: String) async throws -> GoogleOAuthToken {
        guard let token = try tokenStore.load(email: email) else {
            throw GoogleOAuthError.accountNotConnected(email)
        }
        return token.isUsable ? token : try await refresh(token)
    }

    func authorize(
        preferredEmail: String? = nil,
        requireEmailMatch: Bool = false
    ) async throws -> GoogleOAuthToken {
        let expectedEmail: String?
        if requireEmailMatch {
            guard let preferredEmail, !preferredEmail.isEmpty else {
                throw GoogleOAuthError.invalidConfiguration
            }
            expectedEmail = normalizedEmail(preferredEmail)
        } else {
            expectedEmail = nil
        }

        if let authorizationTask {
            if authorizationExpectedEmail == expectedEmail {
                return try await authorizationTask.value
            }
            _ = try? await authorizationTask.value
            self.authorizationTask = nil
            authorizationExpectedEmail = nil
            return try await authorize(
                preferredEmail: preferredEmail,
                requireEmailMatch: requireEmailMatch
            )
        }

        let task = Task { [weak self] () throws -> GoogleOAuthToken in
            guard let self else { throw GoogleOAuthError.cancelled }
            return try await self.performAuthorization(
                preferredEmail: preferredEmail,
                expectedEmail: expectedEmail
            )
        }
        authorizationTask = task
        authorizationExpectedEmail = expectedEmail
        do {
            let token = try await task.value
            authorizationTask = nil
            authorizationExpectedEmail = nil
            return token
        } catch {
            authorizationTask = nil
            authorizationExpectedEmail = nil
            throw error
        }
    }

    func refreshAccessToken(for email: String) async throws -> GoogleOAuthToken {
        guard let token = try tokenStore.load(email: email) else {
            throw GoogleOAuthError.accountNotConnected(email)
        }
        return try await refresh(token)
    }

    func disconnect(email: String? = nil) throws {
        authorizationTask?.cancel()
        authorizationTask = nil
        authorizationExpectedEmail = nil
        if let email {
            try tokenStore.delete(email: email)
        } else {
            try tokenStore.deleteAll()
        }
    }

    private func performAuthorization(
        preferredEmail: String?,
        expectedEmail: String?
    ) async throws -> GoogleOAuthToken {
        let configuration = try GoogleOAuthConfiguration.load()
        let verifier = try randomURLSafeString(byteCount: 64)
        let state = try randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let server = try LoopbackOAuthServer()
        let redirectURI = try await server.start()

        let requestedScopes = [
            "openid",
            "email",
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            GoogleOAuthScope.contactsReadonly
        ]
        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)
        var authorizationQueryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: requestedScopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        if let preferredEmail, !preferredEmail.isEmpty {
            authorizationQueryItems.append(URLQueryItem(name: "login_hint", value: preferredEmail))
        }
        components?.queryItems = authorizationQueryItems
        guard let authorizationURL = components?.url else {
            server.cancel()
            throw GoogleOAuthError.invalidConfiguration
        }
        guard NSWorkspace.shared.open(authorizationURL) else {
            server.cancel()
            throw GoogleOAuthError.browserOpenFailed
        }

        let callbackURL = try await server.waitForCallback()
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleOAuthError.callbackInvalid
        }
        let query = Dictionary(uniqueKeysWithValues: (callback.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard query["state"] == state else { throw GoogleOAuthError.stateMismatch }
        if let oauthError = query["error"] {
            throw GoogleOAuthError.authorizationDenied(query["error_description"] ?? oauthError)
        }
        guard let code = query["code"], !code.isEmpty else { throw GoogleOAuthError.callbackInvalid }

        let response: TokenResponse = try await postTokenRequest(
            configuration: configuration,
            parameters: [
                "client_id": configuration.clientID,
                "client_secret": configuration.clientSecret,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI.absoluteString
            ]
        )
        let email = try await fetchEmail(accessToken: response.accessToken)
        if let expectedEmail, !emailsMatch(email, expectedEmail) {
            throw GoogleOAuthError.accountMismatch(expected: expectedEmail, actual: email)
        }
        let previousRefreshToken = try tokenStore.load(email: email)?.refreshToken
        let token = GoogleOAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previousRefreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            email: email,
            grantedScopes: normalizedScopes(response.scope) ?? requestedScopes.sorted()
        )
        try tokenStore.save(token)
        return token
    }

    private func refresh(_ existing: GoogleOAuthToken) async throws -> GoogleOAuthToken {
        guard let refreshToken = existing.refreshToken, !refreshToken.isEmpty else {
            throw GoogleOAuthError.missingRefreshToken
        }
        let configuration = try GoogleOAuthConfiguration.load()
        let response: TokenResponse = try await postTokenRequest(
            configuration: configuration,
            parameters: [
                "client_id": configuration.clientID,
                "client_secret": configuration.clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
        )
        let token = GoogleOAuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            email: existing.email,
            grantedScopes: normalizedScopes(response.scope) ?? existing.grantedScopes
        )
        try tokenStore.save(token)
        return token
    }

    private func postTokenRequest(
        configuration: GoogleOAuthConfiguration,
        parameters: [String: String]
    ) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(parameters)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleOAuthError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw GoogleOAuthError.tokenExchange(oauthErrorMessage(from: data))
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch let error as GoogleOAuthError {
            throw error
        } catch {
            throw GoogleOAuthError.tokenExchange(error.localizedDescription)
        }
    }

    private func fetchEmail(accessToken: String) async throws -> String {
        guard let url = URL(string: "https://openidconnect.googleapis.com/v1/userinfo") else {
            throw GoogleOAuthError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GoogleOAuthError.userInfo("Google UserInfo non disponibile.")
            }
            let user = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            guard !user.email.isEmpty else { throw GoogleOAuthError.userInfo("Email Google mancante.") }
            return user.email
        } catch let error as GoogleOAuthError {
            throw error
        } catch {
            throw GoogleOAuthError.userInfo(error.localizedDescription)
        }
    }

    private func emailsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedEmail(lhs) == normalizedEmail(rhs)
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedScopes(_ value: String?) -> [String]? {
        guard let value else { return nil }
        let scopes = Set(value.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return scopes.isEmpty ? nil : scopes.sorted()
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw GoogleOAuthError.randomGeneration
        }
        return Data(bytes).base64URLEncodedString()
    }

    private func formEncoded(_ parameters: [String: String]) -> Data {
        let body = parameters.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key.formPercentEncoded)=\(value.formPercentEncoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func oauthErrorMessage(from data: Data) -> String {
        guard let envelope = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) else { return "" }
        return envelope.errorDescription ?? envelope.error
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct UserInfoResponse: Decodable {
        let email: String
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formPercentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? self
    }
}

// MARK: - Google People contact photos

struct GoogleContactPhotoRequest: Sendable {
    let id: String
    let email: String?
    let phoneNumbers: [String]
    let preferredAccountEmail: String?
}

actor GoogleContactPhotoService {
    private struct ContactSnapshot: Codable {
        let fetchedAt: Date
        let contacts: [ContactRecord]
    }

    private struct ContactRecord: Codable {
        let resourceName: String
        let emails: [String]
        let phoneNumbers: [String]
        let photoURL: String?
    }

    private struct PeopleConnectionsPage: Decodable {
        let connections: [PeoplePerson]?
        let nextPageToken: String?
    }

    private struct PeoplePerson: Decodable {
        let resourceName: String?
        let emailAddresses: [PeopleValue]?
        let phoneNumbers: [PeopleValue]?
        let photos: [PeoplePhoto]?
    }

    private struct PeopleValue: Decodable {
        let value: String?
    }

    private struct PeoplePhoto: Decodable {
        let url: String?
        let `default`: Bool?
    }

    private struct PhotoCandidate {
        let accountEmail: String
        let record: ContactRecord
    }

    private enum PeopleError: Error {
        case invalidResponse
        case unavailable
    }

    private let oauthManager: GoogleOAuthManager
    private let session: URLSession
    private let fileManager: FileManager
    private let cacheRoot: URL
    private let cacheLifetime: TimeInterval = 6 * 60 * 60
    private let maximumImageBytes = 5 * 1024 * 1024
    private var snapshots: [String: ContactSnapshot] = [:]

    init(
        oauthManager: GoogleOAuthManager,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.oauthManager = oauthManager
        self.session = session
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Calendar Notch/Google Contact Photos", isDirectory: true)
    }

    func resolve(
        _ requests: [GoogleContactPhotoRequest],
        forceRefresh: Bool = false
    ) async -> [String: Data] {
        guard !requests.isEmpty else { return [:] }

        let tokens: [GoogleOAuthToken]
        do {
            tokens = try await oauthManager.contactEnabledTokens()
        } catch {
            return [:]
        }
        guard !tokens.isEmpty else { return [:] }

        let sortedTokens = tokens.sorted {
            normalizedEmail($0.email) < normalizedEmail($1.email)
        }
        var availableSnapshots: [String: ContactSnapshot] = [:]
        for token in sortedTokens {
            guard !Task.isCancelled else { return [:] }
            let accountEmail = normalizedEmail(token.email)
            let cached = snapshots[accountEmail] ?? loadSnapshot(accountEmail: accountEmail)
            if let cached { snapshots[accountEmail] = cached }

            if !forceRefresh,
               let cached,
               Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
                availableSnapshots[accountEmail] = cached
                continue
            }

            do {
                let refreshed = try await fetchSnapshot(for: token)
                snapshots[accountEmail] = refreshed
                availableSnapshots[accountEmail] = refreshed
                storeSnapshot(refreshed, accountEmail: accountEmail)
            } catch {
                if let cached { availableSnapshots[accountEmail] = cached }
            }
        }

        guard !availableSnapshots.isEmpty else { return [:] }
        var resolved: [String: Data] = [:]
        var loadedImages: [String: Data] = [:]

        for request in requests {
            guard !Task.isCancelled else { return resolved }
            let accountOrder = orderedAccountEmails(
                available: Array(availableSnapshots.keys),
                preferred: request.preferredAccountEmail
            )
            guard let candidate = matchingCandidate(
                for: request,
                accountOrder: accountOrder,
                snapshots: availableSnapshots
            ), let photoURL = candidate.record.photoURL else { continue }

            let imageKey = imageCacheKey(accountEmail: candidate.accountEmail, photoURL: photoURL)
            if let image = loadedImages[imageKey] {
                resolved[request.id] = image
                continue
            }
            if let image = loadCachedImage(
                accountEmail: candidate.accountEmail,
                photoURL: photoURL
            ) {
                loadedImages[imageKey] = image
                resolved[request.id] = image
                continue
            }
            guard let image = await downloadImage(for: candidate) else { continue }
            storeImage(image, accountEmail: candidate.accountEmail, photoURL: photoURL)
            loadedImages[imageKey] = image
            resolved[request.id] = image
        }
        return resolved
    }

    func invalidate(accountEmail: String) async {
        let normalized = normalizedEmail(accountEmail)
        snapshots.removeValue(forKey: normalized)
        try? fileManager.removeItem(at: accountDirectory(accountEmail: normalized))
    }

    private func fetchSnapshot(for storedToken: GoogleOAuthToken) async throws -> ContactSnapshot {
        var token = try await oauthManager.validAccessToken(for: storedToken.email)
        var contacts: [ContactRecord] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "https://people.googleapis.com/v1/people/me/connections"
            )!
            var queryItems = [
                URLQueryItem(name: "personFields", value: "emailAddresses,phoneNumbers,photos"),
                URLQueryItem(name: "pageSize", value: "1000")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw PeopleError.invalidResponse }

            let result = try await authorizedPeopleData(url: url, token: token, retryOnUnauthorized: true)
            token = result.token
            let page: PeopleConnectionsPage
            do {
                page = try JSONDecoder().decode(PeopleConnectionsPage.self, from: result.data)
            } catch {
                throw PeopleError.invalidResponse
            }
            contacts.append(contentsOf: (page.connections ?? []).compactMap(contactRecord(from:)))
            pageToken = page.nextPageToken
        } while pageToken != nil

        return ContactSnapshot(fetchedAt: Date(), contacts: contacts)
    }

    private func authorizedPeopleData(
        url: URL,
        token: GoogleOAuthToken,
        retryOnUnauthorized: Bool
    ) async throws -> (data: Data, token: GoogleOAuthToken) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PeopleError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw PeopleError.invalidResponse }
        if http.statusCode == 401, retryOnUnauthorized {
            let refreshed = try await oauthManager.refreshAccessToken(for: token.email)
            return try await authorizedPeopleData(
                url: url,
                token: refreshed,
                retryOnUnauthorized: false
            )
        }
        guard (200..<300).contains(http.statusCode) else { throw PeopleError.unavailable }
        return (data, token)
    }

    private func contactRecord(from person: PeoplePerson) -> ContactRecord? {
        guard let resourceName = person.resourceName, !resourceName.isEmpty else { return nil }
        let emails = Set((person.emailAddresses ?? []).compactMap { value in
            value.value.flatMap(normalizedOptionalEmail)
        }).sorted()
        let phones = Set((person.phoneNumbers ?? []).compactMap { value in
            value.value.flatMap(normalizedPhone)
        }).sorted()
        let photoURL = (person.photos ?? []).first { photo in
            photo.default != true && validPhotoURL(photo.url) != nil
        }.flatMap { validPhotoURL($0.url)?.absoluteString }

        guard !emails.isEmpty || !phones.isEmpty else { return nil }
        return ContactRecord(
            resourceName: resourceName,
            emails: emails,
            phoneNumbers: phones,
            photoURL: photoURL
        )
    }

    private func matchingCandidate(
        for request: GoogleContactPhotoRequest,
        accountOrder: [String],
        snapshots: [String: ContactSnapshot]
    ) -> PhotoCandidate? {
        if let email = request.email.flatMap(normalizedOptionalEmail) {
            for accountEmail in accountOrder {
                guard let snapshot = snapshots[accountEmail],
                      let record = uniqueCompatibleRecord(
                          in: snapshot.contacts.filter {
                              $0.photoURL != nil && $0.emails.contains(email)
                          }
                      ) else { continue }
                return PhotoCandidate(accountEmail: accountEmail, record: record)
            }
        }

        let requestPhones = Set(request.phoneNumbers.compactMap(normalizedPhone))
        guard !requestPhones.isEmpty else { return nil }
        for accountEmail in accountOrder {
            guard let snapshot = snapshots[accountEmail],
                  let record = uniqueCompatibleRecord(
                      in: snapshot.contacts.filter { contact in
                          contact.photoURL != nil && requestPhones.contains { requestPhone in
                              contact.phoneNumbers.contains { phonesMatch(requestPhone, $0) }
                          }
                      }
                  ) else { continue }
            return PhotoCandidate(accountEmail: accountEmail, record: record)
        }
        return nil
    }

    private func uniqueCompatibleRecord(in records: [ContactRecord]) -> ContactRecord? {
        let photoURLs = Set(records.compactMap(\.photoURL))
        guard photoURLs.count == 1, let photoURL = photoURLs.first else { return nil }
        return records.first { $0.photoURL == photoURL }
    }

    private func orderedAccountEmails(available: [String], preferred: String?) -> [String] {
        let sorted = Set(available.map(normalizedEmail)).sorted()
        guard let preferred = preferred.flatMap(normalizedOptionalEmail),
              sorted.contains(preferred) else { return sorted }
        return [preferred] + sorted.filter { $0 != preferred }
    }

    private func normalizedOptionalEmail(_ value: String) -> String? {
        let normalized = normalizedEmail(value)
        return normalized.contains("@") ? normalized : nil
    }

    private func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedPhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isInternational = trimmed.hasPrefix("+") || trimmed.hasPrefix("00")
        var digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("00"), digits.hasPrefix("00") {
            digits.removeFirst(2)
        }
        guard digits.count >= 8 else { return nil }
        return isInternational ? "+\(digits)" : digits
    }

    private func phonesMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let lhsDigits = lhs.filter(\.isNumber)
        let rhsDigits = rhs.filter(\.isNumber)
        guard min(lhsDigits.count, rhsDigits.count) >= 8 else { return false }
        let difference = abs(lhsDigits.count - rhsDigits.count)
        guard difference > 0, difference <= 3 else { return false }
        return lhsDigits.hasSuffix(rhsDigits) || rhsDigits.hasSuffix(lhsDigits)
    }

    private func validPhotoURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    private func downloadImage(for candidate: PhotoCandidate) async -> Data? {
        guard let photoURL = candidate.record.photoURL.flatMap(validPhotoURL) else { return nil }
        let token = try? await oauthManager.validAccessToken(for: candidate.accountEmail)
        var request = URLRequest(url: photoURL)
        if let token, shouldAttachAuthorization(to: photoURL) {
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.hasPrefix("image/"),
              http.expectedContentLength <= 0 || http.expectedContentLength <= Int64(maximumImageBytes),
              data.count <= maximumImageBytes,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    private func shouldAttachAuthorization(to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com") ||
            host == "googleapis.com" || host.hasSuffix(".googleapis.com")
    }

    private func loadSnapshot(accountEmail: String) -> ContactSnapshot? {
        let url = snapshotURL(accountEmail: accountEmail)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContactSnapshot.self, from: data)
    }

    private func storeSnapshot(_ snapshot: ContactSnapshot, accountEmail: String) {
        let directory = accountDirectory(accountEmail: accountEmail)
        let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL(accountEmail: accountEmail), options: .atomic)
            pruneImages(for: snapshot, accountEmail: accountEmail, imagesDirectory: imagesDirectory)
        } catch {
            return
        }
    }

    private func loadCachedImage(accountEmail: String, photoURL: String) -> Data? {
        let url = imageURL(accountEmail: accountEmail, photoURL: photoURL)
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumImageBytes,
              NSImage(data: data) != nil else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return data
    }

    private func storeImage(_ data: Data, accountEmail: String, photoURL: String) {
        let url = imageURL(accountEmail: accountEmail, photoURL: photoURL)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private func pruneImages(
        for snapshot: ContactSnapshot,
        accountEmail: String,
        imagesDirectory: URL
    ) {
        let referencedNames = Set(snapshot.contacts.compactMap { contact in
            contact.photoURL.map {
                imageURL(accountEmail: accountEmail, photoURL: $0).lastPathComponent
            }
        })
        guard let existing = try? fileManager.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in existing where !referencedNames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func accountDirectory(accountEmail: String) -> URL {
        cacheRoot.appendingPathComponent(hash(normalizedEmail(accountEmail)), isDirectory: true)
    }

    private func snapshotURL(accountEmail: String) -> URL {
        accountDirectory(accountEmail: accountEmail).appendingPathComponent("contacts.json")
    }

    private func imageURL(accountEmail: String, photoURL: String) -> URL {
        accountDirectory(accountEmail: accountEmail)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(imageCacheKey(accountEmail: accountEmail, photoURL: photoURL)).img")
    }

    private func imageCacheKey(accountEmail: String, photoURL: String) -> String {
        hash("\(normalizedEmail(accountEmail))\n\(photoURL)")
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Google account settings

enum GoogleAccountConnectionState: Equatable {
    case checking
    case connected
    case contactsAuthorizationRequired
    case needsReauthorization(String)

    var isCalendarUsable: Bool {
        switch self {
        case .connected, .contactsAuthorizationRequired:
            return true
        default:
            return false
        }
    }
}

enum GoogleAccountChange: Equatable {
    case connectedOrReauthorized(String)
    case disconnected(String)

    var email: String {
        switch self {
        case .connectedOrReauthorized(let email), .disconnected(let email):
            return email
        }
    }
}

struct GoogleAccountSettingsItem: Identifiable, Equatable {
    let email: String
    var connectionState: GoogleAccountConnectionState

    var id: String { email }
}

enum GoogleAccountOperation: Equatable {
    case idle
    case adding
    case reauthorizing(String)
    case disconnecting(String)

    var isBusy: Bool { self != .idle }

    func applies(to email: String) -> Bool {
        switch self {
        case .reauthorizing(let currentEmail), .disconnecting(let currentEmail):
            return currentEmail.caseInsensitiveCompare(email) == .orderedSame
        default:
            return false
        }
    }
}

@MainActor
final class GoogleAccountsSettingsModel: ObservableObject {
    @Published private(set) var accounts: [GoogleAccountSettingsItem] = []
    @Published private(set) var operation: GoogleAccountOperation = .idle
    @Published private(set) var requestedEmail: String?
    @Published private(set) var errorMessage: String?

    private let oauthManager: GoogleOAuthManager
    private let onAccountsChanged: (GoogleAccountChange) -> Void
    private var validationTask: Task<Void, Never>?

    init(
        oauthManager: GoogleOAuthManager,
        onAccountsChanged: @escaping (GoogleAccountChange) -> Void = { _ in }
    ) {
        self.oauthManager = oauthManager
        self.onAccountsChanged = onAccountsChanged
    }

    deinit {
        validationTask?.cancel()
    }

    func prepare(preferredEmail: String?) {
        requestedEmail = preferredEmail.flatMap { value in
            let normalized = normalizeEmail(value)
            return normalized.isEmpty ? nil : normalized
        }
        reload()
    }

    func reload(validate: Bool = true) {
        validationTask?.cancel()
        validationTask = Task { @MainActor [weak self] in
            await self?.reloadAccounts(validate: validate)
        }
    }

    func addAccount() {
        authorize(email: nil, requireMatch: false, operation: .adding)
    }

    func connectRequestedAccount() {
        guard let requestedEmail else { return }
        authorize(
            email: requestedEmail,
            requireMatch: true,
            operation: .reauthorizing(requestedEmail)
        )
    }

    func reauthorize(email: String) {
        let normalized = normalizeEmail(email)
        authorize(
            email: normalized,
            requireMatch: true,
            operation: .reauthorizing(normalized)
        )
    }

    func disconnect(email: String) {
        guard !operation.isBusy else { return }
        validationTask?.cancel()
        let normalized = normalizeEmail(email)
        operation = .disconnecting(normalized)
        errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try oauthManager.disconnect(email: normalized)
                operation = .idle
                onAccountsChanged(.disconnected(normalized))
                await reloadAccounts(validate: true)
            } catch {
                operation = .idle
                errorMessage = error.localizedDescription
                await reloadAccounts(validate: true)
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func account(for email: String) -> GoogleAccountSettingsItem? {
        let normalized = normalizeEmail(email)
        return accounts.first { $0.email == normalized }
    }

    private func authorize(
        email: String?,
        requireMatch: Bool,
        operation newOperation: GoogleAccountOperation
    ) {
        guard !operation.isBusy else { return }
        validationTask?.cancel()
        operation = newOperation
        errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await oauthManager.authorize(
                    preferredEmail: email,
                    requireEmailMatch: requireMatch
                )
                if requireMatch, requestedEmail == normalizeEmail(token.email) {
                    requestedEmail = nil
                }
                operation = .idle
                onAccountsChanged(.connectedOrReauthorized(normalizeEmail(token.email)))
                await reloadAccounts(validate: true)
            } catch {
                operation = .idle
                errorMessage = error.localizedDescription
                await reloadAccounts(validate: true)
            }
        }
    }

    private func reloadAccounts(validate: Bool) async {
        do {
            let tokens = try oauthManager.storedTokens()
            accounts = tokens.map { token in
                GoogleAccountSettingsItem(
                    email: normalizeEmail(token.email),
                    connectionState: validate
                        ? .checking
                        : connectionState(for: token)
                )
            }

            guard validate else { return }
            for account in accounts {
                guard !Task.isCancelled else { return }
                let state: GoogleAccountConnectionState
                do {
                    let token = try await oauthManager.validAccessToken(for: account.email)
                    state = connectionState(for: token)
                } catch {
                    state = .needsReauthorization(error.localizedDescription)
                }
                guard !Task.isCancelled else { return }
                if let index = accounts.firstIndex(where: { $0.email == account.email }) {
                    accounts[index].connectionState = state
                }
            }
        } catch {
            accounts = []
            errorMessage = error.localizedDescription
        }
    }

    private func connectionState(for token: GoogleOAuthToken) -> GoogleAccountConnectionState {
        token.hasGrantedScope(GoogleOAuthScope.contactsReadonly)
            ? .connected
            : .contactsAuthorizationRequired
    }

    private func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct GoogleAccountsSettingsView: View {
    @ObservedObject var model: GoogleAccountsSettingsModel
    @State private var pendingDisconnectEmail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let requestedEmail = model.requestedEmail,
               model.account(for: requestedEmail)?.connectionState.isCalendarUsable != true {
                requestedAccountBanner(email: requestedEmail)
            }

            accountContent

            if let errorMessage = model.errorMessage {
                errorBanner(message: errorMessage)
            }

            Divider().overlay(Color.white.opacity(0.1))

            HStack {
                Spacer()
                Button {
                    model.addAccount()
                } label: {
                    HStack(spacing: 7) {
                        if model.operation == .adding {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                        Text("Aggiungi account")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.operation.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520, height: 390)
        .background(panelBlack)
        .preferredColorScheme(.dark)
        .overlay {
            if let pendingDisconnectEmail {
                disconnectConfirmation(email: pendingDisconnectEmail)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Account Google")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("Gestisci gli account usati per rispondere agli inviti.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    @ViewBuilder
    private var accountContent: some View {
        if model.accounts.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(secondaryText)
                Text("Nessun account collegato")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text("Collega un account Google per rispondere agli inviti di Calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 155)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(model.accounts) { account in
                        accountRow(account)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func requestedAccountBanner(email: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account richiesto")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(email)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            }
            Spacer()
            Button("Collega") { model.connectRequestedAccount() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.operation.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func accountRow(_ account: GoogleAccountSettingsItem) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .overlay {
                    Text("G")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                }
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(account.email)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                accountStatus(account.connectionState)
            }

            Spacer(minLength: 10)

            if model.operation.applies(to: account.email) {
                ProgressView().controlSize(.small)
            }

            Button("Riautorizza") {
                model.reauthorize(email: account.email)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.operation.isBusy)

            Button {
                pendingDisconnectEmail = account.email
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.red.opacity(0.85))
            .disabled(model.operation.isBusy)
            .help("Disconnetti \(account.email)")
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func accountStatus(_ state: GoogleAccountConnectionState) -> some View {
        switch state {
        case .checking:
            Label("Verifica in corso…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(secondaryText)
        case .connected:
            Label("Collegato", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .contactsAuthorizationRequired:
            Label("Riautorizza per mostrare le foto dei contatti", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .help("Riautorizza per mostrare le foto dei contatti")
        case .needsReauthorization(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .help(message)
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.red.opacity(0.9))
        .padding(10)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func disconnectConfirmation(email: String) -> some View {
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())

            VStack(spacing: 13) {
                Image(systemName: "person.crop.circle.badge.minus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.red)
                Text("Disconnettere l’account?")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                Text(email)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)
                Text("Dovrai autorizzarlo di nuovo per rispondere ai relativi inviti.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)

                HStack(spacing: 9) {
                    Button("Annulla") {
                        pendingDisconnectEmail = nil
                    }
                    .buttonStyle(.bordered)

                    Button("Disconnetti") {
                        pendingDisconnectEmail = nil
                        model.disconnect(email: email)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(22)
            .frame(width: 350)
            .background(surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
    }
}

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
    let email: String?
    let phoneNumbers: [String]
    let googleImageData: Data?
    let appleImageData: Data?

    var imageData: Data? {
        googleImageData ?? appleImageData
    }

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

enum RSVPStatus: String, Codable, Equatable {
    case accepted
    case tentative
    case declined
    case needsAction

    init(_ participantStatus: EKParticipantStatus) {
        switch participantStatus {
        case .accepted: self = .accepted
        case .tentative: self = .tentative
        case .declined: self = .declined
        default: self = .needsAction
        }
    }
}

enum RSVPUpdateState: Equatable {
    case idle
    case updating
    case success
    case failed(String)
    case unavailable(String)
    case accountRequired(String)
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
    let currentUserParticipantEmail: String?
    let rsvpStatus: RSVPStatus
    let canRespond: Bool
    let rsvpLookupKey: String

    var hasEnded: Bool { endDate < Date() }
}

enum GoogleCalendarError: LocalizedError {
    case eventNotFound
    case calendarNotWritable
    case unauthorized
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .eventNotFound:
            return "Evento non trovato nell’account Google collegato."
        case .calendarNotWritable:
            return "Non puoi modificare la partecipazione per questo calendario."
        case .unauthorized:
            return "La sessione Google non è più valida."
        case .invalidResponse:
            return "Google Calendar ha restituito una risposta non valida."
        case .api(let message):
            return message.isEmpty ? "Google Calendar non è disponibile." : message
        }
    }
}

@MainActor
final class GoogleCalendarClient {
    private let oauthManager: GoogleOAuthManager
    private let session: URLSession
    private let apiRoot = URL(string: "https://www.googleapis.com/calendar/v3")!

    init(oauthManager: GoogleOAuthManager, session: URLSession = .shared) {
        self.oauthManager = oauthManager
        self.session = session
    }

    func updateResponse(for event: CalendarEventViewModel, status: RSVPStatus) async throws {
        guard status != .needsAction else { return }
        guard let participantEmail = event.currentUserParticipantEmail else {
            throw GoogleCalendarError.api("Impossibile determinare l’account invitato.")
        }

        let token = try await oauthManager.validAccessToken(for: participantEmail)
        let calendars = try await calendarIDs(token: token)
        for calendarID in calendars {
            guard let googleEvent = try await matchingEvent(for: event, calendarID: calendarID, token: token) else {
                continue
            }
            try await patchResponse(
                calendarID: calendarID,
                eventID: googleEvent.id,
                email: participantEmail,
                status: status,
                token: token
            )
            return
        }
        throw GoogleCalendarError.eventNotFound
    }

    private func calendarIDs(token: GoogleOAuthToken) async throws -> [String] {
        var ids = ["primary"]
        var pageToken: String?

        repeat {
            var components = URLComponents(url: apiRoot.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
            if let pageToken { components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)] }
            let data = try await authorizedData(for: URLRequest(url: components.url!), token: token)
            let page: CalendarListPage = try decode(CalendarListPage.self, from: data)
            for item in page.items ?? [] where item.id != "primary" && !ids.contains(item.id) {
                ids.append(item.id)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        return ids
    }

    private func matchingEvent(
        for event: CalendarEventViewModel,
        calendarID: String,
        token: GoogleOAuthToken
    ) async throws -> GoogleEvent? {
        var pageToken: String?
        var candidates: [GoogleEvent] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timeMin = formatter.string(from: event.startDate.addingTimeInterval(-36 * 60 * 60))
        let timeMax = formatter.string(from: event.endDate.addingTimeInterval(36 * 60 * 60))

        repeat {
            let eventsURL = apiRoot
                .appendingPathComponent("calendars")
                .appendingPathComponent(calendarID)
                .appendingPathComponent("events")
            var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "iCalUID", value: event.externalIdentifier),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "showDeleted", value: "false"),
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems

            let data: Data
            do {
                data = try await authorizedData(for: URLRequest(url: components.url!), token: token)
            } catch GoogleCalendarError.calendarNotWritable {
                return nil
            }
            let page: EventsPage = try decode(EventsPage.self, from: data)
            candidates.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil

        if candidates.count == 1 { return candidates[0] }
        return candidates.min { lhs, rhs in
            eventDistance(lhs, from: event.startDate) < eventDistance(rhs, from: event.startDate)
        }.flatMap { candidate in
            eventDistance(candidate, from: event.startDate) <= 36 * 60 * 60 ? candidate : nil
        }
    }

    private func patchResponse(
        calendarID: String,
        eventID: String,
        email: String,
        status: RSVPStatus,
        token: GoogleOAuthToken
    ) async throws {
        let eventURL = apiRoot
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
            .appendingPathComponent(eventID)
        var components = URLComponents(url: eventURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RSVPRequest(
                attendees: [RSVPAttendee(email: email, responseStatus: status.rawValue)],
                attendeesOmitted: true
            )
        )
        _ = try await authorizedData(for: request, token: token, forbiddenMeansNotWritable: true)
    }

    private func authorizedData(
        for request: URLRequest,
        token: GoogleOAuthToken,
        retryOnUnauthorized: Bool = true,
        forbiddenMeansNotWritable: Bool = false
    ) async throws -> Data {
        var authorizedRequest = request
        authorizedRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: authorizedRequest)
        } catch {
            throw GoogleCalendarError.api(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        if http.statusCode == 401, retryOnUnauthorized {
            let refreshed = try await oauthManager.refreshAccessToken(for: token.email)
            return try await authorizedData(
                for: request,
                token: refreshed,
                retryOnUnauthorized: false,
                forbiddenMeansNotWritable: forbiddenMeansNotWritable
            )
        }
        if http.statusCode == 401 { throw GoogleCalendarError.unauthorized }
        if http.statusCode == 403, forbiddenMeansNotWritable { throw GoogleCalendarError.calendarNotWritable }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleCalendarError.api(apiErrorMessage(from: data))
        }
        return data
    }

    private func eventDistance(_ event: GoogleEvent, from date: Date) -> TimeInterval {
        let dates = [event.start?.resolvedDate, event.originalStartTime?.resolvedDate].compactMap { $0 }
        return dates.map { abs($0.timeIntervalSince(date)) }.min() ?? .greatestFiniteMagnitude
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GoogleCalendarError.invalidResponse }
    }

    private func apiErrorMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message) ?? ""
    }

    private struct CalendarListPage: Decodable {
        let items: [CalendarListItem]?
        let nextPageToken: String?
    }

    private struct CalendarListItem: Decodable {
        let id: String
    }

    private struct EventsPage: Decodable {
        let items: [GoogleEvent]?
        let nextPageToken: String?
    }

    private struct GoogleEvent: Decodable {
        let id: String
        let start: GoogleEventDate?
        let originalStartTime: GoogleEventDate?
    }

    private struct GoogleEventDate: Decodable {
        let dateTime: String?
        let date: String?

        var resolvedDate: Date? {
            if let dateTime {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let value = fractional.date(from: dateTime) { return value }
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                return standard.date(from: dateTime)
            }
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
    }

    private struct RSVPRequest: Encodable {
        let attendees: [RSVPAttendee]
        let attendeesOmitted: Bool
    }

    private struct RSVPAttendee: Encodable {
        let email: String
        let responseStatus: String
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError
    }

    private struct APIError: Decodable {
        let message: String
    }
}

@MainActor
final class CalendarModel: ObservableObject {
    @Published var authorizationState: CalendarAuthorizationState = .notDetermined
    @Published var events: [CalendarEventViewModel] = []
    @Published var displayedDate = Date()
    @Published var rsvpStates: [String: RSVPUpdateState] = [:]

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let googleOAuthManager: GoogleOAuthManager
    private let googleContactPhotoService: GoogleContactPhotoService
    private lazy var googleCalendarClient = GoogleCalendarClient(oauthManager: googleOAuthManager)
    private var rsvpOverrides: [String: RSVPStatus] = [:]
    private var storeObserver: NSObjectProtocol?
    private var googlePhotoLoadTask: Task<Void, Never>?
    private var googlePhotoLoadGeneration = 0
    private var accessRequestStarted = false
    private var contactsAccessRequestStarted = false
    private var lastKnownToday = Calendar.current.startOfDay(for: Date())

    init(
        googleOAuthManager: GoogleOAuthManager,
        googleContactPhotoService: GoogleContactPhotoService
    ) {
        self.googleOAuthManager = googleOAuthManager
        self.googleContactPhotoService = googleContactPhotoService
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
        googlePhotoLoadTask?.cancel()
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

    func googleAccountsDidChange() {
        let resolvedEventIDs = rsvpStates.compactMap { eventID, state -> String? in
            guard case .accountRequired(let email) = state,
                  googleOAuthManager.hasStoredToken(for: email) else { return nil }
            return eventID
        }
        for eventID in resolvedEventIDs {
            rsvpStates[eventID] = .idle
        }
        refresh(forceGooglePhotos: true)
    }

    func refresh(forceGooglePhotos: Bool = false) {
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
                let currentParticipant = event.attendees?.first(where: \.isCurrentUser)
                let nativeRSVPStatus = currentParticipant.map { RSVPStatus($0.participantStatus) } ?? .needsAction
                let lookupKey = "\(externalIdentifier)-\(event.startDate.timeIntervalSince1970)"
                let effectiveRSVPStatus: RSVPStatus
                if let override = rsvpOverrides[lookupKey] {
                    effectiveRSVPStatus = override
                    if override == nativeRSVPStatus { rsvpOverrides.removeValue(forKey: lookupKey) }
                } else {
                    effectiveRSVPStatus = nativeRSVPStatus
                }
                let participantEmail = currentParticipant.flatMap(participantEmail(for:))
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
                    meetingLink: meetingLink(for: event),
                    currentUserParticipantEmail: participantEmail,
                    rsvpStatus: effectiveRSVPStatus,
                    canRespond: currentParticipant != nil,
                    rsvpLookupKey: lookupKey
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startDate < rhs.startDate
            }
        loadGoogleContactPhotos(forceRefresh: forceGooglePhotos)
    }

    func respond(to event: CalendarEventViewModel, with status: RSVPStatus) {
        guard event.canRespond else {
            rsvpStates[event.id] = .unavailable("Questo evento non richiede una risposta.")
            return
        }
        guard status != .needsAction else { return }
        guard rsvpStates[event.id] != .updating else { return }
        guard let participantEmail = event.currentUserParticipantEmail else {
            rsvpStates[event.id] = .unavailable("Impossibile determinare l’account invitato.")
            return
        }
        guard googleOAuthManager.hasStoredToken(for: participantEmail) else {
            rsvpStates[event.id] = .accountRequired(participantEmail)
            return
        }

        let previousStatus = event.rsvpStatus
        rsvpOverrides[event.rsvpLookupKey] = status
        replaceRSVPStatus(for: event.id, with: status)
        rsvpStates[event.id] = .updating

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await googleCalendarClient.updateResponse(for: event, status: status)
                rsvpStates[event.id] = .success
            } catch let error as GoogleCalendarError {
                rollbackRSVP(event: event, to: previousStatus)
                switch error {
                case .eventNotFound, .calendarNotWritable:
                    rsvpStates[event.id] = .unavailable(error.localizedDescription)
                default:
                    rsvpStates[event.id] = .failed(error.localizedDescription)
                }
            } catch let error as GoogleOAuthError {
                rollbackRSVP(event: event, to: previousStatus)
                switch error {
                case .accountNotConnected, .missingRefreshToken, .tokenExchange:
                    rsvpStates[event.id] = .accountRequired(participantEmail)
                default:
                    rsvpStates[event.id] = .failed(error.localizedDescription)
                }
            } catch {
                rollbackRSVP(event: event, to: previousStatus)
                rsvpStates[event.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func rollbackRSVP(event: CalendarEventViewModel, to status: RSVPStatus) {
        rsvpOverrides[event.rsvpLookupKey] = status
        replaceRSVPStatus(for: event.id, with: status)
    }

    private func replaceRSVPStatus(for eventID: String, with status: RSVPStatus) {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
        let event = events[index]
        events[index] = CalendarEventViewModel(
            id: event.id,
            eventIdentifier: event.eventIdentifier,
            externalIdentifier: event.externalIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarColor: event.calendarColor,
            attendees: event.attendees,
            meetingLink: event.meetingLink,
            currentUserParticipantEmail: event.currentUserParticipantEmail,
            rsvpStatus: status,
            canRespond: event.canRespond,
            rsvpLookupKey: event.rsvpLookupKey
        )
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
            let eventKitEmail = participantEmail(for: participant)
            let contactEmail = contact?.emailAddresses.lazy
                .map { String($0.value) }
                .compactMap(normalizedEmailForPhotoMatch)
                .first
            let email = eventKitEmail ?? contactEmail
            let phoneNumbers = Set((contact?.phoneNumbers ?? []).compactMap {
                normalizedPhoneForPhotoMatch($0.value.stringValue)
            }).sorted()
            let fallbackName = email ?? participant.url.absoluteString
            let name = contactName?.isEmpty == false
                ? contactName!
                : (participantName?.isEmpty == false ? participantName! : fallbackName)

            return CalendarAttendeeViewModel(
                id: "\(participant.url.absoluteString)-\(index)",
                name: name,
                email: email,
                phoneNumbers: phoneNumbers,
                googleImageData: nil,
                appleImageData: contact?.thumbnailImageData
            )
        }
    }

    private func matchingContact(for participant: EKParticipant) -> CNContact? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        return try? contactStore
            .unifiedContacts(matching: participant.contactPredicate, keysToFetch: keys)
            .first
    }

    private func loadGoogleContactPhotos(forceRefresh: Bool) {
        googlePhotoLoadTask?.cancel()
        googlePhotoLoadGeneration += 1
        let generation = googlePhotoLoadGeneration

        var requests: [GoogleContactPhotoRequest] = []
        var targets: [String: (eventID: String, attendeeID: String)] = [:]
        for event in events {
            for attendee in event.attendees where attendee.email != nil || !attendee.phoneNumbers.isEmpty {
                let requestID = "\(event.id)\n\(attendee.id)"
                requests.append(
                    GoogleContactPhotoRequest(
                        id: requestID,
                        email: attendee.email,
                        phoneNumbers: attendee.phoneNumbers,
                        preferredAccountEmail: event.currentUserParticipantEmail
                    )
                )
                targets[requestID] = (event.id, attendee.id)
            }
        }
        guard !requests.isEmpty else { return }

        let photoService = googleContactPhotoService
        googlePhotoLoadTask = Task { @MainActor [weak self] in
            let images = await photoService.resolve(requests, forceRefresh: forceRefresh)
            guard let self,
                  !Task.isCancelled,
                  googlePhotoLoadGeneration == generation else { return }
            applyGoogleContactPhotos(images, targets: targets)
        }
    }

    private func applyGoogleContactPhotos(
        _ images: [String: Data],
        targets: [String: (eventID: String, attendeeID: String)]
    ) {
        guard !images.isEmpty else { return }
        var updatedEvents = events
        var didChange = false

        for (requestID, imageData) in images {
            guard let target = targets[requestID],
                  let eventIndex = updatedEvents.firstIndex(where: { $0.id == target.eventID }),
                  let attendeeIndex = updatedEvents[eventIndex].attendees.firstIndex(where: {
                      $0.id == target.attendeeID
                  }) else { continue }

            let event = updatedEvents[eventIndex]
            let attendee = event.attendees[attendeeIndex]
            var attendees = event.attendees
            attendees[attendeeIndex] = CalendarAttendeeViewModel(
                id: attendee.id,
                name: attendee.name,
                email: attendee.email,
                phoneNumbers: attendee.phoneNumbers,
                googleImageData: imageData,
                appleImageData: attendee.appleImageData
            )
            updatedEvents[eventIndex] = replacingAttendees(in: event, with: attendees)
            didChange = true
        }

        if didChange { events = updatedEvents }
    }

    private func replacingAttendees(
        in event: CalendarEventViewModel,
        with attendees: [CalendarAttendeeViewModel]
    ) -> CalendarEventViewModel {
        CalendarEventViewModel(
            id: event.id,
            eventIdentifier: event.eventIdentifier,
            externalIdentifier: event.externalIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            calendarColor: event.calendarColor,
            attendees: attendees,
            meetingLink: event.meetingLink,
            currentUserParticipantEmail: event.currentUserParticipantEmail,
            rsvpStatus: event.rsvpStatus,
            canRespond: event.canRespond,
            rsvpLookupKey: event.rsvpLookupKey
        )
    }

    private func participantEmail(for participant: EKParticipant) -> String? {
        guard participant.url.scheme?.lowercased() == "mailto" else { return nil }
        let rawValue = participant.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        let candidate = decoded.split(separator: "?", maxSplits: 1).first.map(String.init) ?? decoded
        return normalizedEmailForPhotoMatch(candidate)
    }

    private func normalizedEmailForPhotoMatch(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("@") ? normalized : nil
    }

    private func normalizedPhoneForPhotoMatch(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isInternational = trimmed.hasPrefix("+") || trimmed.hasPrefix("00")
        var digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("00"), digits.hasPrefix("00") {
            digits.removeFirst(2)
        }
        guard digits.count >= 8 else { return nil }
        return isInternational ? "+\(digits)" : digits
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
    let onOpenSettings: (String?) -> Void

    @State private var weekOffset = 0
    @State private var weekNavigationDirection = 1
    @State private var expandedEventID: String?

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
        .onChange(of: model.displayedDate) {
            expandedEventID = nil
        }
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
            ZStack {
                Text(monthTitle)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)

                HStack(spacing: 7) {
                    Spacer()
                    Button { onOpenSettings(nil) } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(secondaryText)
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Gestisci account Google")
                    .accessibilityLabel("Gestisci account Google")

                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(secondaryText)
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Aggiorna eventi")
                    .accessibilityLabel("Aggiorna eventi")
                }
                .padding(.horizontal, 16)
            }

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
                expandedEventID = nil
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
                            EventRow(
                                event: event,
                                rsvpState: model.rsvpStates[event.id] ?? .idle,
                                isExpanded: expandedEventID == event.id,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedEventID = expandedEventID == event.id ? nil : event.id
                                    }
                                },
                                onRespond: { model.respond(to: event, with: $0) },
                                onOpenSettings: onOpenSettings,
                                onOpenCalendar: { model.openInCalendar(event) }
                            )
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
    let rsvpState: RSVPUpdateState
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRespond: (RSVPStatus) -> Void
    let onOpenSettings: (String?) -> Void
    let onOpenCalendar: () -> Void

    @State private var isHovered = false
    @State private var isJoinHovered = false
    @State private var lastRequestedStatus: RSVPStatus?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(event.calendarColor)
                            .frame(width: 7, height: 7)

                        if event.attendees.isEmpty {
                            Image(systemName: "calendar")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(event.calendarColor)
                                .frame(width: 58, alignment: .leading)
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
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(isExpanded ? "Chiudi dettagli di \(event.title)" : "Apri dettagli di \(event.title)")

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

            if isExpanded {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.horizontal, 14)

                participationContent
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isHovered ? surfaceHover : surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .opacity(event.hasEnded ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }

    private var participationContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Partecipazione")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)

                Spacer()
                progressLabel
            }

            HStack(spacing: 7) {
                rsvpButton("Sì", status: .accepted, color: Color(red: 0.15, green: 0.67, blue: 0.36))
                rsvpButton("Forse", status: .tentative, color: Color(red: 0.95, green: 0.58, blue: 0.16))
                rsvpButton("No", status: .declined, color: Color(red: 0.88, green: 0.25, blue: 0.27))
            }

            statusFeedback

            Button(action: onOpenCalendar) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Apri in Calendar")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(subtleText)
            }
            .buttonStyle(.plain)
            .help("Apri questo evento in Calendar")
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        switch rsvpState {
        case .updating:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Aggiornamento…")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(secondaryText)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusFeedback: some View {
        if !event.canRespond {
            Text("Non sei tra gli invitati di questo evento.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryText)
        } else {
            switch rsvpState {
            case .success:
                Label("Risposta aggiornata", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.15, green: 0.67, blue: 0.36))
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(message)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let lastRequestedStatus {
                        Button("Riprova") { onRespond(lastRequestedStatus) }
                            .buttonStyle(.plain)
                            .foregroundStyle(primaryText)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.38))
            case .unavailable(let message):
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .lineLimit(2)
            case .accountRequired(let email):
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Collega account \(email)")
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Impostazioni") { onOpenSettings(email) }
                        .buttonStyle(.plain)
                        .foregroundStyle(primaryText)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.orange)
            default:
                EmptyView()
            }
        }
    }

    private func rsvpButton(_ title: String, status: RSVPStatus, color: Color) -> some View {
        let isSelected = event.rsvpStatus == status
        return Button {
            lastRequestedStatus = status
            onRespond(status)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(isSelected ? color : Color.white.opacity(0.07))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(controlsAreDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controlsAreDisabled: Bool {
        guard event.canRespond else { return true }
        switch rsvpState {
        case .updating, .unavailable, .accountRequired:
            return true
        default:
            return false
        }
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

// MARK: - Windows

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: GoogleAccountsSettingsModel
    private var window: NSWindow?
    private var hasCenteredWindow = false

    init(model: GoogleAccountsSettingsModel) {
        self.model = model
        super.init()
    }

    func show(preferredEmail: String?) {
        model.prepare(preferredEmail: preferredEmail)
        let settingsWindow = buildWindowIfNeeded()
        if !hasCenteredWindow {
            settingsWindow.center()
            hasCenteredWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.deactivate()
    }

    private func buildWindowIfNeeded() -> NSWindow {
        if let window { return window }

        let hostingView = NSHostingView(rootView: GoogleAccountsSettingsView(model: model))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Calendar Notch — Account Google"
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .normal
        newWindow.collectionBehavior = [.moveToActiveSpace]
        newWindow.contentView = hostingView
        newWindow.delegate = self
        window = newWindow
        return newWindow
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController: NSObject {
    private let googleOAuthManager: GoogleOAuthManager
    private let googleContactPhotoService: GoogleContactPhotoService
    private let model: CalendarModel
    private let settingsWindowController: SettingsWindowController
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
        let googleOAuthManager = GoogleOAuthManager()
        let googleContactPhotoService = GoogleContactPhotoService(oauthManager: googleOAuthManager)
        let model = CalendarModel(
            googleOAuthManager: googleOAuthManager,
            googleContactPhotoService: googleContactPhotoService
        )
        let settingsModel = GoogleAccountsSettingsModel(
            oauthManager: googleOAuthManager,
            onAccountsChanged: { [weak model] change in
                Task { @MainActor in
                    await googleContactPhotoService.invalidate(accountEmail: change.email)
                    model?.googleAccountsDidChange()
                }
            }
        )
        self.googleOAuthManager = googleOAuthManager
        self.googleContactPhotoService = googleContactPhotoService
        self.model = model
        self.settingsWindowController = SettingsWindowController(model: settingsModel)
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
            },
            onOpenSettings: { [weak self] preferredEmail in
                self?.openSettings(preferredEmail: preferredEmail)
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

    private func openSettings(preferredEmail: String?) {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) { [weak self] in
            self?.settingsWindowController.show(preferredEmail: preferredEmail)
        }
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
