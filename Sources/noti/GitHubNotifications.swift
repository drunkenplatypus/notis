import Foundation
import Security
import UserNotifications

@MainActor
final class GitHubNotificationCoordinator {
    private let api = GitHubAPI()
    private let notifier = MacNotificationService()

    private var token: String?
    private var login: String?
    private var reviewRequestKeys = Set<String>()
    private var seenReviewIDs = Set<Int>()
    private var seenIssueCommentIDs = Set<Int>()
    private var seenReviewCommentIDs = Set<Int>()

    private(set) var statusText = "GitHub PAT required"
    private(set) var lastCheckText = "Not checked yet"
    private(set) var isAuthenticated = false
    private(set) var assignedPullRequests: [GitHubPullRequest] = []
    private(set) var reviewRequestedPullRequests: [GitHubPullRequest] = []
    private(set) var unreadNotificationCount = 0

    func prepare() async {
        guard let storedToken = GitHubPATStore.load() else {
            resetState(message: "GitHub PAT required")
            return
        }

        await authenticateAndSeed(using: storedToken)
    }

    func saveToken(_ newToken: String) async {
        do {
            try GitHubPATStore.save(token: newToken)
            await authenticateAndSeed(using: newToken)
        } catch {
            statusText = "Failed to save PAT"
            lastCheckText = conciseError(from: error)
            isAuthenticated = false
        }
    }

    func clearToken() async {
        GitHubPATStore.delete()
        token = nil
        login = nil
        reviewRequestKeys.removeAll()
        seenReviewIDs.removeAll()
        seenIssueCommentIDs.removeAll()
        seenReviewCommentIDs.removeAll()
        unreadNotificationCount = 0
        resetState(message: "GitHub PAT required")
    }

    func poll(sendNotifications: Bool) async {
        guard let token else {
            resetState(message: "GitHub PAT required")
            return
        }

        guard let login else {
            await authenticateAndSeed(using: token)
            return
        }

        do {
            try await sync(token: token, login: login, sendNotifications: sendNotifications)
            statusText = "Signed in as \(login)"
            lastCheckText = "Last checked \(Self.timeFormatter.string(from: Date()))"
            isAuthenticated = true
        } catch {
            statusText = "GitHub check failed"
            lastCheckText = conciseError(from: error)
            isAuthenticated = false
        }
    }

    private func authenticateAndSeed(using token: String) async {
        let user: GitHubUser
        do {
            user = try await api.fetchCurrentUser(token: token)
        } catch {
            self.token = nil
            login = nil
            statusText = "GitHub auth failed"
            lastCheckText = conciseError(from: error)
            isAuthenticated = false
            return
        }

        self.token = token
        login = user.login
        reviewRequestKeys.removeAll()
        seenReviewIDs.removeAll()
        seenIssueCommentIDs.removeAll()
        seenReviewCommentIDs.removeAll()

        do {
            try await sync(token: token, login: user.login, sendNotifications: false)
        } catch {
            // Seeding failed — still mark as authenticated, next poll will retry
            statusText = "Signed in as \(user.login)"
            lastCheckText = "Initial sync failed: \(conciseError(from: error))"
            isAuthenticated = true
            return
        }

        statusText = "Signed in as \(user.login)"
        lastCheckText = "Monitoring pull requests"
        isAuthenticated = true
    }

