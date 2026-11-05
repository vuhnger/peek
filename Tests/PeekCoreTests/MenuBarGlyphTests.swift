import Foundation
import Testing

@testable import PeekCore

private func running(id: Int, started: TimeInterval = 0, workflow: Int = 1) -> WorkflowRun {
  makeRun(
    id: id, workflow: workflow, status: "in_progress", conclusion: nil, created: started,
    started: started, jobs: [WorkflowJob(name: "ci", status: "in_progress")])
}

private func history(workflow: Int = 1) -> [WorkflowRun] {
  (1...3).map {
    successfulRun(id: 100 + $0, workflow: workflow, created: Double($0 * -1000), duration: 60)
  }
}

private func repo(_ visible: [WorkflowRun], history: [WorkflowRun] = []) -> MenuBarRepo {
  MenuBarRepo(visible: visible, history: history)
}

struct MenuBarGlyphTests {
  @Test func aLiveRunBeatsFailedAndPassedRuns() {
    let runs = [
      running(id: 1), makeRun(id: 2, workflow: 2, conclusion: "failure"),
      makeRun(id: 3, workflow: 3),
    ]
    #expect(MenuBarGlyphs.glyph(for: repo(runs), now: at(10)) == .running(progress: nil))
  }

  @Test func aNewerPassedRunBeatsAnOlderFailedRun() {
    let runs = [
      makeRun(id: 1, workflow: 1, conclusion: "failure", created: 0),
      makeRun(id: 2, workflow: 2, created: 100),
    ]
    #expect(MenuBarGlyphs.glyph(for: repo(runs), now: at(200)) == .passed)
  }

  @Test func aNewerFailedRunBeatsAnOlderPassedRun() {
    let runs = [
      makeRun(id: 1, workflow: 1, created: 0),
      makeRun(id: 2, workflow: 2, conclusion: "failure", created: 100),
    ]
    #expect(MenuBarGlyphs.glyph(for: repo(runs), now: at(200)) == .failed)
  }

  @Test func skippedAndCancelledRunsGiveNoGlyph() {
    let runs = [
      makeRun(id: 1, conclusion: "skipped"), makeRun(id: 2, workflow: 2, conclusion: "cancelled"),
    ]
    #expect(MenuBarGlyphs.glyph(for: repo(runs), now: at(10)) == nil)
  }

