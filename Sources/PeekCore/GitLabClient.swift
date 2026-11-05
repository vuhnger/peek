import Foundation

extension JSONDecoder {
  static var gitlab: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: string) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: string) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
    }
    return decoder
  }
}

struct GitLabProject: Decodable, Sendable, Equatable {
  let id: Int
  let path: String
  let pathWithNamespace: String
  let defaultBranch: String?
  let lastActivityAt: Date?

  func repo(host: String) -> Repo {
    Repo(
      id: id, name: path, fullName: pathWithNamespace, defaultBranch: defaultBranch ?? "main",
      pushedAt: lastActivityAt, host: host)
  }
}

struct GitLabUser: Decodable, Sendable, Equatable {
  let id: Int
  let username: String
}

struct GitLabPipeline: Decodable, Sendable, Equatable {
  let id: Int
  let projectId: Int
  let ref: String?
  let status: String
  let source: String?
  let createdAt: Date
  let updatedAt: Date?
  let webUrl: String?
  let name: String?
}

struct GitLabMergeRequest: Decodable, Sendable, Equatable {
  let iid: Int
  let sourceBranch: String?
  let sourceProjectId: Int?
  let title: String?
  let author: Author?

  struct Author: Decodable, Sendable, Equatable {
    let username: String
  }
}

enum GitLabMapping {
  static func status(_ status: String) -> (status: String, conclusion: String?) {
    switch status {
    case "created", "waiting_for_resource", "preparing", "pending", "scheduled":
      ("queued", nil)
    case "running": ("in_progress", nil)
    case "success": ("completed", "success")
    case "failed": ("completed", "failure")
    case "skipped": ("completed", "skipped")
    case "canceled", "manual": ("completed", "cancelled")
    default: ("completed", status)
    }
  }

  static func mergeRequestNumber(ref: String?) -> Int? {
    guard let ref else { return nil }
    let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "refs", parts[1] == "merge-requests",
      parts[3] == "head" || parts[3] == "merge"
    else { return nil }
    return Int(parts[2])
  }

  static func run(
    _ pipeline: GitLabPipeline, project: Repo, actor: Account?,
    mergeRequest: GitLabMergeRequest?
  ) -> WorkflowRun {
    let number = mergeRequestNumber(ref: pipeline.ref)
    let mapped = status(pipeline.status)
    let branch = number.map { mergeRequest?.sourceBranch ?? "!\($0)" } ?? pipeline.ref
    return WorkflowRun(
      id: pipeline.id, workflowId: pipeline.projectId, createdAt: pipeline.createdAt,
      name: pipeline.name ?? "Pipeline", displayTitle: mergeRequest?.title,
      status: mapped.status, conclusion: mapped.conclusion, event: pipeline.source,
      headBranch: branch, pullRequests: number.map { [PullRequestRef(number: $0)] },
      runStartedAt: pipeline.createdAt, updatedAt: pipeline.updatedAt, htmlUrl: pipeline.webUrl,
      actor: actor,
      headRepository: mergeRequest?.sourceProjectId.flatMap {
        $0 == project.id ? nil : RepoRef(id: $0, fullName: nil)
      } ?? RepoRef(id: project.id, fullName: project.fullName),
      isMergeRequest: number != nil)
  }
}

