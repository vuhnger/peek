import Foundation
import Testing

@testable import Peek
@testable import PeekCore

private struct FakeProvider: RunProvider {
  let host: String
  let repo: Repo
  let runId: Int
  var failure: GitHubError?

  func viewer() async throws -> Viewer {
    if let failure { throw failure }
    return Viewer(id: 1, login: "me")
  }

  func repos() async throws -> [Repo] { [repo] }

  func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun? {
    try run(for: repo)
  }

  func runs(repo: Repo) async throws -> [WorkflowRun] { [try run(for: repo)] }

  func branches(repo: Repo) async throws -> Set<String>? { nil }

  private func run(for repo: Repo) throws -> WorkflowRun {
    let json = """
      {"id":\(runId),"workflow_id":1,"status":"completed","conclusion":"success","event":"push",\
      "created_at":"\(Date().ISO8601Format())","head_branch":"main","run_attempt":1,\
      "actor":{"login":"me","id":1},\
      "head_repository":{"id":\(repo.id),"full_name":"\(repo.fullName)"}}
      """
    return try JSONDecoder.github.decode(WorkflowRun.self, from: Data(json.utf8))
  }
}

private final class RecordingProvider: RunProvider, @unchecked Sendable {
  let host = Repo.githubHost
  let repo: Repo
  private let lock = NSLock()
  private var passed: [[Int]] = []

  init(repo: Repo) { self.repo = repo }

  var lookedUp: [[Int]] { lock.withLock { passed } }

  func viewer() async throws -> Viewer { Viewer(id: 1, login: "me") }
  func repos() async throws -> [Repo] { [repo] }
  func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun? {
    try run(1, 1, "main", "push")
  }
  func branches(repo: Repo) async throws -> Set<String>? { ["main"] }

  func runs(repo: Repo) async throws -> [WorkflowRun] {
    [
      try run(1, 1, "main", "pull_request"),
      try run(2, 1, "gone", "pull_request"),
      try run(3, 2, "main", "push"),
    ]
  }

  private func run(_ id: Int, _ workflow: Int, _ branch: String, _ event: String) throws
    -> WorkflowRun
  {
    let json = """
      {"id":\(id),"workflow_id":\(workflow),"status":"completed","conclusion":"success",\
      "event":"\(event)","created_at":"\(Date().ISO8601Format())","head_branch":"\(branch)",\
      "actor":{"login":"me","id":1},"head_repository":{"id":1,"full_name":"foo/bar"}}
      """
    return try JSONDecoder.github.decode(WorkflowRun.self, from: Data(json.utf8))
  }

  func resolvingPullRequests(_ runs: [WorkflowRun], repo: Repo) async -> [WorkflowRun] {
    lock.withLock { passed.append(runs.map(\.id).sorted()) }
    return runs.map { run in
      var run = run
      if run.id == 1 { run.pullRequests = [PullRequestRef(number: 42)] }
      return run
    }
  }
}

private final class ScriptedProvider: RunProvider, @unchecked Sendable {
  let host = Repo.githubHost
  let repo: Repo
  private let lock = NSLock()
  private var current: [WorkflowRun] = []
  private var timing: [WorkflowRun] = []
  private var timingFailure: GitHubError?

  init(repo: Repo) { self.repo = repo }

  func set(_ runs: [WorkflowRun]) { lock.withLock { current = runs } }
  func setTiming(_ runs: [WorkflowRun], failure: GitHubError? = nil) {
    lock.withLock {
      timing = runs
      timingFailure = failure
    }
  }

  func viewer() async throws -> Viewer { Viewer(id: 1, login: "me") }
  func repos() async throws -> [Repo] { [repo] }
  func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun? {
    lock.withLock { current.first }
  }
  func branches(repo: Repo) async throws -> Set<String>? { nil }
  func runs(repo: Repo) async throws -> [WorkflowRun] { lock.withLock { current } }
  func timingHistory(for active: [WorkflowRun], repo: Repo) async throws -> [WorkflowRun] {
    try lock.withLock {
      if let timingFailure { throw timingFailure }
      return timing
    }
  }
}