  @Test func passedQueuedAndRunningMapToTheirOwnGlyph() {
    let queued = makeRun(id: 1, status: "queued", conclusion: nil)
    #expect(MenuBarGlyphs.glyph(for: repo([queued]), now: at(10)) == .queued)
    #expect(MenuBarGlyphs.glyph(for: repo([makeRun(id: 2)]), now: at(10)) == .passed)
    #expect(
      MenuBarGlyphs.glyph(for: repo([running(id: 3), queued]), now: at(10))
        == .running(progress: nil))
  }

  @Test func runningProgressUsesTheConservativeRemainingEstimate() {
    let glyph = MenuBarGlyphs.glyph(
      for: repo([running(id: 1)], history: history()), now: at(30))
    #expect(glyph == .running(progress: 5.0 / 12))
  }

  @Test func progressSnapsToTwelfthsSoTheIconRedrawsRarely() {
    let a = MenuBarGlyphs.glyph(for: repo([running(id: 1)], history: history()), now: at(31))
    let b = MenuBarGlyphs.glyph(for: repo([running(id: 1)], history: history()), now: at(32))
    #expect(a == b)
  }

  @Test func runningPastAllComparableHistoryIsOverdue() {
    let glyph = MenuBarGlyphs.glyph(
      for: repo([running(id: 1)], history: history()), now: at(90))
    #expect(glyph == .overdue)
  }

  @Test func anOverdueRunWinsOverAFresherRunningOne() {
    let runs = [running(id: 1, started: 0, workflow: 1), running(id: 2, started: 80, workflow: 2)]
    let past = history(workflow: 1) + history(workflow: 2)
    #expect(MenuBarGlyphs.glyph(for: repo(runs, history: past), now: at(90)) == .overdue)
  }

  @Test func neutralOnlyAndEmptyReposShowNothing() {
    let skipped = makeRun(id: 1, conclusion: "skipped")
    #expect(MenuBarGlyphs.glyph(for: repo([skipped]), now: at(10)) == nil)
    #expect(MenuBarGlyphs.glyph(for: repo([]), now: at(10)) == nil)
  }

  @Test func aQueuedRepoShowsQueuedNextToFailedPassedAndEmptyRepos() {
    let repos = [
      repo([makeRun(id: 1, conclusion: "failure")]), repo([makeRun(id: 2)]), repo([]),
      repo([makeRun(id: 3, conclusion: "skipped")]),
      repo([makeRun(id: 4, status: "queued", conclusion: nil)]),
    ]
    #expect(MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10)) == .queued)
  }

  @Test func failedAndPassedReposShowTheIdleIcon() {
    let repos = [repo([makeRun(id: 1, conclusion: "failure")]), repo([makeRun(id: 2)])]
    #expect(MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10)) == .idle)
  }

  @Test func aRepoWithAFailedAndARunningWorkflowShowsTheRunningGlyph() {
    let runs = [makeRun(id: 1, workflow: 1, conclusion: "failure"), running(id: 2, workflow: 2)]
    #expect(
      MenuBarGlyphs.glyph(repos: [repo(runs)], signedOut: false, now: at(10))
        == .running(progress: nil))
  }

  @Test func aFailedRepoNextToARunningOneShowsOnlyTheRunningGlyph() {
    let repos = [repo([makeRun(id: 1, conclusion: "failure")]), repo([running(id: 2)])]
    #expect(
      MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10))
        == .running(progress: nil))
  }

  @Test func allPassedShowsTheIdleIcon() {
    let repos = [repo([makeRun(id: 1)]), repo([makeRun(id: 2)])]
    #expect(MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10)) == .idle)
  }

  @Test func nothingWatchedShowsTheIdleIcon() {
    #expect(MenuBarGlyphs.glyph(repos: [], signedOut: false, now: at(10)) == .idle)
    #expect(MenuBarGlyphs.glyph(repos: [repo([])], signedOut: false, now: at(10)) == .idle)
  }

  @Test func mixedActiveAndPassedShowsOnlyTheActiveOnes() {
    let repos = [repo([makeRun(id: 1)]), repo([running(id: 2)]), repo([makeRun(id: 3)])]
    #expect(
      MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10))
        == .running(progress: nil))
  }

  @Test func twoReposRunningAtOnceShowOneGlyph() {
    let repos = [repo([running(id: 1)]), repo([running(id: 2)])]
    #expect(
      MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10))
        == .running(progress: nil))
  }

  @Test func anOverdueRepoWinsOverARunningRepo() {
    let repos = [
      repo([running(id: 1, started: 80)], history: history()),
      repo([running(id: 2, started: 0)], history: history()),
    ]
    #expect(MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(90)) == .overdue)
  }

  @Test func theOldestRunAcrossReposSetsTheProgress() {
    let repos = [
      repo([running(id: 1, started: 20)], history: history()),
      repo([running(id: 2, started: 0)], history: history()),
    ]
    #expect(
      MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(30))
        == .running(progress: 5.0 / 12))
  }

  @Test func eachRunUsesItsOwnReposHistory() {
    let ownHistory = [repo([running(id: 1)], history: history()), repo([])]
    let otherHistory = [repo([running(id: 1)]), repo([], history: history())]
    #expect(
      MenuBarGlyphs.glyph(repos: ownHistory, signedOut: false, now: at(30))
        == .running(progress: 5.0 / 12))
    #expect(
      MenuBarGlyphs.glyph(repos: otherHistory, signedOut: false, now: at(30))
        == .running(progress: nil))
  }

  @Test func aRunningRepoBeatsAQueuedRepo() {
    let repos = [
      repo([makeRun(id: 1, status: "queued", conclusion: nil)]), repo([running(id: 2)]),
    ]
    #expect(
      MenuBarGlyphs.glyph(repos: repos, signedOut: false, now: at(10))
        == .running(progress: nil))
  }

  @Test func signedOutIsASingleLockWhateverTheRepos() {
    let repos = [repo([makeRun(id: 1, conclusion: "failure")]), repo([makeRun(id: 2)])]
    #expect(MenuBarGlyphs.glyph(repos: repos, signedOut: true, now: at(10)) == .signedOut)
    #expect(MenuBarGlyphs.glyph(repos: [], signedOut: true, now: at(10)) == .signedOut)
  }
}
