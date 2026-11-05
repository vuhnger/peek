import Foundation

public enum Formatting {
  private static let secondsLimit = 1e12

  private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
    seconds.isFinite ? Int(min(max(seconds, -secondsLimit), secondsLimit)) : 0
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, wholeSeconds(seconds))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \(total % 3600 / 60)m"
  }

  public static func relative(from date: Date, now: Date) -> String {
    let seconds = wholeSeconds(now.timeIntervalSince(date))
    switch seconds {
    case ..<5: return "just now"
    case ..<60: return "\(seconds)s ago"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86400)d ago"
    }
  }

  public static func remaining(_ secondsLeft: TimeInterval) -> String {
    guard secondsLeft.isFinite, secondsLeft > 0 else { return "Taking longer than expected" }
    if secondsLeft < 60 { return "<1m left" }
    let seconds = wholeSeconds((secondsLeft / 30).rounded() * 30)
    let minutes = seconds / 60
    return seconds % 60 == 0 ? "\(minutes)m left" : "\(minutes)m 30s left"
  }

  public static func login(_ login: String) -> String {
    login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login
  }
}
