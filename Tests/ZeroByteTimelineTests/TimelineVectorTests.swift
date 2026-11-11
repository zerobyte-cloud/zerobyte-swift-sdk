import Foundation
import Testing

@testable import ZeroByteTimeline

// Known answers from the independent reference (zerobyte-protocol,
// spec/timeline.py), copied as timeline.json. Never regenerate them here.

struct TimelineVectors: Decodable {
    struct ClockCase: Decodable {
        let last: String
        let now_ms: UInt64
        let next: String
    }
    struct Seen: Decodable {
        let replica: String
        let sequence: UInt64
    }
    struct Change: Decodable {
        let collection, key: String
        let value: String?
    }
    struct Commit: Decodable {
        let name, replica, parent, clock, hex, id: String
        let sequence: UInt64
        let seen: [Seen]
        let entries: [Change]
    }
    struct Message: Decodable {
        let name, hex: String
    }
    struct Stamped: Decodable {
        let collection, key, clock, replica: String
        let sequence: UInt64
        let value: String?
    }
    struct Head: Decodable {
        let replica, clock, id: String
        let sequence: UInt64
    }
    struct Merge: Decodable {
        let orders: [[String]]
        let state: [Stamped]
        let heads: [Head]
        let last: String
    }
    struct Outcome: Decodable {
        let order: [String]
        let outcome: String
    }
    struct CatchUp: Decodable {
        let requester_heads: [Seen]
        let entries: [Stamped]
        let hex: String
    }
    struct Rejection: Decodable {
        let name, kind, hex, error: String
    }
    struct Diverged: Decodable {
        let name: String
        let commits: [String]
    }
    let message_limit: Int
    let clock: [ClockCase]
    let commits: [Commit]
    let messages: [Message]
    let merge: Merge
    let gap: Outcome
    let skip: Outcome
    let catch_up: CatchUp
    let rejections: [Rejection]
    let diverged: [Diverged]

