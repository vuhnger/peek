import AppKit
import Foundation
import Observation
import PeekCore

@MainActor @Observable
final class RunRowModel: Identifiable {
  let id: Int
  private(set) var workflow: String
  private(set) var pullRequest: Int?
  private(set) var isMergeRequest: Bool
  private(set) var title: String
  private(set) var state: RunState
  private(set) var starter: String
  private(set) var avatar: URL?
  private(set) var url: URL?
  private(set) var startedAt: Date
  private(set) var activityAt: Date
  private(set) var estimate: ETAEstimate?
  private static let workflowWidthCap: CGFloat = 150

  init(run: WorkflowRun, eta: ETAEstimate?, host: String = Repo.githubHost) {
    id = run.id
    workflow = run.name ?? "Workflow"
    pullRequest = run.pullRequestNumber
    isMergeRequest = run.isMergeRequest == true
    title = run.displayTitle ?? ""
    state = run.state
    starter = Formatting.login(run.actor?.login ?? "")
    avatar = AvatarCache.url(run.actor?.avatarUrl)
    url = run.targetLink(host: host)
    startedAt = run.queuedAt
    activityAt = run.activityDate
    estimate = eta
  }

  func update(run: WorkflowRun, eta: ETAEstimate?, host: String = Repo.githubHost) {
    set(\.workflow, run.name ?? "Workflow")
    set(\.pullRequest, run.pullRequestNumber)
    set(\.isMergeRequest, run.isMergeRequest == true)
    set(\.title, run.displayTitle ?? "")
    set(\.state, run.state)
    set(\.starter, Formatting.login(run.actor?.login ?? ""))
    set(\.avatar, AvatarCache.url(run.actor?.avatarUrl))
    set(\.url, run.targetLink(host: host))
    set(\.startedAt, run.queuedAt)
    set(\.activityAt, run.activityDate)
    set(\.estimate, eta)
  }

  var workflowWidth: CGFloat {
    let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
    let font = NSFont.systemFont(ofSize: size, weight: .medium)
    let measured = NSAttributedString(string: workflow, attributes: [.font: font]).size().width
    return min(Self.workflowWidthCap, ceil(measured) + 2)
  }

  func progress(at now: Date) -> RunProgress? {
    estimate?.progress(elapsed: now.timeIntervalSince(startedAt))
  }

  private func set<Value: Equatable>(
    _ path: ReferenceWritableKeyPath<RunRowModel, Value>, _ value: Value
  ) {
    if self[keyPath: path] != value { self[keyPath: path] = value }
  }
}

struct BranchModel: Identifiable, Equatable {
  let name: String
  let rows: [RunRowModel]

  var id: String { name }

  static func == (lhs: BranchModel, rhs: BranchModel) -> Bool {
    lhs.name == rhs.name && lhs.rows.elementsEqual(rhs.rows, by: ===)
  }
}

enum RepoProblem: Equatable {
  case gone
}

@MainActor @Observable
final class RepoModel: Identifiable {
  let id: String
  let owner: String
  let name: String
  var glyph: MenuBarGlyph?
  var newest: Date?
  var branches: [BranchModel] = []
  var problem: RepoProblem?
  var userExpanded: Bool?

  init(repo: Repo) {
    id = repo.key
    owner = repo.owner
    name = repo.name
  }

  var hasActiveRun: Bool {
    branches.contains { $0.rows.contains { $0.state == .running || $0.state == .queued } }
  }

  var expanded: Bool {
    RepoCardRules.isExpanded(
      hasActiveRun: hasActiveRun, userChoice: userExpanded, hasProblem: problem != nil)
  }

  func toggle() {
    userExpanded = !expanded
  }
}
