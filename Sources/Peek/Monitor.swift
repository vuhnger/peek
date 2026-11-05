import AppKit
import Observation
import PeekCore

private struct RepoMeta: Sendable {
  let repo: Repo
  let branches: Set<String>?
  let fetchedAt: Date
}

private struct Fetched: Sendable {
  let id: String
  let host: String
  let meta: RepoMeta
  let group: RepoGroup?
  let rawRuns: [WorkflowRun]
  let etas: [Int: ETAEstimate]
}

private struct Outcome: Sendable {
  let repo: Repo
  let result: Result<Fetched, GitHubError>
}

@MainActor
private final class Source {
  let provider: any RunProvider
  var viewer: String?
  var discovery = Discovery(repos: [], error: nil)
  var lastDiscovery = Date.distantPast
  var discoveryForced = true
  var errors: [GitHubError] = []
  var lastError: GitHubError?
  var failures = 0
  var jitter = 0.0
  var finishedAt = Date.distantPast
  var task: Task<Void, Never>?
  var anySuccess = false

  init(provider: any RunProvider) {
    self.provider = provider
  }

  var isGitHub: Bool { provider.host == Repo.githubHost }
  var signedOut: Bool { errors.contains(.unauthorized) }
}

@MainActor @Observable
final class Monitor {
  private(set) var repos: [RepoModel] = []
  private(set) var notice: PanelNotice?
  private(set) var menuBarGlyph: MenuBarGlyph = .idle
  private(set) var connections: [ConnectionRow] = []
  var onEvents: (([RunEvent]) -> Void)?
  var onSession: ((SessionState) -> Void)?
  var onGitLabSession: ((SessionState) -> Void)?

  @ObservationIgnored private var sources: [Source]
  @ObservationIgnored private let gitLabProviders: @Sendable () -> [any RunProvider]
  @ObservationIgnored private var lastSourceRefresh = Date.distantPast
  @ObservationIgnored private var metas: [String: RepoMeta] = [:]
  @ObservationIgnored private var ghInstalled = true
  @ObservationIgnored private var rows: [String: RunRowModel] = [:]
  @ObservationIgnored private var models: [String: RepoModel] = [:]
  @ObservationIgnored private var menuInputs: [String: MenuBarRepo] = [:]
  @ObservationIgnored private var trackers: [String: RunTracker] = [:]
  @ObservationIgnored private var lastUpdated: Date?
  @ObservationIgnored private var lastPollStart = Date.distantPast
  @ObservationIgnored private var panelVisible = false
  @ObservationIgnored private var hasActiveRun = false
  @ObservationIgnored private var woke = false
  @ObservationIgnored private var forced = false
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var sleeper: Task<Void, Never>?
  @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var shownBuiltIn = BuiltInRuns.isShown(in: .standard)

  var showsRepos: Bool {
    if !repos.isEmpty { return true }
    switch notice {
    case .ghMissing, .signedOut, .noRecentRuns: return false
    default: return true
    }
  }

  init(
    github: any RunProvider = GitHubClient(tokenProvider: { await GhTokenReader.read() }),
    gitLab: @escaping @Sendable () -> [any RunProvider] = {
      GlabCLI.hosts().map { host in
        GitLabClient(host: host, tokenProvider: { await GlabCLI.token(host: host) })
      }
    }
  ) {
    sources = [Source(provider: github)]
    gitLabProviders = gitLab
  }