    static func load() throws -> TimelineVectors {
        let url = try #require(Bundle.module.url(forResource: "timeline", withExtension: "json"))
        return try JSONDecoder().decode(TimelineVectors.self, from: Data(contentsOf: url))
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func replica(_ hex: String) -> ReplicaID { ReplicaID(bytes: Data(hex: hex))! }

struct TimelineVectorTests {
    let vectors: TimelineVectors
    let commits: [String: TimelineCommit]

    init() throws {
        vectors = try TimelineVectors.load()
        var commits: [String: TimelineCommit] = [:]
        for item in vectors.commits {
            commits[item.name] = try TimelineCommit(decoding: Data(hex: item.hex))
        }
        self.commits = commits
    }

    @Test func limits() {
        #expect(vectors.message_limit == TimelineLimits.maximumMessageBytes)
    }

    @Test func clock() {
        for item in vectors.clock {
            let now = Date(timeIntervalSince1970: TimeInterval(item.now_ms) / 1000)
            #expect(TimelineClock.next(after: UInt64(item.last)!, nowMilliseconds: item.now_ms)
                == UInt64(item.next)!)
            #expect(TimelineClock.next(after: UInt64(item.last)!, now: now) == UInt64(item.next)!)
        }
    }

    @Test func commitsEncodeAndDecode() throws {
        for item in vectors.commits {
            var seen: [ReplicaID: UInt64] = [:]
            for other in item.seen { seen[replica(other.replica)] = other.sequence }
            let built = TimelineCommit(
                replica: replica(item.replica), sequence: item.sequence,
                parent: Data(hex: item.parent), clock: UInt64(item.clock)!, seen: seen,
                changes: item.entries.map {
                    TimelineChange(
                        slot: TimelineSlot($0.collection, $0.key), value: $0.value.map(Data.init(hex:)))
                })
            #expect(built.bytes.hex == item.hex, "\(item.name)")
            #expect(built.id.hex == item.id, "\(item.name)")
            let decoded = try #require(commits[item.name])
            #expect(decoded == built)
        }
    }

    @Test func messagesRoundTrip() throws {
        for item in vectors.messages {
            let message = try TimelineMessage(decoding: Data(hex: item.hex))
            #expect(message.encoded().hex == item.hex, "\(item.name)")
        }
    }

    @Test func everyOrderReachesTheSameState() throws {
        for order in vectors.merge.orders {
            var timeline = Timeline()
            for name in order {
                let receipt = try timeline.receive(.commits([try #require(commits[name])]))
                #expect(receipt.merged == 1)
            }
            let state = vectors.merge.state.map { item in
                (item.collection, item.key, item.clock, item.replica, item.sequence, item.value)
            }
            var found: [(String, String, String, String, UInt64, String?)] = []
            for collection in Set(vectors.merge.state.map(\.collection)).sorted() {
                for entry in timeline.entries(in: collection) {
                    found.append(
                        (entry.slot.collection, entry.slot.key, String(entry.stamp.clock),
                         entry.stamp.replica.hex, entry.stamp.sequence, entry.value?.hex))
                }
            }
            #expect(found.count == state.count)
            for (a, b) in zip(found, state) {
                #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 && a.4 == b.4 && a.5 == b.5)
            }
            for head in vectors.merge.heads {
                let mine = try #require(timeline.heads[replica(head.replica)])
                #expect(mine.sequence == head.sequence)
                #expect(String(mine.clock) == head.clock)
                #expect(mine.id.hex == head.id)
            }
            #expect(String(timeline.last) == vectors.merge.last)
        }
    }

    @Test func gapAndRepeat() throws {
        var gap = Timeline()
        let receipt = try gap.receive(.commits([try #require(commits[vectors.gap.order[0]])]))
        #expect(receipt.foundGap && receipt.merged == 0 && gap.entryCount == 0)

        var again = Timeline()
        let first = try #require(commits[vectors.skip.order[0]])
        _ = try again.receive(.commits([first]))
        let repeated = try again.receive(.commits([first]))
        #expect(repeated.merged == 0 && !repeated.foundGap)
    }

    @Test func catchUpSelection() throws {
        var timeline = Timeline()
        for name in vectors.merge.orders[0] {
            _ = try timeline.receive(.commits([try #require(commits[name])]))
        }
        var heads: [ReplicaID: TimelineHead] = [:]
        for head in vectors.catch_up.requester_heads {
            heads[replica(head.replica)] = TimelineHead(sequence: head.sequence, clock: 0, id: Data(count: 32))
        }
        let parts = timeline.catchUp(after: heads)
        #expect(parts.count == 1)
        #expect(parts[0].encoded().hex == vectors.catch_up.hex)
    }

    @Test func rejections() {
        for item in vectors.rejections {
            let expected: TimelineError
            switch item.error {
            case "malformed": expected = .malformed
            case "unsupported_version": expected = .unsupportedVersion
            case "too_large": expected = .tooLarge
            default: expected = .diverged
            }
            #expect(throws: expected, "\(item.name)") {
                if item.kind == "commit" {
                    _ = try TimelineCommit(decoding: Data(hex: item.hex))
                } else {
                    _ = try TimelineMessage(decoding: Data(hex: item.hex))
                }
            }
        }
    }

    @Test func diverged() {
        for item in vectors.diverged {
            #expect(throws: TimelineError.diverged, "\(item.name)") {
                var timeline = Timeline()
                for hex in item.commits {
                    _ = try timeline.receive(.commits([try TimelineCommit(decoding: Data(hex: hex))]))
                }
            }
        }
    }

    @Test func tooLarge() throws {
        var timeline = Timeline()
        let big = Data(count: TimelineLimits.maximumMessageBytes)
        #expect(throws: TimelineError.tooLarge) {
            try timeline.set(big, at: TimelineSlot("stream", "w"))
        }
        #expect(throws: TimelineError.tooLarge) {
            _ = try TimelineMessage(decoding: Data(count: TimelineLimits.maximumMessageBytes + 1))
        }
    }
}
