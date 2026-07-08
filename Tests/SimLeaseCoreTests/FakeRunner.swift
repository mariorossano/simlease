import Foundation
@testable import SimLeaseCore

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-runner")
    private var _responses: [String: ProcessResult] = [:]
    private var _calls: [[String]] = []

    var responses: [String: ProcessResult] {
        get { queue.sync { _responses } }
        set { queue.sync { _responses = newValue } }
    }

    var calls: [[String]] { queue.sync { _calls } }

    func setResponse(_ prefix: String, _ result: ProcessResult) {
        queue.sync { _responses[prefix] = result }
    }

    func run(_ arguments: [String]) throws -> ProcessResult {
        queue.sync { _calls.append(arguments) }
        let key = arguments.joined(separator: " ")
        let snapshot = queue.sync { _responses }
        for (prefix, result) in snapshot where key.hasPrefix(prefix) {
            return result
        }
        return ProcessResult(status: 0, stdout: "", stderr: "")
    }
}