private func pullRequestRun(_ id: Int, branch: String, actor: String, status: String)
  -> WorkflowRun
{
  let conclusion = status == "completed" ? "\"success\"" : "null"
  let json = """
    {"id":\(id),"workflow_id":1,"status":"\(status)","conclusion":\(conclusion),\
    "event":"pull_request","created_at":"\(Date().ISO8601Format())","head_branch":"\(branch)",\
    "actor":{"login":"\(actor)","id":1},"head_repository":{"id":1,"full_name":"foo/bar"}}
    """
  return try! JSONDecoder.github.decode(WorkflowRun.self, from: Data(json.utf8))
}

private func repo(host: String, id: Int = 1) -> Repo {
  Repo(
    id: id, name: "bar", fullName: "foo/bar", defaultBranch: "main", pushedAt: Date(), host: host)
}

@MainActor
struct MonitorProviderTests {
  @Test func panelAndMenuUseEnrichedHistoryAndKeepLiveStatusWhenEstimatesFail() async throws {
    let github = ScriptedProvider(repo: repo(host: Repo.githubHost))
    let now = Date()
    func run(_ id: Int, start: Date, finished: Date?) throws -> WorkflowRun {
      var json: [String: Any] = [
        "id": id, "workflow_id": 1, "event": "push", "run_attempt": 1,
        "created_at": start.ISO8601Format(),
        "run_started_at": start.addingTimeInterval(20).ISO8601Format(),
        "status": finished == nil ? "in_progress" : "completed", "head_branch": "main",
        "actor": ["id": 1, "login": "me"], "head_repository": ["id": 1, "full_name": "foo/bar"],
        "pull_requests": [["number": 42]],
      ]
      json["updated_at"] = finished?.ISO8601Format()
      json["conclusion"] = finished.map { _ in "success" }
      return try JSONDecoder.github.decode(
        WorkflowRun.self, from: JSONSerialization.data(withJSONObject: json))
    }
    var active = try run(1, start: now.addingTimeInterval(-30), finished: nil)
    github.set([active])
    active.jobs = [WorkflowJob(name: "ci", status: "in_progress")]
    var previous = try run(
      100, start: now.addingTimeInterval(-3600), finished: now.addingTimeInterval(-3500))
    previous.jobs = [WorkflowJob(name: "ci", conclusion: "success")]
    github.setTiming([active, previous])
    let monitor = Monitor(github: github, gitLab: { [] })
    await monitor.pollOnce()
    let row = try #require(monitor.repos.first?.branches.first?.rows.first)
    #expect(row.estimate?.durations == [100])
    #expect(row.startedAt == active.createdAt)
    #expect(row.pullRequest == 42)
    #expect(monitor.menuBarGlyph == .running(progress: 0.25))
    github.setTiming([], failure: .server(503))
    await monitor.pollOnce()
    #expect(row.state == .running)
    #expect(row.estimate == nil)
    #expect(monitor.menuBarGlyph == .running(progress: nil))
  }

  @Test func onlyDisplayedRunsAreResolvedAndTheNumberReachesTheRow() async {
    let github = RecordingProvider(repo: repo(host: Repo.githubHost))
    let monitor = Monitor(github: github, gitLab: { [] })
    await monitor.pollOnce()
    #expect(github.lookedUp == [[1, 3]])
    let rows = monitor.repos.first?.branches.flatMap(\.rows) ?? []
    #expect(rows.contains { $0.pullRequest == 42 })
  }

  @Test func notificationsCoverTheSameRunsAsThePanel() async {
    let github = ScriptedProvider(repo: repo(host: Repo.githubHost))
    let monitor = Monitor(github: github, gitLab: { [] })
    var events: [RunEvent] = []
    monitor.onEvents = { events += $0 }
    github.set([
      pullRequestRun(1, branch: "mine", actor: "me", status: "completed"),
      pullRequestRun(2, branch: "theirs", actor: "someone", status: "completed"),
    ])
    await monitor.pollOnce()
    github.set([
      pullRequestRun(3, branch: "mine", actor: "me", status: "in_progress"),
      pullRequestRun(4, branch: "theirs", actor: "someone", status: "in_progress"),
    ])
    await monitor.pollOnce()
    let shown = monitor.repos.flatMap(\.branches).flatMap(\.rows).map(\.id)
    #expect(shown == [3])
    #expect(events.map(\.run.id) == shown)
  }

