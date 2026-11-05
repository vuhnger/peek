import Foundation

extension JSONDecoder {
  static var github: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public struct Viewer: Decodable, Sendable, Equatable {
  public let id: Int
  public let login: String

  public init(id: Int, login: String) {
    self.id = id
    self.login = login
  }
}

public struct Repo: Decodable, Sendable, Equatable, Identifiable {
  public static let githubHost = "github.com"

  public let id: Int
  public let name: String
  public let fullName: String
  public let defaultBranch: String
  public let pushedAt: Date?
  public var host = Repo.githubHost

  private enum CodingKeys: String, CodingKey {
    case id, name, fullName, defaultBranch, pushedAt
  }

  public init(
    id: Int, name: String, fullName: String, defaultBranch: String, pushedAt: Date?,
    host: String = Repo.githubHost
  ) {
    self.id = id
    self.name = name
    self.fullName = fullName
    self.defaultBranch = defaultBranch
    self.pushedAt = pushedAt
    self.host = host
  }

  public var key: String {
    (host == Self.githubHost ? fullName : "\(host)/\(fullName)").lowercased()
  }

  public var owner: String {
    String(fullName.dropLast(name.count + 1))
  }
}

public struct Branch: Decodable, Sendable, Equatable {
  public let name: String
}

public struct Account: Decodable, Sendable, Equatable {
  public let login: String
  public let avatarUrl: String?

  public init(login: String, avatarUrl: String? = nil) {
    self.login = login
    self.avatarUrl = avatarUrl
  }
}

public struct RepoRef: Decodable, Sendable, Equatable {
  public let id: Int
  public let fullName: String?

  public init(id: Int, fullName: String?) {
    self.id = id
    self.fullName = fullName
  }
}

public struct PullRequestRef: Decodable, Sendable, Equatable {
  public let number: Int

  public init(number: Int) {
    self.number = number
  }
}

public struct WorkflowJob: Decodable, Sendable, Equatable {
  public let name: String
  public let status: String?
  public let conclusion: String?
  public let createdAt: Date?
  public let startedAt: Date?
  public let completedAt: Date?

  public init(
    name: String, status: String? = nil, conclusion: String? = nil,
    createdAt: Date? = nil, startedAt: Date? = nil, completedAt: Date? = nil
  ) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.completedAt = completedAt
  }
}

public struct WorkflowRun: Decodable, Sendable, Equatable, Identifiable {
  public let id: Int
  public let workflowId: Int
  public let createdAt: Date
  public let name: String?
  public let displayTitle: String?
  public let status: String?
  public let conclusion: String?
  public let event: String?
  public let headBranch: String?
  public var pullRequests: [PullRequestRef]?
  public let headSha: String?
  public var runAttempt: Int?
  public let runStartedAt: Date?
  public let updatedAt: Date?
  public let htmlUrl: String?
  public let actor: Account?
  public let triggeringActor: Account?
  public let headRepository: RepoRef?
  public let isMergeRequest: Bool?
  public var jobs: [WorkflowJob]?

  public init(
    id: Int, workflowId: Int, createdAt: Date, name: String?, displayTitle: String?,
    status: String?, conclusion: String?, event: String?, headBranch: String?,
    pullRequests: [PullRequestRef]?, runStartedAt: Date?, updatedAt: Date?, htmlUrl: String?,
    actor: Account?, headRepository: RepoRef?, isMergeRequest: Bool
  ) {
    self.id = id
    self.workflowId = workflowId
    self.createdAt = createdAt
    self.name = name
    self.displayTitle = displayTitle
    self.status = status
    self.conclusion = conclusion
    self.event = event
    self.headBranch = headBranch
    self.pullRequests = pullRequests
    self.headSha = nil
    self.runAttempt = nil
    self.runStartedAt = runStartedAt
    self.updatedAt = updatedAt
    self.htmlUrl = htmlUrl
    self.actor = actor
    self.triggeringActor = nil
    self.headRepository = headRepository
    self.isMergeRequest = isMergeRequest
  }

  public var queuedAt: Date {
    return (runAttempt ?? 1) > 1 ? runStartedAt ?? createdAt : createdAt
  }

  public var state: RunState {
    RunState(status: status, conclusion: conclusion)
  }

  public var branch: String {
    headBranch ?? "unknown"
  }

  public func link(host: String) -> URL? {
    guard let htmlUrl, let url = URL(string: htmlUrl), url.scheme == "https",
      url.host?.lowercased() == host.split(separator: ":").first?.lowercased()
    else { return nil }
    return url
  }

  public func targetLink(host: String) -> URL? {
    guard let run = link(host: host) else { return nil }
    guard let number = pullRequestNumber else { return run }
    let isGitLab = isMergeRequest == true
    let marker = isGitLab ? "/-/" : "/actions/"
    guard let cut = run.path.range(of: marker),
      var components = URLComponents(url: run, resolvingAgainstBaseURL: false)
    else { return run }
    components.path =
      run.path[..<cut.lowerBound] + (isGitLab ? "/-/merge_requests/" : "/pull/") + "\(number)"
    components.query = nil
    components.fragment = nil
    return components.url ?? run
  }

  public var pullRequestNumber: Int? {
    pullRequests?.first?.number
  }

  public var isPullOrMergeRequest: Bool {
    pullRequestNumber != nil || isMergeRequest == true || event == "pull_request"
      || event == "pull_request_target"
  }

  public var activityDate: Date {
    updatedAt ?? createdAt
  }
}

public struct RunsPage: Decodable, Sendable {
  public let runs: [WorkflowRun]

  private enum CodingKeys: String, CodingKey {
    case workflowRuns
  }

  private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: any Decoder) throws {
      value = try? decoder.singleValueContainer().decode(Element.self)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runs = try container.decode([Lossy<WorkflowRun>].self, forKey: .workflowRuns).compactMap(
      \.value)
  }
}

public enum RunState: Sendable, Equatable, CaseIterable {
  case failed
  case running
  case queued
  case passed
  case neutral

  public init(status: String?, conclusion: String?) {
    switch status {
    case "in_progress":
      self = .running
    case "queued", "waiting", "requested", "pending":
      self = .queued
    case "completed":
      switch conclusion {
      case "success": self = .passed
      case "failure", "timed_out", "startup_failure": self = .failed
      case "action_required": self = .queued
      default: self = .neutral
      }
    default:
      self = .neutral
    }
  }

  public var urgency: Int {
    Self.allCases.firstIndex(of: self) ?? Self.allCases.count
  }

  public static func mostUrgent(_ states: [RunState]) -> RunState {
    states.min { $0.urgency < $1.urgency } ?? .neutral
  }
}
