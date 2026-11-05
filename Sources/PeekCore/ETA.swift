import Foundation

public struct ETAEstimate: Sendable, Equatable {
  public let durations: [TimeInterval]
  public let buffer: Double

  public var sampleCount: Int { durations.count }

  public func remaining(elapsed: TimeInterval) -> TimeInterval? {
    guard elapsed.isFinite else { return nil }
    let elapsed = max(0, elapsed)
    let survivors = durations.filter { $0 > elapsed }
    guard let duration = ETA.percentile(survivors) else { return nil }
    return duration * buffer - elapsed
  }

  public func progress(elapsed: TimeInterval) -> RunProgress {
    guard elapsed.isFinite else {
      return RunProgress(fraction: 0, isOverdue: false, overdueBy: 0)
    }
    let elapsed = max(0, elapsed)
    guard let remaining = remaining(elapsed: elapsed) else {
      return RunProgress(
        fraction: 1, isOverdue: true, overdueBy: max(0, elapsed - (durations.max() ?? 0)))
    }
    return RunProgress(
      fraction: elapsed / (elapsed + remaining), isOverdue: false, overdueBy: 0)
  }
}

public struct RunProgress: Sendable, Equatable {
  public let fraction: Double
  public let isOverdue: Bool
  public let overdueBy: TimeInterval
}

public enum ETA {
  public static let maxSamples = 30

  public static func estimate(
    for run: WorkflowRun, among runs: [WorkflowRun], predictionAt: Date = Date()
  ) -> ETAEstimate? {
    let durations =
      runs
      .filter { $0.id != run.id && $0.state == .passed && comparable(run, $0) }
      .sorted { $0.queuedAt > $1.queuedAt }
      .compactMap { candidate -> TimeInterval? in
        guard let finished = candidate.updatedAt,
          finished <= predictionAt,
          finished >= (candidate.runStartedAt ?? candidate.queuedAt)
        else { return nil }
        let duration = finished.timeIntervalSince(candidate.queuedAt)
        return duration.isFinite && duration > 0 ? duration : nil
      }
      .prefix(maxSamples)
      .reversed()
    guard !durations.isEmpty else { return nil }
    let samples = Array(durations)
    let ratios = samples.indices.dropFirst(5).compactMap { index -> Double? in
      guard let prediction = percentile(Array(samples[..<index])) else { return nil }
      return samples[index] / prediction
    }
    let buffer = ratios.count >= 10 ? max(1.1, percentile(ratios) ?? 1.1) : 1.1
    return ETAEstimate(durations: samples, buffer: buffer)
  }

  public static func comparable(_ run: WorkflowRun, _ candidate: WorkflowRun) -> Bool {
    guard run.workflowId == candidate.workflowId, run.event == candidate.event,
      let attempt = run.runAttempt, let candidateAttempt = candidate.runAttempt,
      (attempt > 1) == (candidateAttempt > 1),
      attempt <= 1 || run.runStartedAt != nil,
      candidateAttempt <= 1 || candidate.runStartedAt != nil,
      let jobs = run.jobs, !jobs.isEmpty, let history = candidate.jobs, !history.isEmpty
    else { return false }
    let executed = Set(history.filter { $0.conclusion != "skipped" }.map(\.name))
    let selected = Set(jobs.filter { $0.conclusion != "skipped" }.map(\.name))
    let skipped = Set(jobs.filter { $0.conclusion == "skipped" }.map(\.name))
    return !selected.isEmpty && selected.isSubset(of: executed)
      && skipped.isDisjoint(with: executed)
  }

  static func percentile(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[Int(ceil(Double(sorted.count) * 0.9)) - 1]
  }
}
