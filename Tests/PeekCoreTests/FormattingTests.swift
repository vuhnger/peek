import Foundation
import Testing

@testable import PeekCore

struct FormattingTests {
  @Test(
    arguments: [
      (0.0, "0s"), (49, "49s"), (59.9, "59s"), (60, "1m 0s"), (194, "3m 14s"),
      (3599, "59m 59s"), (3720, "1h 2m"), (7200, "2h 0m"), (-5, "0s"),
    ] as [(Double, String)])
  func formatsDurations(seconds: Double, expected: String) {
    #expect(Formatting.duration(seconds) == expected)
  }

  @Test(
    arguments: [
      (-10.0, "just now"), (0, "just now"), (4, "just now"), (5, "5s ago"), (8, "8s ago"),
      (59, "59s ago"), (60, "1m ago"), (360, "6m ago"), (3599, "59m ago"), (3600, "1h ago"),
      (7199, "1h ago"), (86_399, "23h ago"), (86_400, "1d ago"), (172_805, "2d ago"),
    ] as [(Double, String)])
  func formatsRelativeTimes(secondsAgo: Double, expected: String) {
    #expect(Formatting.relative(from: at(-secondsAgo), now: t0) == expected)
  }

  @Test(
    arguments: [
      (30.0, "<1m left"), (0, "Taking longer than expected"), (59, "<1m left"), (60, "1m left"),
      (61, "1m left"), (74, "1m left"), (75, "1m 30s left"), (91, "1m 30s left"),
      (104, "1m 30s left"), (105, "2m left"), (119, "2m left"), (180, "3m left"),
      (-30, "Taking longer than expected"), (-60, "Taking longer than expected"),
      (-120, "Taking longer than expected"), (-179, "Taking longer than expected"),
    ] as [(Double, String)])
  func formatsRemainingTime(secondsLeft: Double, expected: String) {
    #expect(Formatting.remaining(secondsLeft) == expected)
  }

  @Test func survivesNonFiniteAndHugeValues() {
    #expect(Formatting.duration(.nan) == "0s")
    #expect(Formatting.duration(.infinity) == "0s")
    #expect(Formatting.duration(-.infinity) == "0s")
    #expect(Formatting.duration(1e30) == Formatting.duration(1e12))
    #expect(Formatting.relative(from: Date(timeIntervalSince1970: .nan), now: t0) == "just now")
    #expect(!Formatting.relative(from: Date(timeIntervalSince1970: -1e30), now: t0).isEmpty)
    #expect(Formatting.remaining(.nan) == "Taking longer than expected")
    #expect(!Formatting.remaining(.infinity).isEmpty)
    #expect(!Formatting.remaining(-.infinity).isEmpty)
  }

  @Test func stripsTheBotSuffixOnly() {
    #expect(Formatting.login("dependabot[bot]") == "dependabot")
    #expect(Formatting.login("octocat") == "octocat")
    #expect(Formatting.login("a[bot]b") == "a[bot]b")
  }

  @Test func neverProducesEmDashesOrMiddleDots() {
    let banned: [Character] = ["\u{2014}", "\u{00B7}"]
    for seconds in stride(from: -400_000.0, through: 400_000.0, by: 997) {
      let outputs = [
        Formatting.duration(seconds),
        Formatting.relative(from: at(seconds), now: t0),
        Formatting.remaining(seconds),
      ]
      for output in outputs {
        #expect(!output.contains(where: banned.contains), "\(output)")
      }
    }
  }
}
