import Foundation

public enum GitHubError: Error, Equatable, Sendable {
  case unauthorized
  case rateLimited(resumeAt: Date)
  case notFound
  case server(Int)
  case transport(URLError.Code)
  case decoding
}

public actor GitHubClient: RunProvider {
  private static let baseURL = "https://api.github.com/"
  private static let apiHost = "api.github.com"
  private static let timeout: TimeInterval = 15
  private static let pageSize = 100

  public nonisolated let host = Repo.githubHost
  private let session: URLSession
  private let tokenProvider: @Sendable () async -> String?
  private let now: @Sendable () -> Date
  private var token: String?
  private var cache: [URL: (etag: String, body: Data)] = [:]
  private var pullNumbers: [String: [String: [Int]]] = [:]
  private var timingHistories: [String: (fetchedAt: Date, runs: [WorkflowRun])] = [:]

  public init(
    configuration: URLSessionConfiguration = .ephemeral,
    tokenProvider: @escaping @Sendable () async -> String?,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let hardened = configuration.copy() as! URLSessionConfiguration
    hardened.urlCache = nil
    hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
    hardened.timeoutIntervalForRequest = Self.timeout
    self.session = URLSession(configuration: hardened)
    self.tokenProvider = tokenProvider
    self.now = now
  }

  public func viewer() async throws -> Viewer {
    try await get("user")
  }

  public func repos() async throws -> [Repo] {
    try await get(
      "user/repos?sort=pushed&direction=desc&per_page=30"
        + "&affiliation=owner,collaborator,organization_member")
  }

  public func latestRun(owner: String, name: String, actor: String, since: Date) async throws
    -> WorkflowRun?
  {
    let day = since.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    let path =
      "repos/\(try segment(owner))/\(try segment(name))/actions/runs"
      + "?actor=\(try segment(actor))&created=%3E%3D\(day)&per_page=1"
    let page: RunsPage = try await get(path)
    return page.runs.first
  }

  public func runs(owner: String, name: String) async throws -> [WorkflowRun] {
    let path = "repos/\(try segment(owner))/\(try segment(name))/actions/runs?per_page=100"
    let page: RunsPage = try await get(path)
    return page.runs
  }

  public func resolvingPullRequests(_ runs: [WorkflowRun], repo: Repo) async -> [WorkflowRun] {
    guard let (owner, name) = try? parts(repo) else { return runs }
    let repo = "\(owner)/\(name)"
    var known = pullNumbers[repo, default: [:]].filter { sha, _ in
      runs.contains { $0.headSha == sha }
    }
    var result = runs
    var failed: Set<String> = []
    for index in result.indices {
      let run = result[index]
      guard run.event == "pull_request" || run.event == "pull_request_target",
        run.pullRequestNumber == nil, let sha = run.headSha, !failed.contains(sha)
      else { continue }
      if known[sha] == nil {
        do {
          let pulls: [PullRequestRef] = try await get(
            "repos/\(try segment(owner))/\(try segment(name))/commits/\(try segment(sha))/pulls")
          known[sha] = pulls.prefix(1).map(\.number)
        } catch {
          failed.insert(sha)
          continue
        }
      }
      result[index].pullRequests = known[sha]?.map(PullRequestRef.init)
    }
    pullNumbers[repo] = known
    return result
  }

  public func branches(owner: String, name: String) async throws -> Set<String>? {
    let path = "repos/\(try segment(owner))/\(try segment(name))/branches?per_page=100"
    let page: [Branch] = try await get(path)
    return page.count < Self.pageSize ? Set(page.map(\.name)) : nil
  }

  public func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun? {
    let (owner, name) = try parts(repo)
    return try await latestRun(owner: owner, name: name, actor: actor, since: since)
  }

  public func runs(repo: Repo) async throws -> [WorkflowRun] {
    let (owner, name) = try parts(repo)
    return try await runs(owner: owner, name: name)
  }

  public func branches(repo: Repo) async throws -> Set<String>? {
    let (owner, name) = try parts(repo)
    return try await branches(owner: owner, name: name)
  }

  public func timingHistory(for active: [WorkflowRun], repo: Repo) async throws -> [WorkflowRun] {
    let (owner, name) = try parts(repo)
    let base = "repos/\(try segment(owner))/\(try segment(name))/actions"
    var result: [Int: WorkflowRun] = [:]
    for original in active {
      guard let attempt = original.runAttempt, let event = original.event else { continue }
      var run = original
      run.jobs = try await jobs(base: base, run: run)
      result[run.id] = run
      guard run.jobs?.isEmpty == false else { continue }
      let path =
        "\(base)/workflows/\(run.workflowId)/runs"
        + "?event=\(try segment(event))&status=success&per_page=100"
      var history = timingHistories[path]
      if history.map({ now().timeIntervalSince($0.fetchedAt) >= 60 }) ?? true {
        let page: RunsPage = try await get(path)
        let previous = Dictionary(
          (history?.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        history = (
          now(),
          page.runs.map { candidate in
            var candidate = candidate
            if previous[candidate.id]?.runAttempt == candidate.runAttempt {
              candidate.jobs = previous[candidate.id]?.jobs
            }
            return candidate
          }
        )
      }
      guard var history else { continue }
      let indices = history.runs.indices.filter {
        let candidate = history.runs[$0]
        return candidate.id != run.id && candidate.state == .passed
          && candidate.workflowId == run.workflowId && candidate.event == event
          && candidate.runAttempt.map { ($0 > 1) == (attempt > 1) } == true
      }
      var matches = 0
      for offset in stride(from: 0, to: indices.count, by: 4) {
        let batch = indices[offset..<min(offset + 4, indices.count)]
        let enriched = try await withThrowingTaskGroup(of: (Int, WorkflowRun).self) { group in
          for index in batch {
            let candidate = history.runs[index]
            group.addTask {
              var candidate = candidate
              if candidate.jobs == nil {
                candidate.jobs = try await self.jobs(base: base, run: candidate)
              }
              return (index, candidate)
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
      timingHistories[path] = history
    }
    return Array(result.values)
  }

  private struct JobsPage: Decodable {
    let totalCount: Int
    let jobs: [WorkflowJob]
  }

  private func jobs(base: String, run: WorkflowRun) async throws -> [WorkflowJob] {
    guard let attempt = run.runAttempt else { return [] }
    var jobs: [WorkflowJob] = []
    for page in 1...10 {
      let result: JobsPage = try await get(
        "\(base)/runs/\(run.id)/attempts/\(attempt)/jobs?per_page=100&page=\(page)")
      jobs += result.jobs
      if jobs.count >= result.totalCount { return jobs }
      guard !result.jobs.isEmpty else { throw GitHubError.decoding }
    }
    throw GitHubError.decoding
  }

  private func parts(_ repo: Repo) throws -> (String, String) {
    let parts = repo.fullName.split(separator: "/").map(String.init)
    guard parts.count == 2 else { throw GitHubError.notFound }
    return (parts[0], parts[1])
  }

  private func segment(_ value: String) throws -> String {
    guard RepoPath.isValidSegment(value) else { throw GitHubError.notFound }
    return value
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    guard let url = URL(string: Self.baseURL + path) else { throw GitHubError.notFound }
    let body = try await body(for: url)
    do {
      return try JSONDecoder.github.decode(Value.self, from: body)
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
    return token
  }

  private func fetch(_ url: URL, token: String) async throws -> Data {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("peek", forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let cached = cache[url] {
      request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(
        for: request, delegate: RedirectPolicy(token: token, apiHost: Self.apiHost))
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
    case 403, 429:
      if let resumeAt = rateLimitResume(http) { throw GitHubError.rateLimited(resumeAt: resumeAt) }
      throw GitHubError.server(http.statusCode)
    default:
      throw GitHubError.server(http.statusCode)
    }
  }

  private func rateLimitResume(_ response: HTTPURLResponse) -> Date? {
    if let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
    {
      return now().addingTimeInterval(retryAfter)
    }
    if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
      let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
    {
      return Date(timeIntervalSince1970: reset)
    }
    return nil
  }
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
  private let token: String
  private let apiHost: String

  init(token: String, apiHost: String) {
    self.token = token
    self.apiHost = apiHost
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    var redirected = request
    if request.url?.scheme == "https", request.url?.host == apiHost {
      redirected.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    } else {
      redirected.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    return redirected
  }
}
