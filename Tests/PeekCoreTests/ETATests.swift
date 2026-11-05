import Foundation
import Testing

@testable import PeekCore

struct ETATests {
  private let running = makeRun(
    id: 999, workflow: 1, status: "in_progress", conclusion: nil, event: "push",
    created: 10_000, started: 10_000, jobs: [WorkflowJob(name: "ci", status: "in_progress")])

  @Test func usesTheNinetiethPercentileWithAnInitialTenPercentBuffer() throws {
    let runs = (1...10).map {
      successfulRun(id: $0, created: Double($0), duration: Double($0 * 10))
    }
    let estimate = try #require(ETA.estimate(for: running, among: runs))
    #expect(abs(try #require(estimate.remaining(elapsed: 0)) - 99) < 0.001)
    #expect(estimate.sampleCount == 10)
    #expect(estimate.buffer == 1.1)
  }

  @Test func usesThirtyNewestComparableValidSuccessfulSamples() throws {
    var runs = (1...35).map {
      successfulRun(id: $0, created: Double($0), duration: 100)
    }
    runs.append(successfulRun(id: 40, workflow: 2, created: 500, duration: 9000))
    runs.append(successfulRun(id: 41, event: "schedule", created: 500, duration: 9000))
    runs.append(makeRun(id: 42, conclusion: "failure", created: 500, updated: 9500))
    runs.append(makeRun(id: 43, created: 600, jobs: [WorkflowJob(name: "ci")]))
    let estimate = try #require(ETA.estimate(for: running, among: runs))
    #expect(estimate.durations == Array(repeating: 100, count: 30))
    #expect(estimate.buffer == 1.1)
  }

  @Test func recalculatesRemainingTimeFromRunsThatOutlastTheElapsedTime() throws {
    let runs = [60.0, 120, 300, 600].enumerated().map {
      successfulRun(id: $0.offset, created: Double($0.offset), duration: $0.element)
    }
    let estimate = try #require(ETA.estimate(for: running, among: runs))
    #expect(abs(try #require(estimate.remaining(elapsed: 100)) - 560) < 0.001)
    #expect(abs(try #require(estimate.remaining(elapsed: 590)) - 70) < 0.001)
    #expect(estimate.remaining(elapsed: 600) == nil)
    #expect(estimate.remaining(elapsed: 700) == nil)
  }

  @Test func separatesPartialRetriesFromFreshRuns() throws {
    var runs = [successfulRun(id: 1, created: 1, duration: 600)]
    for index in 2...4 {
      var retry = successfulRun(id: index, created: Double(index), duration: 20)
      retry.runAttempt = 2
      runs.append(retry)
    }
    let fresh = try #require(ETA.estimate(for: running, among: runs))
    #expect(fresh.durations == [600])
    var retry = running
    retry.runAttempt = 2
    #expect(ETA.estimate(for: retry, among: runs)?.durations == [20, 20, 20])
  }

  @Test func theSafetyMarginDoesNotDisappearWhileTheClockAdvances() throws {
    let estimate = try #require(
      ETA.estimate(
        for: running, among: [successfulRun(id: 1, created: 0, duration: 100)]))
    let initial = try #require(estimate.remaining(elapsed: 0))
    let later = try #require(estimate.remaining(elapsed: 50))
    #expect(abs(initial - (later + 50)) < 0.001)
  }

  @Test func matchesObservedJobsAndExcludesKnownSkippedJobsWithoutGuessingFutureJobs() {
    var partial = running
    partial.jobs = [WorkflowJob(name: "lint"), WorkflowJob(name: "test", conclusion: "skipped")]
    var short = successfulRun(id: 1, created: 1, duration: 60)
    short.jobs = [WorkflowJob(name: "lint", conclusion: "success")]
    var full = successfulRun(id: 2, created: 2, duration: 600)
    full.jobs = short.jobs! + [WorkflowJob(name: "test", conclusion: "success")]
    #expect(ETA.estimate(for: partial, among: [short, full])?.durations == [60])
    partial.jobs = [WorkflowJob(name: "lint", status: "in_progress")]
    #expect(ETA.estimate(for: partial, among: [short, full])?.sampleCount == 2)
    partial.jobs = [WorkflowJob(name: "new-job", status: "in_progress")]
    #expect(ETA.estimate(for: partial, among: [short, full]) == nil)
  }

  @Test func doesNotInventAWorkloadBeforeJobsAreAvailable() {
    var unknown = running
    unknown.jobs = nil
    let history = [successfulRun(id: 1, created: 0, duration: 60)]
    #expect(ETA.estimate(for: unknown, among: history) == nil)
    unknown.jobs = []
    #expect(ETA.estimate(for: unknown, among: history) == nil)
    unknown = running
    unknown.runAttempt = nil
    #expect(ETA.estimate(for: unknown, among: history) == nil)
  }

  @Test func includesQueueTimeButExcludesTheGapBeforeARetry() throws {
    let queued = makeRun(
      id: 1, created: 0, started: 30, updated: 150,
      jobs: [WorkflowJob(name: "ci", conclusion: "success")])
    #expect(ETA.estimate(for: running, among: [queued])?.durations == [150])
    var retry = makeRun(
      id: 2, created: 0, started: 3600, updated: 3660, attempt: 2,
      jobs: [WorkflowJob(name: "ci", conclusion: "success")])
    var target = running
    target.runAttempt = 2
    #expect(ETA.estimate(for: target, among: [retry])?.durations == [60])
    retry.runAttempt = 1
    #expect(ETA.estimate(for: running, among: [retry])?.durations == [3660])
  }

  @Test func ignoresMissingInvalidAndNonSuccessfulDurations() {
    let jobs = [WorkflowJob(name: "ci")]
    let invalid = [
      makeRun(id: 1, jobs: jobs),
      makeRun(id: 2, created: 0, started: 100, updated: 40, jobs: jobs),
      makeRun(id: 3, created: 10, updated: 5, jobs: jobs),
      makeRun(id: 4, conclusion: "failure", created: 0, updated: 60, jobs: jobs),
    ]
    #expect(ETA.estimate(for: running, among: invalid) == nil)
    #expect(ETA.estimate(for: running, among: []) == nil)
    let history = invalid + [successfulRun(id: 5, created: 0, duration: 90)]
    #expect(ETA.estimate(for: running, among: history)?.durations == [90])
  }

  @Test func calibratesTheBufferUsingEarlierPredictionsOnly() throws {
    let growing = (0..<20).map {
      successfulRun(id: $0, created: Double($0), duration: pow(2, Double($0)))
    }
    let estimate = try #require(ETA.estimate(for: running, among: growing))
    #expect(estimate.buffer > 1.1)
    #expect(try #require(estimate.remaining(elapsed: 0)) >= pow(2, 19))
  }

  @Test func progressHandlesNegativeNonFiniteAndExhaustedHistory() throws {
    let estimate = try #require(
      ETA.estimate(
        for: running, among: [successfulRun(id: 1, created: 0, duration: 120)]))
    #expect(estimate.progress(elapsed: -5).fraction == 0)
    #expect(estimate.progress(elapsed: .nan).fraction == 0)
    #expect(estimate.remaining(elapsed: .infinity) == nil)
    #expect(estimate.progress(elapsed: 30).fraction < 0.25)
    #expect(!estimate.progress(elapsed: 119).isOverdue)
    #expect(estimate.progress(elapsed: 120).isOverdue)
    #expect(estimate.progress(elapsed: 150).fraction == 1)
    #expect(estimate.progress(elapsed: 150).overdueBy == 30)
  }
}