  func start() {
    guard loop == nil else { return }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.woke = true
        for source in self.sources {
          source.discoveryForced = true
          source.task?.cancel()
        }
        self.nudge()
      }
    }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, BuiltInRuns.isShown(in: .standard) != self.shownBuiltIn else { return }
        self.retry()
      }
    }
    loop = Task { await run() }
  }

  func retry() {
    forced = true
    nudge()
  }

  func panelVisibilityChanged(_ visible: Bool) {
    panelVisible = visible
    if !visible { for model in models.values { model.userExpanded = nil } }
    guard visible else { return }
    if Date().timeIntervalSince(lastPollStart) > 1 { forced = true }
    nudge()
  }

  func pollOnce() async {
    refreshSources(force: true)
    let tasks = sources.map { start($0) }
    for task in tasks { await task.value }
  }

  private func nudge() {
    sleeper?.cancel()
  }

  private func refreshSources(force: Bool = false) {
    let now = Date()
    guard force || now.timeIntervalSince(lastSourceRefresh) >= Self.sourceRefreshInterval else {
      return
    }
    lastSourceRefresh = now
    let fresh = gitLabProviders().filter { $0.host != Repo.githubHost }
    var kept = [sources[0]]
    for provider in fresh where !kept.contains(where: { $0.provider.host == provider.host }) {
      kept.append(
        sources.first { $0.provider.host == provider.host } ?? Source(provider: provider))
    }
    for source in sources where !kept.contains(where: { $0 === source }) { source.task?.cancel() }
    sources = kept
  }

  private func remaining(for source: Source) -> TimeInterval {
    let delay = PollPolicy.delay(
      after: source.lastError, failures: source.failures, panelVisible: panelVisible,
      hasActiveRun: hasActiveRun, wokeFromSleep: woke, now: source.finishedAt,
      jitter: source.jitter)
    return source.finishedAt.addingTimeInterval(delay).timeIntervalSinceNow
  }

  private func isDue(_ source: Source) -> Bool {
    source.task == nil
      && (remaining(for: source) <= 0
        || (forced && PollPolicy.allowsForcedPoll(after: source.lastError)))
  }

  @discardableResult
  private func start(_ source: Source) -> Task<Void, Never> {
    if let running = source.task { return running }
    lastPollStart = Date()
    let task = Task {
      await pollSource(source)
      source.finishedAt = Date()
      source.jitter = Double.random(in: 0...1)
      source.task = nil
      nudge()
    }
    source.task = task
    return task
  }

  private func run() async {
    while !Task.isCancelled {
      refreshSources()
      if woke { await NetworkGate.waitUntilSatisfied(timeout: .seconds(2)) }
      for source in sources where isDue(source) { start(source) }
      woke = false
      forced = false
      let wait =
        sources.filter { $0.task == nil }.map { remaining(for: $0) }.min()
        ?? Self.sourceRefreshInterval
      let sleep = Task<Void, Never> {
        _ = try? await Task.sleep(for: .seconds(min(max(wait, 0.05), Self.sourceRefreshInterval)))
      }
      sleeper = sleep
      await sleep.value
    }
  }

  private func pollSource(_ source: Source) async {
    let login: String
    do {
      login = try await viewerLogin(source)
    } catch {
      guard !(error is CancellationError), !Task.isCancelled else { return }
      await finish(source, outcomes: [], errors: [error as? GitHubError ?? .transport(.unknown)])
      return
    }
    var errors: [GitHubError] = []
    let now = Date()
    let provider = source.provider
    if source.discoveryForced
      || now.timeIntervalSince(source.lastDiscovery) >= Self.discoveryInterval
    {
      let result = await RepoDiscovery.discover(
        previous: source.discovery.repos, now: now,
        candidates: { try await provider.repos() },
        latestRun: { repo in
          try await provider.latestRun(
            repo: repo, actor: login, since: now.addingTimeInterval(-RepoDiscovery.window))
        })
      guard !Task.isCancelled else { return }
      if let error = result.error {
        errors.append(error)
      } else {
        source.discovery = result
        source.lastDiscovery = now
        source.discoveryForced = false
      }
    }
    let list = source.discovery.repos
    let known = metas
    let showBuiltIn = BuiltInRuns.isShown(in: .standard)
    shownBuiltIn = showBuiltIn
    let outcomes = await withTaskGroup(of: Outcome.self) { group in
      for repo in list {
        group.addTask {
          await Self.fetch(
            client: provider, repo: repo, viewer: login, cached: known[repo.key], now: now,
            showBuiltIn: showBuiltIn)
        }
      }
      var all: [Outcome] = []
      for await outcome in group { all.append(outcome) }
      return all
    }
    guard !Task.isCancelled else { return }
    errors += outcomes.compactMap { outcome -> GitHubError? in
      if case .failure(let error) = outcome.result { error } else { nil }
    }
    await finish(source, outcomes: outcomes, errors: errors)
  }

  private func finish(_ source: Source, outcomes: [Outcome], errors: [GitHubError]) async {
    let primary =
      errors.first { $0 == .unauthorized }
      ?? errors.first { if case .rateLimited = $0 { true } else { false } }
      ?? errors.first { $0 != .notFound }
    if primary == .unauthorized {
      source.viewer = nil
      source.discovery = Discovery(repos: [], error: nil)
      source.discoveryForced = true
      if source.isGitHub {
        ghInstalled = await Task.detached { GhTokenReader.isInstalled() }.value
      }
    }
    source.failures = PollPolicy.failures(after: primary, previous: source.failures)
    source.lastError = primary
    source.errors = errors
    source.anySuccess = outcomes.contains { if case .success = $0.result { true } else { false } }
    apply(outcomes: outcomes)
  }

  private func viewerLogin(_ source: Source) async throws -> String {
    if let viewer = source.viewer { return viewer }
    let login = try await source.provider.viewer().login
    source.viewer = login
    return login
  }

  private nonisolated static let metaLifetime: TimeInterval = 300
  private nonisolated static let discoveryInterval: TimeInterval = 300
  private nonisolated static let sourceRefreshInterval: TimeInterval = 60

  private nonisolated static func fetch(
    client: any RunProvider, repo: Repo, viewer: String, cached: RepoMeta?, now: Date,
    showBuiltIn: Bool
  ) async -> Outcome {
    do {
      let meta: RepoMeta
      if let cached, now.timeIntervalSince(cached.fetchedAt) < metaLifetime {
        meta = cached
      } else {
        let branches = try? await client.branches(repo: repo)
        meta = RepoMeta(repo: repo, branches: branches ?? cached?.branches, fetchedAt: now)
      }
      var runs = BuiltInRuns.filter(try await client.runs(repo: repo), shown: showBuiltIn)
      func grouped(_ runs: [WorkflowRun]) -> RepoGroup? {
        RunGrouping.groups(
          [
            RepoRuns(
              id: meta.repo.id, fullName: meta.repo.fullName,
              defaultBranch: meta.repo.defaultBranch, runs: runs, liveBranches: meta.branches)
          ],
          viewer: viewer
        ).first
      }
      let shown = await client.resolvingPullRequests(
        grouped(runs)?.branches.flatMap(\.runs) ?? [], repo: repo)
      let active = shown.filter { $0.state == .running || $0.state == .queued }
      let history: [WorkflowRun]
      do {
        history = try await client.timingHistory(for: active, repo: repo)
      } catch GitHubError.unauthorized {
        throw GitHubError.unauthorized
      } catch GitHubError.rateLimited(let resumeAt) {
        throw GitHubError.rateLimited(resumeAt: resumeAt)
      } catch {
        history = []
      }
      let timings = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      runs = runs.map { timings[$0.id] ?? $0 }
      let resolved = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let group = grouped(
        runs.map { run in
          var run = run
          run.pullRequests = resolved[run.id]?.pullRequests ?? run.pullRequests
          return run
        })
      var etas: [Int: ETAEstimate] = [:]
      for run in group?.branches.flatMap(\.runs) ?? [] where run.state == .running {
        etas[run.id] = ETA.estimate(for: run, among: history)
      }
      let fetched = Fetched(
        id: repo.key, host: repo.host, meta: meta, group: group,
        rawRuns: history, etas: etas)
      return Outcome(repo: repo, result: .success(fetched))
    } catch let error as GitHubError {
      return Outcome(repo: repo, result: .failure(error))
    } catch {
      return Outcome(repo: repo, result: .failure(.transport(.unknown)))
    }
  }

  private func rowKey(_ repo: String, _ run: Int) -> String {
    "\(repo)#\(run)"
  }

  private func apply(outcomes: [Outcome]) {
    let list = RepoDiscovery.merge(sources.map(\.discovery))
    let now = Date()
    if outcomes.contains(where: { if case .success = $0.result { true } else { false } }) {
      lastUpdated = now
    }
    var events: [RunEvent] = []
    var live = Set<String>()
    var ordered: [RepoModel] = []
    for repo in list {
      let id = repo.key
      let model = models[id] ?? RepoModel(repo: repo)
      models[id] = model
      guard let outcome = outcomes.first(where: { $0.repo.key == id }) else {
        if let last = menuInputs[id] { live.formUnion(last.visible.map { rowKey(id, $0.id) }) }
        ordered.append(model)
        continue
      }
      switch outcome.result {
      case .success(let fetched):
        if model.problem != nil { model.problem = nil }
        metas[id] = fetched.meta
        let visible = fetched.group?.branches.flatMap(\.runs) ?? []
        live.formUnion(visible.map { rowKey(id, $0.id) })
        apply(fetched, to: model)
        menuInputs[id] = MenuBarRepo(visible: visible, history: fetched.rawRuns)
        var tracker = trackers[id] ?? RunTracker()
        events += tracker.ingest(repo: id, runs: visible, host: fetched.host)
        trackers[id] = tracker
      case .failure(.notFound):
        model.problem = .gone
        metas[id] = nil
        model.branches = []
        model.glyph = nil
        model.newest = nil
        menuInputs[id] = nil
      case .failure:
        if let last = menuInputs[id] { live.formUnion(last.visible.map { rowKey(id, $0.id) }) }
      }
      ordered.append(model)
    }
    let byId = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
    let newOrder = RepoCardRules.newestFirst(ordered.map { (id: $0.id, newest: $0.newest) })
      .compactMap { byId[$0] }
    if newOrder.map(\.id) != repos.map(\.id) { repos = newOrder }
    let ids = Set(list.map(\.key))
    models = models.filter { ids.contains($0.key) }
    metas = metas.filter { ids.contains($0.key) }
    menuInputs = menuInputs.filter { ids.contains($0.key) }
    trackers = trackers.filter { ids.contains($0.key) }
    rows = rows.filter { live.contains($0.key) }

    let github = sources.first { $0.isGitHub }
    let gitLabs = sources.filter { !$0.isGitHub }
    let githubErrors = !ghInstalled && !gitLabs.isEmpty ? [] : github?.errors ?? []
    let githubNotice = NoticePolicy.notice(
      ghInstalled: ghInstalled || !gitLabs.isEmpty,
      tokenAvailable: true, repoCount: list.count, errors: githubErrors, lastUpdated: lastUpdated)
    let gitLabSignedOut = gitLabs.contains { $0.signedOut }
    let newNotice = NoticePolicy.combined(github: githubNotice, gitLabSignedOut: gitLabSignedOut)
    if newNotice != notice { notice = newNotice }
    let githubSignedOut = githubErrors.contains(.unauthorized) || githubNotice == .ghMissing
    let newConnections = Connections.rows(
      github: ConnectionAccount(
        host: Repo.githubHost, login: github?.viewer, signedOut: githubSignedOut || !ghInstalled),
      gitLab: gitLabs.map {
        ConnectionAccount(host: $0.provider.host, login: $0.viewer, signedOut: $0.signedOut)
      })
    if newConnections != connections { connections = newConnections }
    let newMenuBarGlyph = MenuBarGlyphs.glyph(
      repos: newOrder.compactMap { menuInputs[$0.id] },
      signedOut: (githubSignedOut || gitLabSignedOut) && newOrder.isEmpty,
      now: now)
    if newMenuBarGlyph != menuBarGlyph { menuBarGlyph = newMenuBarGlyph }
    onSession?(
      SessionPolicy.sample(
        signedOutSignal: githubSignedOut, anySuccess: github?.anySuccess ?? false))
    onGitLabSession?(
      SessionPolicy.sample(
        signedOutSignal: gitLabSignedOut, anySuccess: gitLabs.contains { $0.anySuccess }))
    hasActiveRun = menuInputs.values.contains {
      $0.visible.contains { $0.state == .running || $0.state == .queued }
    }
    if !events.isEmpty { onEvents?(events) }
  }

  private func apply(_ fetched: Fetched, to model: RepoModel) {
    let branches = (fetched.group?.branches ?? []).map { branch in
      BranchModel(
        name: branch.branch,
        rows: branch.runs.map { run in
          let eta = fetched.etas[run.id]
          let key = rowKey(fetched.id, run.id)
          if let row = rows[key] {
            row.update(run: run, eta: eta, host: fetched.host)
            return row
          }
          let row = RunRowModel(run: run, eta: eta, host: fetched.host)
          rows[key] = row
          return row
        })
    }
    if branches != model.branches { model.branches = branches }
    let visible = fetched.group?.branches.flatMap(\.runs) ?? []
    let glyph = MenuBarGlyphs.glyph(
      for: MenuBarRepo(visible: visible, history: fetched.rawRuns), now: Date())
    if glyph != model.glyph { model.glyph = glyph }
    let newest = visible.map(\.activityDate).max()
    if newest != model.newest { model.newest = newest }
  }
}
