import CryptoKit
import Foundation
import Testing
import ZeroByte

@testable import ZeroByteTimeline

/// The relay in memory, with an optional envelope limit per direction.
actor TimelineMemoryRelay: RelayTransport {
    private var stored: [Direction: [UInt64: Data]] = [:]
    private var last: [Direction: UInt64] = [:]
    private let capacity: Int?
    private(set) var notified: [Notify] = []

    init(capacity: Int? = nil) { self.capacity = capacity }

    func claim() async throws {}

    func put(_ envelope: Data, direction: Direction, sequence: UInt64) async throws {
        try await put(envelope, direction: direction, sequence: sequence, notify: .none)
    }

    func put(_ envelope: Data, direction: Direction, sequence: UInt64, notify: Notify) async throws {
        if let previous = last[direction], sequence <= previous {
            throw RelayError.sequenceConflict(last: previous)
        }
        if let capacity, (stored[direction]?.count ?? 0) >= capacity {
            throw RelayError.quotaExceeded
        }
        stored[direction, default: [:]][sequence] = envelope
        last[direction] = sequence
        if notify != .none { notified.append(notify) }
    }

    func fetch(direction: Direction, after sequence: UInt64?) async throws -> (
        envelopes: [Data], more: Bool
    ) {
        let keys = (stored[direction] ?? [:]).keys.filter { $0 > (sequence ?? 0) }.sorted()
        let page = keys.prefix(16)
        return (page.map { stored[direction]![$0]! }, keys.count > page.count)
    }

    func lastSequence(direction: Direction) async throws -> UInt64? { last[direction] }

    func prune(direction: Direction, through sequence: UInt64) async throws {
        stored[direction] = stored[direction]?.filter { $0.key > sequence }
    }

    func erase() async throws {
        stored = [:]
        last = [:]
    }

    func count(_ direction: Direction) -> Int { stored[direction]?.count ?? 0 }
}

/// One device: its timeline, saved after every step as an app would.
@MainActor
final class Device {
    var timeline: Timeline
    var saved: Data
    let sends: Direction
    let credentials: Credentials
    let relay: TimelineMemoryRelay
    /// What an app that does not keep its own values would produce again.
    var source: [TimelineSlot: Data] = [:]

    init(sends: Direction, credentials: Credentials, relay: TimelineMemoryRelay, keepsOwn: Bool) {
        timeline = Timeline(keepsOwnValues: keepsOwn)
        saved = timeline.encoded()
        self.sends = sends
        self.credentials = credentials
        self.relay = relay
    }

    @discardableResult
    func sync(budget: Int? = nil, at seconds: TimeInterval = 1_762_855_200) async throws
        -> TimelineSyncOutcome
    {
        let source = self.source
        var timeline = self.timeline
        defer { self.timeline = timeline }
        return try await TimelineRelay.sync(
            &timeline, credentials: credentials, transport: relay, sends: sends,
            now: Date(timeIntervalSince1970: seconds), commitBudget: budget,
            notify: .silent, values: { source[$0] }
        ) { self.saved = $0.encoded() }
    }

    func set(_ text: String, _ collection: String, _ key: String) throws {
        let slot = TimelineSlot(collection, key)
        source[slot] = Data(text.utf8)
        try timeline.set(Data(text.utf8), at: slot)
    }

    func text(_ collection: String, _ key: String) -> String? {
        timeline.value(TimelineSlot(collection, key)).map { String(decoding: $0, as: UTF8.self) }
    }
}