  @Test func aFailingGitLabHostLeavesGitHubResultsIntact() async {
    for failure in [GitHubError.unauthorized, .transport(.timedOut), .server(500), .decoding] {
      let monitor = Monitor(
        github: FakeProvider(host: Repo.githubHost, repo: repo(host: Repo.githubHost), runId: 5),
        gitLab: {
          [
            FakeProvider(
              host: "gitlab.example.com", repo: repo(host: "gitlab.example.com"), runId: 5,
              failure: failure)
          ]
        })
      await monitor.pollOnce()
      #expect(monitor.repos.map(\.id) == ["foo/bar"])
      #expect(monitor.repos.first?.branches.first?.rows.count == 1)
      #expect(monitor.menuBarGlyph != .signedOut)
      let expected: PanelNotice? = failure == .unauthorized ? .gitLabSignedOut : nil
      #expect(monitor.notice == expected)
    }
  }

  @Test func aFailingGitHubLeavesGitLabCardsInPlace() async {
    let monitor = Monitor(
      github: FakeProvider(
        host: Repo.githubHost, repo: repo(host: Repo.githubHost), runId: 5,
        failure: .transport(.notConnectedToInternet)),
      gitLab: {
        [FakeProvider(host: "gitlab.com", repo: repo(host: "gitlab.com"), runId: 5)]
      })
    await monitor.pollOnce()
    #expect(monitor.repos.map(\.id) == ["gitlab.com/foo/bar"])
  }

  @Test func sameNameAndSameIdsOnTwoHostsGiveTwoCardsWithTheirOwnRows() async {
    let monitor = Monitor(
      github: FakeProvider(host: Repo.githubHost, repo: repo(host: Repo.githubHost), runId: 5),
      gitLab: {
        [
          FakeProvider(host: "gitlab.com", repo: repo(host: "gitlab.com"), runId: 5),
          FakeProvider(
            host: "gitlab.example.com", repo: repo(host: "gitlab.example.com"), runId: 5),
        ]
      })
    await monitor.pollOnce()
    let ids = Set(monitor.repos.map(\.id))
    #expect(ids == ["foo/bar", "gitlab.com/foo/bar", "gitlab.example.com/foo/bar"])
    let rows = monitor.repos.compactMap { $0.branches.first?.rows.first }
    #expect(rows.count == 3)
    #expect(Set(rows.map(ObjectIdentifier.init)).count == 3)
  }

  @Test func aGitLabSignOutReportsOnItsOwnSessionChannel() async {
    let monitor = Monitor(
      github: FakeProvider(host: Repo.githubHost, repo: repo(host: Repo.githubHost), runId: 5),
      gitLab: {
        [
          FakeProvider(
            host: "gitlab.com", repo: repo(host: "gitlab.com"), runId: 5, failure: .unauthorized)
        ]
      })
    var github: [SessionState] = []
    var gitlab: [SessionState] = []
    monitor.onSession = { github.append($0) }
    monitor.onGitLabSession = { gitlab.append($0) }
    await monitor.pollOnce()
    #expect(github.last == .signedIn)
    #expect(gitlab.last == .signedOut)
  }

  @Test func withoutGitLabHostsOnlyGitHubRuns() async {
    let monitor = Monitor(
      github: FakeProvider(host: Repo.githubHost, repo: repo(host: Repo.githubHost), runId: 5),
      gitLab: { [] })
    var gitlab: [SessionState] = []
    monitor.onGitLabSession = { gitlab.append($0) }
    await monitor.pollOnce()
    #expect(monitor.repos.map(\.id) == ["foo/bar"])
    #expect(gitlab.allSatisfy { $0 == .unknown })
    #expect(monitor.notice == nil)
  }
}