    private func sync(token: String, login: String, sendNotifications: Bool) async throws {
        let fetchedReviewRequested = try await api.searchPullRequests(
            query: "is:pr state:open archived:false review-requested:\(login)",
            token: token
        )
        let fetchedAssigned = try await api.searchPullRequests(
            query: "is:pr state:open archived:false assignee:\(login)",
            token: token
        )

        // Badge count now reflects only the events this app will notify about,
        // so it stays in sync with local macOS notifications.
        var badgeCountForThisPoll = 0

        reviewRequestedPullRequests = fetchedReviewRequested
        assignedPullRequests = fetchedAssigned

        let nextReviewRequestKeys = Set(fetchedReviewRequested.map(\.stableKey))
        if sendNotifications {
            for pullRequest in fetchedReviewRequested where !reviewRequestKeys.contains(pullRequest.stableKey) {
                badgeCountForThisPoll += 1
                await notifier.send(
                    title: "Review requested",
                    subtitle: pullRequest.displayIdentifier,
                    body: pullRequest.title,
                    url: pullRequest.htmlURL
                )
            }
        }
        reviewRequestKeys = nextReviewRequestKeys

        // Merge both lists, deduplicating by stable key, so we track comments on
        // PRs where the user is a reviewer as well as PRs they are assigned to.
        var seenKeys = Set<String>()
        let allTrackedPRs = (fetchedAssigned + fetchedReviewRequested).filter {
            seenKeys.insert($0.stableKey).inserted
        }

        for pullRequest in allTrackedPRs {
            async let reviewsTask = api.fetchReviews(pullRequestURL: pullRequest.pullRequest.apiURL, token: token)
            async let issueCommentsTask = api.fetchIssueComments(commentsURL: pullRequest.commentsURL, token: token)
            async let reviewCommentsTask = api.fetchReviewComments(pullRequestURL: pullRequest.pullRequest.apiURL, token: token)

            let reviews = (try? await reviewsTask) ?? []
            let issueComments = (try? await issueCommentsTask) ?? []
            let reviewComments = (try? await reviewCommentsTask) ?? []

            print("[noti] \(pullRequest.displayIdentifier): \(reviews.count) reviews, \(issueComments.count) issue comments, \(reviewComments.count) review comments")

            var newlyNotifiedReviewIDs = Set<Int>()

            for review in reviews {
                guard let author = review.user?.login, author != login else { continue }
                let inserted = seenReviewIDs.insert(review.id).inserted
                print("[noti]   review \(review.id) by \(author) — inserted=\(inserted) notify=\(sendNotifications) hasDate=\(review.submittedAt != nil)")
                guard inserted, sendNotifications, review.submittedAt != nil else { continue }
                newlyNotifiedReviewIDs.insert(review.id)
                badgeCountForThisPoll += 1
                await notifier.send(
                    title: "Pull request review",
                    subtitle: pullRequest.displayIdentifier,
                    body: "\(author) reviewed: \(review.summary)",
                    url: pullRequest.htmlURL
                )
            }

            for comment in issueComments {
                guard let author = comment.user?.login, author != login else { continue }
                let inserted = seenIssueCommentIDs.insert(comment.id).inserted
                print("[noti]   issue comment \(comment.id) by \(author) — inserted=\(inserted) notify=\(sendNotifications)")
                guard inserted, sendNotifications else { continue }
                badgeCountForThisPoll += 1
                await notifier.send(
                    title: "Pull request comment",
                    subtitle: pullRequest.displayIdentifier,
                    body: "\(author): \(comment.summary)",
                    url: pullRequest.htmlURL
                )
            }

            for comment in reviewComments {
                guard let author = comment.user?.login, author != login else { continue }
                // Skip if this comment belongs to a review we already notified about
                if let reviewID = comment.pullRequestReviewID, newlyNotifiedReviewIDs.contains(reviewID) { continue }
                let inserted = seenReviewCommentIDs.insert(comment.id).inserted
                print("[noti]   review comment \(comment.id) by \(author) — inserted=\(inserted) notify=\(sendNotifications)")
                guard inserted, sendNotifications else { continue }
                badgeCountForThisPoll += 1
                await notifier.send(
                    title: "Review comment",
                    subtitle: pullRequest.displayIdentifier,
                    body: "\(author): \(comment.summary)",
                    url: pullRequest.htmlURL
                )
            }
        }

        unreadNotificationCount = sendNotifications ? badgeCountForThisPoll : 0
    }

    private func resetState(message: String) {
        statusText = message
        lastCheckText = "Not checked yet"
        isAuthenticated = false
        assignedPullRequests = []
        reviewRequestedPullRequests = []
        unreadNotificationCount = 0
    }

    private func conciseError(from error: Error) -> String {
        if let apiError = error as? GitHubAPIError {
            return apiError.description
        }

        return error.localizedDescription
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

struct GitHubAPI {
    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        try await request(path: "/user", token: token)
    }

    func searchPullRequests(query: String, token: String) async throws -> [GitHubPullRequest] {
        var components = URLComponents(string: "https://api.github.com/search/issues")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "100")
        ]

        guard let url = components?.url else {
            throw GitHubAPIError.invalidURL
        }

