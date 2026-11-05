import Foundation
import Synchronization

@testable import PeekCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func at(_ offset: TimeInterval) -> Date {
  t0.addingTimeInterval(offset)
}

func makeRun(
  id: Int,
  workflow: Int = 1,
  branch: String? = "main",
  status: String = "completed",
  conclusion: String? = "success",
  event: String = "push",
  created: TimeInterval = 0,
  started: TimeInterval? = nil,
  updated: TimeInterval? = nil,
  actor: String = "me",
  triggering: String? = nil,
  headRepo: Int = 1,
  attempt: Int = 1,
  pull: Int? = nil,
  sha: String? = nil,
  mergeRequest: Bool = false,
  jobs: [WorkflowJob]? = nil
) -> WorkflowRun {
  var json: [String: Any] = [
    "id": id,
    "workflow_id": workflow,
    "status": status,
    "event": event,
    "created_at": at(created).ISO8601Format(),
    "run_attempt": attempt,
    "actor": ["login": actor, "id": 1],
    "triggering_actor": ["login": triggering ?? actor, "id": 1],
    "head_repository": ["id": headRepo, "full_name": "owner\(headRepo)/repo"],
  ]
  json["head_branch"] = branch
  if let pull { json["pull_requests"] = [["number": pull]] }
  json["head_sha"] = sha
  if mergeRequest { json["is_merge_request"] = true }
  json["conclusion"] = conclusion
  json["run_started_at"] = started.map { at($0).ISO8601Format() }
  json["updated_at"] = updated.map { at($0).ISO8601Format() }
  let data = try! JSONSerialization.data(withJSONObject: json)
  var run = try! JSONDecoder.github.decode(WorkflowRun.self, from: data)
  run.jobs = jobs
  return run
}

func successfulRun(
  id: Int, workflow: Int = 1, event: String = "push", created: TimeInterval, duration: TimeInterval
) -> WorkflowRun {
  makeRun(
    id: id, workflow: workflow, event: event, created: created, started: created,
    updated: created + duration, jobs: [WorkflowJob(name: "ci", conclusion: "success")])
}

enum Fixture {
  static func data(_ name: String) -> Data {
    let url = Bundle.module.url(
      forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
  }
}

struct StubReply: Sendable {
  var status: Int = 200
  var headers: [String: String] = [:]
  var body = Data()
  var error: URLError?
}

final class StubProtocol: URLProtocol {
  static let handler = Mutex<(@Sendable (URLRequest) -> StubReply)?>(nil)
  static let seen = Mutex<[URLRequest]>([])

  static func install(_ handler: @escaping @Sendable (URLRequest) -> StubReply) {
    Self.handler.withLock { $0 = handler }
    seen.withLock { $0 = [] }
  }

  static var requests: [URLRequest] { seen.withLock { $0 } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.seen.withLock { $0.append(request) }
    guard let reply = Self.handler.withLock({ $0 })?(request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    if let error = reply.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
      headerFields: reply.headers)!
    if (300..<400).contains(reply.status), let location = reply.headers["Location"] {
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
