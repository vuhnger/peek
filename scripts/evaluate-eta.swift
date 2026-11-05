import CryptoKit
import Foundation

private struct EvaluationRecord: Decodable {
  let repo: String
  let split: String
  let run: WorkflowRun

  private enum CodingKeys: String, CodingKey {
    case repo, split
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repo = try container.decode(String.self, forKey: .repo)
    split = try container.decode(String.self, forKey: .split)
    run = try WorkflowRun(from: decoder)
  }
}

private struct EvaluationDataset: Decodable {
  let runs: [EvaluationRecord]
}

@main
private enum EvaluateETA {
  static func main() {
    do {
      try evaluate()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static func evaluate() throws {
    guard CommandLine.arguments.count == 3 else {
      throw invalid("Usage: evaluate-eta <dataset.json> <results.json>")
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let original = try Data(contentsOf: input)
    guard var document = try JSONSerialization.jsonObject(with: original) as? [String: Any],
      var rawRuns = document["runs"] as? [[String: Any]]
    else { throw invalid("Dataset must contain a runs array") }
    for index in rawRuns.indices {
      if let numbers = rawRuns[index]["pull_requests"] as? [Int] {
        rawRuns[index]["pull_requests"] = numbers.map { ["number": $0] }
      }
    }
    document["runs"] = rawRuns
    let dataset = try JSONDecoder.github.decode(
      EvaluationDataset.self, from: JSONSerialization.data(withJSONObject: document))
    let holdout = dataset.runs.filter { $0.split == "holdout" && $0.run.state == .passed }
    guard !holdout.isEmpty else { throw invalid("Dataset has no successful holdout runs") }
    let clock = ISO8601DateFormatter()
    var rows: [[String: Any]] = []
    for record in holdout {
      guard let completed = record.run.updatedAt else { continue }
      for checkpoint in [0, 30, 60, 120] {
        let now = record.run.queuedAt.addingTimeInterval(Double(checkpoint))
        guard now < completed else { continue }
        let history = dataset.runs.filter {
          $0.repo == record.repo && $0.run.id != record.run.id && $0.run.state == .passed
            && ($0.run.updatedAt.map { $0 < now } ?? false)
        }
        var target = record.run
        target.jobs = visibleJobs(record.run.jobs ?? [], at: now)
        let before = baseline(for: record.run, among: history.map(\.run), now: now)
        let estimate = ETA.estimate(for: target, among: history.map(\.run))
        let remaining = estimate?.remaining(elapsed: now.timeIntervalSince(target.queuedAt))
        let status =
          remaining != nil
          ? "forecast"
          : estimate != nil
            ? "history_exhausted"
            : target.jobs?.isEmpty != false ? "waiting_for_jobs" : "no_comparable_history"
        rows.append([
          "key": "\(record.repo):\(record.run.id):\(checkpoint)", "repo": record.repo,
          "runID": record.run.id, "runAttempt": record.run.runAttempt ?? 1,
          "checkpointSeconds": checkpoint, "predictionAt": clock.string(from: now),
          "actualRemainingSeconds": completed.timeIntervalSince(now),
          "baselineRemainingSeconds": nullable(before?.remaining),
          "baselineSampleCount": before?.samples ?? 0,
          "afterRemainingSeconds": nullable(remaining),
          "afterSampleCount": estimate?.sampleCount ?? 0,
          "afterBuffer": nullable(estimate?.buffer), "afterStatus": status,
          "observedJobCount": target.jobs?.count ?? 0,
          "historyWarmupCount": history.filter { $0.split == "warmup" }.count,
          "historyEarlierHoldoutCount": history.filter { $0.split == "holdout" }.count,
        ])
      }
    }
    guard !rows.isEmpty else { throw invalid("No holdout run has a valid completion timestamp") }
    let checkpoints = Dictionary(grouping: rows) { String($0["checkpointSeconds"] as? Int ?? 0) }
    let repositories = Dictionary(grouping: rows) { $0["repo"] as? String ?? "" }
    let attempts = Dictionary(grouping: rows) {
      ($0["runAttempt"] as? Int ?? 1) > 1 ? "retry" : "first"
    }
    let result: [String: Any] = [
      "datasetSHA256": SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
      "baselineSourceCommit": "eb5d322", "generatedAt": clock.string(from: Date()),
      "target": "Current-attempt queue-to-workflow-completion time",
      "calibration":
        "Only completed past history is available; earlier holdout outcomes can enter later forecasts",
      "warmupRunCount": dataset.runs.filter { $0.split == "warmup" }.count,
      "holdoutRunCount": holdout.count,
      "summary": summarize(rows), "byCheckpointSeconds": checkpoints.mapValues(summarize),
      "byRepository": repositories.mapValues(summarize), "byAttempt": attempts.mapValues(summarize),
      "cases": rows,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output)
    print("Evaluated \(holdout.count) held-out runs at \(rows.count) checkpoints")
  }

  static func visibleJobs(_ jobs: [WorkflowJob], at now: Date) -> [WorkflowJob] {
    jobs.compactMap { job in
      guard let available = job.createdAt ?? job.startedAt, available <= now else { return nil }
      let finished = job.completedAt.map { $0 <= now } ?? false
      let started = job.startedAt.map { $0 <= now } ?? false
      return WorkflowJob(
        name: job.name, status: finished ? job.status : (started ? "in_progress" : "queued"),
        conclusion: finished ? job.conclusion : nil, createdAt: job.createdAt,
        startedAt: started ? job.startedAt : nil, completedAt: finished ? job.completedAt : nil)
    }
  }

  static func baseline(for run: WorkflowRun, among runs: [WorkflowRun], now: Date) -> (
    remaining: Double, samples: Int
  )? {
    let durations =
      runs
      .filter { $0.workflowId == run.workflowId && $0.event == run.event && $0.state == .passed }
      .sorted { $0.createdAt > $1.createdAt }
      .prefix(10)
      .compactMap { candidate -> Double? in
        guard let start = candidate.runStartedAt, let finish = candidate.updatedAt else {
          return nil
        }
        let duration = finish.timeIntervalSince(start)
        return duration > 0 ? duration : nil
      }
    guard let duration = median(durations) else { return nil }
    return (duration - now.timeIntervalSince(run.runStartedAt ?? run.createdAt), durations.count)
  }

  static func summarize(_ rows: [[String: Any]]) -> [String: Any] {
    let pairs = rows.filter {
      $0["baselineRemainingSeconds"] is Double && $0["afterRemainingSeconds"] is Double
    }
    let statuses = ["forecast", "waiting_for_jobs", "no_comparable_history", "history_exhausted"]
    return [
      "baselineAll": metrics(rows, field: "baselineRemainingSeconds"),
      "afterAll": metrics(rows, field: "afterRemainingSeconds"),
      "pairedBaseline": metrics(pairs, field: "baselineRemainingSeconds"),
      "pairedAfter": metrics(pairs, field: "afterRemainingSeconds"),
      "afterStatuses": Dictionary(
        uniqueKeysWithValues: statuses.map { status in
          (status, rows.filter { $0["afterStatus"] as? String == status }.count)
        }),
    ]
  }

  static func metrics(_ rows: [[String: Any]], field: String) -> [String: Any] {
    let errors = rows.compactMap { row -> Double? in
      guard let prediction = row[field] as? Double,
        let actual = row["actualRemainingSeconds"] as? Double
      else { return nil }
      return prediction - actual
    }
    let underestimates = errors.filter { $0 < 0 }.count
    return [
      "eligibleCases": rows.count, "forecastCases": errors.count,
      "forecastAvailability": nullable(
        rows.isEmpty ? nil : Double(errors.count) / Double(rows.count)),
      "underestimatedCases": underestimates,
      "underestimationRate": nullable(
        errors.isEmpty ? nil : Double(underestimates) / Double(errors.count)),
      "meanAbsoluteErrorSeconds": nullable(mean(errors.map(abs))),
      "medianAbsoluteErrorSeconds": nullable(median(errors.map(abs))),
      "meanSignedErrorSeconds": nullable(mean(errors)),
      "pinballLoss90Seconds": nullable(mean(errors.map { $0 < 0 ? -0.9 * $0 : 0.1 * $0 })),
    ]
  }

  static func mean(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  static func nullable(_ value: Double?) -> Any {
    value.map { $0 as Any } ?? NSNull()
  }

  static func invalid(_ message: String) -> NSError {
    NSError(domain: "ETAEvaluation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
