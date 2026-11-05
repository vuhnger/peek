import Foundation

public protocol RunProvider: Sendable {
  nonisolated var host: String { get }
  func viewer() async throws -> Viewer
  func repos() async throws -> [Repo]
  func latestRun(repo: Repo, actor: String, since: Date) async throws -> WorkflowRun?
  func runs(repo: Repo) async throws -> [WorkflowRun]
  func branches(repo: Repo) async throws -> Set<String>?
  func resolvingPullRequests(_ runs: [WorkflowRun], repo: Repo) async -> [WorkflowRun]
  func timingHistory(for active: [WorkflowRun], repo: Repo) async throws -> [WorkflowRun]
}

extension RunProvider {
  public func resolvingPullRequests(_ runs: [WorkflowRun], repo: Repo) async -> [WorkflowRun] {
    runs
  }

  public func timingHistory(for active: [WorkflowRun], repo: Repo) async throws -> [WorkflowRun] {
    []
  }
}