@MainActor
struct TimelineRelayTests {
    static func pair(capacity: Int? = nil) throws -> (Device, Device, TimelineMemoryRelay) {
        let credentials = try Credentials(
            linkKey: Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }), linkID: UUID())
        let relay = TimelineMemoryRelay(capacity: capacity)
        let phone = Device(
            sends: .primaryToCompanion, credentials: credentials, relay: relay, keepsOwn: false)
        let mac = Device(
            sends: .companionToPrimary, credentials: credentials, relay: relay, keepsOwn: true)
        return (phone, mac, relay)
    }

    @Test func changesTravelBothWays() async throws {
        let (phone, mac, _) = try Self.pair()
        try phone.set("hrv 45", "day", "20261110")
        try phone.set("hrv 47", "day", "20261111")
        try await phone.sync()
        let received = try await mac.sync()
        #expect(mac.text("day", "20261110") == "hrv 45")
        #expect(received.updates.count == 2)

        try mac.set("tempo", "plan", "p-1")
        try await mac.sync()
        let back = try await phone.sync()
        #expect(back.updates.map(\.slot) == [TimelineSlot("plan", "p-1")])
        #expect(phone.text("plan", "p-1") == "tempo")
        // The phone keeps foreign values, not its own.
        #expect(phone.timeline.value(TimelineSlot("day", "20261110")) == nil)
        #expect(phone.timeline.entry(TimelineSlot("day", "20261110"))?.digest != nil)
    }

    @Test func quietOnceBothAreCurrent() async throws {
        let (phone, mac, _) = try Self.pair()
        try phone.set("hrv 45", "day", "1")
        try mac.set("tempo", "plan", "p")
        for _ in 0..<3 {
            try await phone.sync()
            try await mac.sync()
        }
        let phoneRun = try await phone.sync()
        let macRun = try await mac.sync()
        #expect(phoneRun.written == 0 && macRun.written == 0)
        #expect(phoneRun.isPeerCurrent && macRun.isPeerCurrent)
        #expect(mac.text("day", "1") == "hrv 45" && phone.text("plan", "p") == "tempo")
    }

    @Test func onlyChangesTravel() async throws {
        let (phone, mac, _) = try Self.pair()
        for day in 1...30 { try phone.set("day \(day)", "day", String(day)) }
        try await phone.sync()
        try await mac.sync()
        // Everything set again, one value different: one change is pending.
        for day in 1...30 { try phone.set(day == 7 ? "day 7 edited" : "day \(day)", "day", String(day)) }
        #expect(phone.timeline.pendingCount == 1)
        try await phone.sync(at: 1_762_855_300)
        let outcome = try await mac.sync()
        #expect(outcome.updates.map(\.slot.key) == ["7"])
        #expect(mac.text("day", "7") == "day 7 edited")
    }

    @Test func concurrentEditsConverge() async throws {
        let (phone, mac, _) = try Self.pair()
        try phone.set("easy", "plan", "p-1")
        try await phone.sync(at: 1_762_855_200)
        try await mac.sync(at: 1_762_855_201)
        // Both edit without seeing the other; the later clock wins on both.
        try phone.set("tempo", "plan", "p-1")
        try mac.set("intervals", "plan", "p-1")
        try await phone.sync(at: 1_762_855_210)
        try await mac.sync(at: 1_762_855_220)
        try await phone.sync(at: 1_762_855_230)
        #expect(mac.text("plan", "p-1") == "intervals")
        #expect(phone.text("plan", "p-1") == "intervals")
        // A change made after seeing another always wins, whatever the clock says.
        try phone.set("long run", "plan", "p-1")
        try await phone.sync(at: 1_762_855_000)
        try await mac.sync(at: 1_762_855_240)
        #expect(mac.text("plan", "p-1") == "long run")
    }

    @Test func deletionsWin() async throws {
        let (phone, mac, _) = try Self.pair()
        try phone.set("ride", "workout", "w-1")
        try await phone.sync()
        try await mac.sync()
        try phone.timeline.delete(TimelineSlot("workout", "w-1"))
        phone.source[TimelineSlot("workout", "w-1")] = nil
        try await phone.sync(at: 1_762_855_300)
        let outcome = try await mac.sync()
        #expect(outcome.updates.first?.value == nil)
        #expect(mac.timeline.entry(TimelineSlot("workout", "w-1"))?.isDeleted == true)
    }

    @Test func aReplicaThatLostItsStateCatchesUp() async throws {
        let (phone, mac, relay) = try Self.pair()
        for day in 1...5 { try phone.set("day \(day)", "day", String(day)) }
        try mac.set("tempo", "plan", "p-1")
        try await phone.sync()
        try await mac.sync()
        try await phone.sync()
        try await mac.sync()
        #expect(phone.timeline.relay.confirmed >= 1)

        // The Mac starts again from nothing, under a new replica id.
        let fresh = Device(
            sends: .companionToPrimary, credentials: mac.credentials, relay: relay, keepsOwn: true)
        fresh.timeline.relay.readThrough = mac.timeline.relay.readThrough
        try await fresh.sync()
        try await phone.sync()
        try await fresh.sync()
        for day in 1...5 { #expect(fresh.text("day", String(day)) == "day \(day)") }
        // Its own plan comes back from the phone, under the old Mac's stamp.
        #expect(fresh.text("plan", "p-1") == "tempo")
    }

    @Test func aFullMailboxWaitsForTheReader() async throws {
        let (phone, mac, relay) = try Self.pair(capacity: 2)
        let value = String(repeating: "x", count: 300_000)
        for index in 0..<12 { try phone.set(value + String(index), "stream", String(index)) }
        let first = try await phone.sync()
        #expect(first.waiting > 0)
        #expect(await relay.count(.primaryToCompanion) == 2)
        var rounds = 0
        while rounds < 20 {
            try await mac.sync()
            let outcome = try await phone.sync()
            rounds += 1
            if outcome.waiting == 0 && phone.timeline.pendingCount == 0 { break }
        }
        try await mac.sync()
        for index in 0..<12 { #expect(mac.text("stream", String(index)) == value + String(index)) }
    }

    @Test func aBudgetLeavesTheRestPending() async throws {
        let (phone, mac, _) = try Self.pair()
        let value = String(repeating: "y", count: 200_000)
        for index in 0..<10 { try phone.set(value + String(index), "stream", String(index)) }
        try await phone.sync(budget: 500_000)
        #expect(phone.timeline.pendingCount > 0)
        try await phone.sync(budget: nil)
        try await mac.sync()
        #expect(mac.timeline.entries(in: "stream").count == 10)
    }

    @Test func savedStateReadsBack() async throws {
        let (phone, mac, _) = try Self.pair(capacity: 1)
        try phone.set("a", "day", "1")
        try phone.set("b", "day", "2")
        try phone.timeline.set(Data("c".utf8), at: TimelineSlot("day", "3"))
        try await phone.sync()
        try mac.set("plan", "plan", "p")
        try await mac.sync()
        for device in [phone, mac] {
            let restored = try Timeline(encoded: device.saved)
            #expect(restored.encoded() == device.saved)
            #expect(restored.heads == device.timeline.heads)
            #expect(restored.relay == device.timeline.relay)
        }
    }

    @Test func aLongCatchUpSpansRuns() async throws {
        let (phone, mac, relay) = try Self.pair(capacity: 3)
        let value = String(repeating: "z", count: 250_000)
        for index in 0..<10 { try phone.set(value + String(index), "stream", String(index)) }
        for _ in 0..<12 {
            try await phone.sync()
            try await mac.sync()
        }
        #expect(mac.timeline.entries(in: "stream").count == 10)

        let fresh = Device(
            sends: .companionToPrimary, credentials: mac.credentials, relay: relay, keepsOwn: true)
        fresh.timeline.relay.readThrough = mac.timeline.relay.readThrough
        try await fresh.sync()
        var runs = 0
        while runs < 12 {
            let outcome = try await phone.sync(budget: 600_000)
            try await fresh.sync()
            runs += 1
            if outcome.waiting == 0, phone.timeline.relay.catchUp == nil { break }
        }
        #expect(runs > 1)
        try await fresh.sync()
        for index in 0..<10 { #expect(fresh.text("stream", String(index)) == value + String(index)) }
        #expect(fresh.timeline.heads[phone.timeline.replica] == phone.timeline.heads[phone.timeline.replica])
    }

    @Test func aDirectExchangeNeedsNoRelay() throws {
        var phone = Timeline(keepsOwnValues: true)
        var mac = Timeline()
        try phone.set(Data("hrv".utf8), at: TimelineSlot("day", "1"))
        try mac.set(Data("tempo".utf8), at: TimelineSlot("plan", "p"))
        let now = Date(timeIntervalSince1970: 1_762_855_200)
        _ = phone.commit(now: now)
        _ = mac.commit(now: now)
        let phoneHeads = phone.heads
        let macHeads = mac.heads
        for part in phone.catchUp(after: macHeads) { _ = try mac.receive(part) }
        for part in mac.catchUp(after: phoneHeads) { _ = try phone.receive(part) }
        #expect(mac.value(TimelineSlot("day", "1")) == Data("hrv".utf8))
        #expect(phone.value(TimelineSlot("plan", "p")) == Data("tempo".utf8))
        #expect(phone.heads == mac.heads)
    }
}
