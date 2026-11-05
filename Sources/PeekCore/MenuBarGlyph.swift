import Foundation

public enum MenuBarGlyph: Sendable, Equatable {
  case failed
  case running(progress: Double?)
  case overdue
  case queued
  case passed
  case signedOut
  case idle
}

public struct MenuBarRepo: Sendable {
  public let visible: [WorkflowRun]
  public let history: [WorkflowRun]

  public init(visible: [WorkflowRun], history: [WorkflowRun]) {
    self.visible = visible
    self.history = history
  }
}

public enum MenuBarGlyphs {
  private static let progressSteps = 12.0

  public static func glyph(for repo: MenuBarRepo, now: Date) -> MenuBarGlyph? {
    let states = repo.visible.map(\.state)
    if states.contains(.running) { return runningGlyph([repo], now: now) }
    if states.contains(.queued) { return .queued }
    let finished = repo.visible.filter { $0.state == .failed || $0.state == .passed }
    guard let newest = finished.max(by: { $0.activityDate < $1.activityDate }) else { return nil }
    return newest.state == .failed ? .failed : .passed
  }

  public static func glyph(repos: [MenuBarRepo], signedOut: Bool, now: Date) -> MenuBarGlyph {
    if signedOut { return .signedOut }
    let live = repos.map { repo in
      MenuBarRepo(
        visible: repo.visible.filter { $0.state == .running || $0.state == .queued },
        history: repo.history)
    }
    let states = live.flatMap(\.visible).map(\.state)
    if states.contains(.running) { return runningGlyph(live, now: now) }
    return states.isEmpty ? .idle : .queued
  }

  private static func runningGlyph(_ repos: [MenuBarRepo], now: Date) -> MenuBarGlyph {
    let candidates = repos.flatMap { repo in
      repo.visible.filter { $0.state == .running }.map { run in
        let started = run.queuedAt
        let progress = ETA.estimate(for: run, among: repo.history).map {
          $0.progress(elapsed: now.timeIntervalSince(started))
        }
        return (started: started, progress: progress)
      }
    }
    if candidates.contains(where: { $0.progress?.isOverdue == true }) { return .overdue }
    guard let oldest = candidates.min(by: { $0.started < $1.started }),
      let progress = oldest.progress
    else { return .running(progress: nil) }
    return .running(progress: (progress.fraction * progressSteps).rounded() / progressSteps)
  }
}