        let response: SearchResponse<GitHubPullRequest> = try await request(url: url, token: token)
        return response.items
    }

    func fetchReviews(pullRequestURL: URL, token: String) async throws -> [GitHubReview] {
        let url = try pagedURL(from: pullRequestURL.appendingPathComponent("reviews"))
        return try await request(url: url, token: token)
    }

    func fetchIssueComments(commentsURL: URL, token: String) async throws -> [GitHubComment] {
        let url = try pagedURL(from: commentsURL)
        return try await request(url: url, token: token)
    }

    func fetchReviewComments(pullRequestURL: URL, token: String) async throws -> [GitHubComment] {
        let url = try pagedURL(from: pullRequestURL.appendingPathComponent("comments"))
        return try await request(url: url, token: token)
    }

    func fetchUnreadNotificationCount(token: String) async throws -> Int {
        var components = URLComponents(string: "https://api.github.com/notifications")
        components?.queryItems = [
            URLQueryItem(name: "all", value: "false"),
            URLQueryItem(name: "participating", value: "false"),
            URLQueryItem(name: "per_page", value: "100")
        ]

        guard let url = components?.url else {
            throw GitHubAPIError.invalidURL
        }

        let threads: [GitHubNotificationThread] = try await request(url: url, token: token)
        return threads.count
    }

    private func request<T: Decodable>(path: String, token: String) async throws -> T {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubAPIError.invalidURL
        }

        return try await request(url: url, token: token)
    }

    private func request<T: Decodable>(url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("noti", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiMessage = try? GitHubAPI.decoder.decode(GitHubAPIMessage.self, from: data)
            throw GitHubAPIError.httpStatus(code: httpResponse.statusCode, message: apiMessage?.message)
        }

        do {
            return try GitHubAPI.decoder.decode(T.self, from: data)
        } catch {
            throw GitHubAPIError.decodingFailed(error.localizedDescription)
        }
    }

    private func pagedURL(from baseURL: URL) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]

        guard let url = components?.url else {
            throw GitHubAPIError.invalidURL
        }

        return url
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = GitHubAPI.parseISO8601Date(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: value)
    }
}

enum GitHubAPIError: Error, CustomStringConvertible {
    case invalidURL
    case invalidResponse
    case httpStatus(code: Int, message: String?)
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidURL:
            return "GitHub URL construction failed"
        case .invalidResponse:
            return "GitHub returned an invalid response"
        case let .httpStatus(code, message):
            if let message, !message.isEmpty {
                return "GitHub error \(code): \(message)"
            }

            return "GitHub error \(code)"
        case let .decodingFailed(message):
            return "GitHub response could not be decoded: \(message)"
        }
    }
}

enum GitHubPATStore {
    private static let service = "noti.github.pat"
    private static let account = "default"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func save(token: String) throws {
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8)
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}

@MainActor
final class MacNotificationService {
    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
        }
    }

    func send(title: String, subtitle: String, body: String, url: URL? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "PR_EVENT"
        if let url {
            content.userInfo = ["url": url.absoluteString]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
        }
    }
}

struct SearchResponse<Item: Decodable>: Decodable {
    let items: [Item]
}

struct GitHubNotificationThread: Decodable {
    let id: String
}

struct GitHubUser: Decodable {
    let login: String
}

struct GitHubPullRequest: Decodable {
    let number: Int
    let title: String
    let htmlURL: URL
    let commentsURL: URL
    let repositoryURL: URL
    let pullRequest: PullRequestReference

    var repositoryFullName: String {
        repositoryURL.path.replacingOccurrences(of: "/repos/", with: "")
    }

    var displayIdentifier: String {
        "\(repositoryFullName) #\(number)"
    }

    var stableKey: String {
        pullRequest.apiURL.absoluteString
    }

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case htmlURL = "html_url"
        case commentsURL = "comments_url"
        case repositoryURL = "repository_url"
        case pullRequest = "pull_request"
    }
}

struct PullRequestReference: Decodable {
    let apiURL: URL

    enum CodingKeys: String, CodingKey {
        case apiURL = "url"
    }
}

struct GitHubReview: Decodable {
    let id: Int
    let body: String?
    let submittedAt: Date?
    let user: GitHubActor?

    var summary: String {
        body?.notificationSnippet ?? "Review submitted"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case submittedAt = "submitted_at"
        case user
    }
}

struct GitHubComment: Decodable {
    let id: Int
    let body: String?
    let user: GitHubActor?
    let pullRequestReviewID: Int?

    var summary: String {
        body?.notificationSnippet ?? "Comment added"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case user
        case pullRequestReviewID = "pull_request_review_id"
    }
}

struct GitHubActor: Decodable {
    let login: String
}

struct GitHubAPIMessage: Decodable {
    let message: String
}

extension Optional where Wrapped == String {
    var notificationSnippet: String? {
        self?.notificationSnippet
    }
}

extension String {
    var notificationSnippet: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Updated"
        }

        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.count <= 120 {
            return firstLine
        }

        let endIndex = firstLine.index(firstLine.startIndex, offsetBy: 117)
        return String(firstLine[..<endIndex]) + "..."
    }
}