public actor GitLabClient: RunProvider {
  private static let timeout: TimeInterval = 15
  private static let pageSize = 100
  private static let rateLimitFallback: TimeInterval = 60

  public nonisolated let host: String
  private let baseURL: String
  private let session: URLSession
  private let tokenProvider: @Sendable () async -> String?
  private let now: @Sendable () -> Date
  private var token: String?
  private var me: Viewer?
  private var cache: [URL: (etag: String, body: Data)] = [:]
  private var timingHistories: [String: (fetchedAt: Date, runs: [WorkflowRun])] = [:]

  public init(
    host: String,
    configuration: URLSessionConfiguration = .ephemeral,
    tokenProvider: @escaping @Sendable () async -> String?,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let hardened = configuration.copy() as! URLSessionConfiguration
    hardened.urlCache = nil
    hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
    hardened.timeoutIntervalForRequest = Self.timeout
    self.session = URLSession(configuration: hardened)
    self.host = host
    self.baseURL = "https://\(host)/api/v4/"
    self.tokenProvider = tokenProvider
    self.now = now
  }

  public func viewer() async throws -> Viewer {
    if let me { return me }
    let user: GitLabUser = try await get("user")
    let viewer = Viewer(id: user.id, login: user.username)
    me = viewer
    return viewer
  }

  public func repos() async throws -> [Repo] {
    let since = Self.day(now().addingTimeInterval(-RepoDiscovery.window))
    let projects: [GitLabProject] = try await list(
      "projects?membership=true&archived=false&order_by=last_activity_at&sort=desc"
        + "&per_page=30&last_activity_after=\(since)")
    return projects.map { $0.repo(host: host) }
  }

  public func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun? {
    let login = try segment(actor)
    let pipelines: [GitLabPipeline] = try await list(
      "projects/\(repo.id)/pipelines?username=\(login)&created_after=\(Self.day(since))&per_page=1")
    return pipelines.first.map {
      GitLabMapping.run($0, project: repo, actor: Account(login: actor), mergeRequest: nil)
    }
  }

  public func runs(repo: Repo) async throws -> [WorkflowRun] {
    let login = try await viewer().login
    let base = "projects/\(repo.id)/pipelines?per_page=\(Self.pageSize)"
    let all: [GitLabPipeline] = try await list(base)
    let mine: [GitLabPipeline] = try await list(base + "&username=\(try segment(login))")
    let mineIds = Set(mine.map(\.id))
    let requests = await mergeRequests(
      repo: repo, numbers: Set(all.compactMap { GitLabMapping.mergeRequestNumber(ref: $0.ref) }))
    return all.map { pipeline in
      let number = GitLabMapping.mergeRequestNumber(ref: pipeline.ref)
      let request = number.flatMap { requests[$0] }
      let isMine =
        number == nil ? mineIds.contains(pipeline.id) : request?.author?.username == login
      return GitLabMapping.run(
        pipeline, project: repo, actor: isMine ? Account(login: login) : nil,
        mergeRequest: request)
    }
  }

  public func branches(repo: Repo) async throws -> Set<String>? {
    let page: [Branch] = try await get(
      "projects/\(repo.id)/repository/branches?per_page=\(Self.pageSize)")
    return page.count < Self.pageSize ? Set(page.map(\.name)) : nil
  }

  public func timingHistory(for active: [WorkflowRun], repo: Repo) async throws -> [WorkflowRun] {
    guard !active.isEmpty else { return [] }
    let path = "projects/\(repo.id)/pipelines?status=success&per_page=100&order_by=id&sort=desc"
    var history = timingHistories[path]
    if history.map({ now().timeIntervalSince($0.fetchedAt) >= 60 }) ?? true {
      let pipelines: [GitLabPipeline] = try await list(path)
      let previous = Dictionary(
        (history?.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      history = (
        now(),
        pipelines.map { pipeline in
          if let old = previous[pipeline.id], old.updatedAt == pipeline.updatedAt { return old }
          return GitLabMapping.run(pipeline, project: repo, actor: nil, mergeRequest: nil)
        }
      )
    }
    guard var history else { return [] }
    var result: [Int: WorkflowRun] = [:]
    for original in active {
      let run = try await timing(for: original, repo: repo)
      result[run.id] = run
      guard run.runAttempt != nil else { continue }
      var matches = 0
      for offset in stride(from: 0, to: history.runs.count, by: 4) {
        let indices = offset..<min(offset + 4, history.runs.count)
        let enriched = try await withThrowingTaskGroup(of: (Int, WorkflowRun).self) { group in
          for index in indices {
            let candidate = history.runs[index]
            group.addTask {
              let enriched =
                candidate.jobs == nil
                ? try await self.timing(for: candidate, repo: repo) : candidate
              return (index, enriched)
            }
          }
          var enriched: [(Int, WorkflowRun)] = []
          for try await item in group { enriched.append(item) }
          return enriched
        }
        for (index, candidate) in enriched {
          history.runs[index] = candidate
          result[candidate.id] = candidate
          if ETA.comparable(run, candidate) { matches += 1 }
        }
        if matches >= ETA.maxSamples { break }
      }
    }
    timingHistories[path] = history
    return Array(result.values)
  }

  private struct Job: Decodable {
    let name: String
    let status: String
    let retried: Bool?
    let createdAt: Date?
    let startedAt: Date?
    let finishedAt: Date?
  }

  private func timing(for original: WorkflowRun, repo: Repo) async throws -> WorkflowRun {
    var jobs: [Job] = []
    var complete = false
    for page in 1...10 {
      let batch: [Job] = try await get(
        "projects/\(repo.id)/pipelines/\(original.id)/jobs?include_retried=true&per_page=100&page=\(page)"
      )
      jobs += batch
      if batch.count < Self.pageSize {
        complete = true
        break
      }
    }
    guard complete else { throw GitHubError.decoding }
    var run = original
    run.jobs = jobs.filter { $0.retried != true }.map { job in
      let mapped = GitLabMapping.status(job.status)
      return WorkflowJob(
        name: job.name, status: mapped.status, conclusion: mapped.conclusion,
        createdAt: job.createdAt, startedAt: job.startedAt, completedAt: job.finishedAt)
    }
    let retried = jobs.contains { $0.retried == true } || Set(jobs.map(\.name)).count < jobs.count
    run.runAttempt = retried ? nil : 1
    return run
  }

  private func mergeRequests(repo: Repo, numbers: Set<Int>) async -> [Int: GitLabMergeRequest] {
    guard !numbers.isEmpty else { return [:] }
    let filter = numbers.sorted().map { "iids%5B%5D=\($0)" }.joined(separator: "&")
    let found: [GitLabMergeRequest]? = try? await list(
      "projects/\(repo.id)/merge_requests?state=all&per_page=\(Self.pageSize)&\(filter)")
    return Dictionary((found ?? []).map { ($0.iid, $0) }, uniquingKeysWith: { first, _ in first })
  }

  private static func day(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
  }

  private func segment(_ value: String) throws -> String {
    guard RepoPath.isValidSegment(value) else { throw GitHubError.notFound }
    return value
  }

  private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: any Decoder) throws {
      value = try? decoder.singleValueContainer().decode(Element.self)
    }
  }

  private func list<Element: Decodable>(_ path: String) async throws -> [Element] {
    let items: [Lossy<Element>] = try await get(path)
    return items.compactMap(\.value)
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    guard let url = URL(string: baseURL + path) else { throw GitHubError.notFound }
    let body = try await body(for: url)
    do {
      return try JSONDecoder.gitlab.decode(Value.self, from: body)
    } catch {
      throw GitHubError.decoding
    }
  }

  private func body(for url: URL) async throws -> Data {
    guard let current = await currentToken() else { throw GitHubError.unauthorized }
    do {
      return try await fetch(url, token: current)
    } catch GitHubError.unauthorized {
      guard let renewed = await renewedToken(), renewed != current else {
        throw GitHubError.unauthorized
      }
      return try await fetch(url, token: renewed)
    }
  }

  private func currentToken() async -> String? {
    if let token { return token }
    token = await tokenProvider()
    return token
  }

  private func renewedToken() async -> String? {
    token = await tokenProvider()
    cache = [:]
    me = nil
    return token
  }

  private func fetch(_ url: URL, token: String) async throws -> Data {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("peek", forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let cached = cache[url] {
      request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(
        for: request, delegate: RedirectPolicy(token: token, apiHost: host))
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw GitHubError.transport(error.code)
    }
    guard let http = response as? HTTPURLResponse else { throw GitHubError.decoding }

    switch http.statusCode {
    case 200..<300:
      cache[url] = http.value(forHTTPHeaderField: "ETag").map { ($0, data) }
      return data
    case 304:
      guard let cached = cache[url] else { throw GitHubError.server(304) }
      return cached.body
    case 401:
      throw GitHubError.unauthorized
    case 404:
      cache[url] = nil
      throw GitHubError.notFound
    case 429:
      throw GitHubError.rateLimited(resumeAt: rateLimitResume(http))
    default:
      throw GitHubError.server(http.statusCode)
    }
  }

  private func rateLimitResume(_ response: HTTPURLResponse) -> Date {
    if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    {
      return now().addingTimeInterval(retryAfter)
    }
    if let reset = response.value(forHTTPHeaderField: "RateLimit-Reset").flatMap(TimeInterval.init)
    {
      return Date(timeIntervalSince1970: reset)
    }
    return now().addingTimeInterval(Self.rateLimitFallback)
  }
}
