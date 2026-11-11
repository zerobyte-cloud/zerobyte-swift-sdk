//
//  Timeline.swift
//  ZeroByte — Timeline v1
//
//  One replica of a link's keyed state (timeline-v1.md §1–§5). Local changes
//  wait as pending until `commit`; commits and catch-ups from the other side
//  merge by stamp, so both replicas converge whatever order things arrive in.
//  `relay` is the bookkeeping `TimelineRelay` keeps between runs; it is saved
//  with the rest by `encoded()`.
//

import CryptoKit
import Foundation

/// One key's current entry.
public struct TimelineEntry: Hashable, Sendable {
    public let slot: TimelineSlot
    public let stamp: TimelineStamp
    /// The value; nil for a deletion, and for an own entry of a replica that
    /// does not keep its own values.
    public let value: Data?
    public let isDeleted: Bool
    /// SHA-256 of the value; nil for a deletion.
    public let digest: Data?
}

/// A key whose entry a merge replaced.
public struct TimelineUpdate: Hashable, Sendable {
    public let slot: TimelineSlot
    /// The new value, or nil when the key was deleted.
    public let value: Data?
    public let stamp: TimelineStamp
}

/// What one received message did.
public struct TimelineReceipt: Sendable {
    public var updates: [TimelineUpdate] = []
    /// Commits merged.
    public var merged = 0
    /// A commit arrived after one that never did; ask for a catch-up.
    public var foundGap = false
    /// The other side's state, when the message was one.
    public var peerState: (request: TimelineRequest, heads: [ReplicaID: TimelineHead])?
    /// The highest of this replica's own sequences the other side said it has.
    public var confirmed: UInt64?
}

/// A message written or waiting to be written to the relay.
public struct TimelineOutboxItem: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        case commits = 1
        case state = 2
        case catchUp = 3
    }

    public let kind: Kind
    public let message: Data
    /// For a message of commits: the last own sequence it carries.
    public let ownThrough: UInt64?

    public init(kind: Kind, message: Data, ownThrough: UInt64? = nil) {
        self.kind = kind
        self.message = message
        self.ownThrough = ownThrough
    }
}

/// Where a catch-up written a few parts at a time has got to.
public struct TimelineCatchUpCursor: Hashable, Sendable {
    public let requesterHeads: [ReplicaID: TimelineHead]
    public let includingOwn: Bool
    public let finalHeads: [ReplicaID: TimelineHead]
    /// The last key considered.
    public var after: TimelineSlot?
}

/// What `TimelineRelay` remembers between runs.
public struct TimelineRelayCursor: Hashable, Sendable {
    /// The last envelope read from the other direction.
    public var readThrough: UInt64?
    public var nextWrite: UInt64?
    /// Messages not yet on the relay, oldest first.
    public var outbox: [TimelineOutboxItem] = []
    /// The other side's heads, as it last reported them.
    public var peerHeads: [ReplicaID: TimelineHead]?
    /// The highest own sequence the other side confirmed.
    public var confirmed: UInt64 = 0
    /// A catch-up the other side asked for and this side has not answered.
    public var peerRequest: TimelineRequest = []
    public var peerRequestHeads: [ReplicaID: TimelineHead] = [:]
    /// A catch-up this side still has to ask for.
    public var ownRequest: TimelineRequest = .newReplica
    /// A catch-up being written, when it did not fit one run.
    public var catchUp: TimelineCatchUpCursor?

    public init() {}
}

public struct Timeline: Sendable {
    public private(set) var replica: ReplicaID
    public private(set) var heads: [ReplicaID: TimelineHead] = [:]
    /// The greatest clock written or merged.
    public private(set) var last: UInt64 = 0
    /// Collections whose own values this replica keeps only as digests: for
    /// an app that can produce them again (`TimelineRelay.sync(values:)`), so
    /// the state does not hold a second copy of its database.
    public let forgetsOwnValues: Set<String>
    public let maximumMessageBytes: Int
    public var relay = TimelineRelayCursor()

    private var entries: [TimelineSlot: Stored] = [:]
    private var pending: [TimelineSlot: Pending] = [:]

    struct Stored: Hashable, Sendable {
        var stamp: TimelineStamp
        var digest: Data?
        var value: Data?
    }

    enum Pending: Hashable, Sendable {
        case value(Data)
        case deletion
    }

    public init(
        replica: ReplicaID = .random(), forgetsOwnValues: Set<String> = [],
        maximumMessageBytes: Int = TimelineLimits.maximumMessageBytes
    ) {
        self.replica = replica
        self.forgetsOwnValues = forgetsOwnValues
        self.maximumMessageBytes = min(maximumMessageBytes, TimelineLimits.maximumMessageBytes)
    }

    var maximumCommitBytes: Int { maximumMessageBytes - TimelineLimits.commitsMessageOverhead }

    // MARK: Reading

    public func entry(_ slot: TimelineSlot) -> TimelineEntry? {
        entries[slot].map { entry(slot, $0) }
    }

    /// The current value at a key; nil when absent, deleted or not kept.
    public func value(_ slot: TimelineSlot) -> Data? {
        entries[slot]?.value
    }

    public func entries(in collection: String) -> [TimelineEntry] {
        let bytes = Array(collection.utf8)
        return entries.filter { $0.key.collectionBytes == bytes }
            .sorted { $0.key < $1.key }
            .map { entry($0.key, $0.value) }
    }

    public var entryCount: Int { entries.count }

    private func entry(_ slot: TimelineSlot, _ stored: Stored) -> TimelineEntry {
        TimelineEntry(
            slot: slot, stamp: stored.stamp, value: stored.value, isDeleted: stored.digest == nil,
            digest: stored.digest)
    }

    // MARK: Local changes

    /// Stages a value. Returns false when the key already holds exactly it.
    @discardableResult
    public mutating func set(_ value: Data, at slot: TimelineSlot) throws -> Bool {
        guard slot.isValid else { throw TimelineError.malformed }
        let change = TimelineChange(slot: slot, value: value)
        guard TimelineLimits.commitFixedBytes + change.encodedLength <= maximumCommitBytes else {
            throw TimelineError.tooLarge
        }
        let digest = Data(SHA256.hash(data: value))
        if let stored = entries[slot], stored.digest == digest {
            pending[slot] = nil
            return false
        }
        if pending[slot] == .value(value) { return false }
        pending[slot] = .value(value)
        return true
    }

    /// Stages a deletion. Returns false when the key holds nothing.
    @discardableResult
    public mutating func delete(_ slot: TimelineSlot) throws -> Bool {
        guard slot.isValid else { throw TimelineError.malformed }
        guard let stored = entries[slot], stored.digest != nil else {
            pending[slot] = nil
            return false
        }
        pending[slot] = .deletion
        return true
    }

    public var hasPendingChanges: Bool { !pending.isEmpty }
    public var pendingCount: Int { pending.count }

    /// Whether a change at this key waits to be committed.
    public func hasPendingChange(at slot: TimelineSlot) -> Bool { pending[slot] != nil }

    public var pendingBytes: Int {
        pending.reduce(0) { total, item in
            if case .value(let data) = item.value { return total + data.count }
            return total
        }
    }

    public mutating func discardPendingChanges() { pending.removeAll() }

    /// Turns pending changes into commits, each small enough for one message.
    ///
    /// - Parameter maximumBytes: Stop once the commits made reach this size;
    ///   the rest stay pending. At least one commit is made.
    public mutating func commit(now: Date, maximumBytes: Int? = nil) -> [TimelineCommit] {
        let slots = pending.keys.sorted()
        var commits: [TimelineCommit] = []
        var batch: [TimelineChange] = []
        var size = 0
        var total = 0
        let fixed = TimelineLimits.commitFixedBytes + (heads.count) * 24

        func flush() {
            guard !batch.isEmpty else { return }
            let commit = makeCommit(batch, now: now)
            commits.append(commit)
            total += commit.bytes.count
            batch = []
            size = 0
        }

        for slot in slots {
            if let maximumBytes, !commits.isEmpty, total >= maximumBytes { break }
            let change: TimelineChange
            switch pending[slot]! {
            case .value(let data): change = TimelineChange(slot: slot, value: data)
            case .deletion: change = TimelineChange(slot: slot, value: nil)
            }
            if !batch.isEmpty, fixed + size + change.encodedLength > maximumCommitBytes {
                flush()
                if let maximumBytes, total >= maximumBytes { break }
            }
            batch.append(change)
            size += change.encodedLength
            pending[slot] = nil
        }
        flush()
        return commits
    }

    private mutating func makeCommit(_ changes: [TimelineChange], now: Date) -> TimelineCommit {
        let own = heads[replica]
        var seen: [ReplicaID: UInt64] = [:]
        for (other, head) in heads where other != replica { seen[other] = head.sequence }
        let commit = TimelineCommit(
            replica: replica, sequence: (own?.sequence ?? 0) + 1,
            parent: own?.id ?? TimelineCommit.zeroParent,
            clock: TimelineClock.next(after: last, now: now), seen: seen, changes: changes)
        _ = apply(commit)
        return commit
    }

    // MARK: Merging

    public mutating func receive(_ data: Data) throws -> TimelineReceipt {
        try receive(TimelineMessage(decoding: data, maximumBytes: maximumMessageBytes))
    }

    public mutating func receive(_ message: TimelineMessage) throws -> TimelineReceipt {
        var receipt = TimelineReceipt()
        switch message {
        case .commits(let commits):
            for commit in commits {
                switch try merge(commit) {
                case .merged(let updates):
                    receipt.updates += updates
                    receipt.merged += 1
                    if let own = commit.seen[replica] {
                        receipt.confirmed = max(receipt.confirmed ?? 0, own)
                    }
                case .skipped:
                    break
                case .gap:
                    receipt.foundGap = true
                }
            }
        case .state(let request, let peerHeads):
            receipt.peerState = (request, peerHeads)
            if let own = peerHeads[replica] { receipt.confirmed = own.sequence }
        case .catchUp(let isFinal, let catchUpHeads, let stamped):
            for item in stamped {
                last = max(last, item.stamp.clock)
                if let update = place(item.slot, stamp: item.stamp, value: item.value) {
                    receipt.updates.append(update)
                }
            }
            if isFinal {
                for (other, head) in catchUpHeads where (heads[other]?.sequence ?? 0) < head.sequence {
                    heads[other] = head
                    last = max(last, head.clock)
                }
            }
        }
        return receipt
    }

    enum MergeOutcome {
        case merged([TimelineUpdate])
        case skipped
        case gap
    }

    mutating func merge(_ commit: TimelineCommit) throws -> MergeOutcome {
        let head = heads[commit.replica]
        if let head, commit.sequence <= head.sequence {
            if commit.sequence == head.sequence, commit.id != head.id {
                throw TimelineError.diverged
            }
            return .skipped
        }
        guard commit.sequence == (head?.sequence ?? 0) + 1 else { return .gap }
        if let head, commit.parent != head.id || commit.clock <= head.clock {
            throw TimelineError.diverged
        }
        return .merged(apply(commit))
    }

    private mutating func apply(_ commit: TimelineCommit) -> [TimelineUpdate] {
        var updates: [TimelineUpdate] = []
        let stamp = TimelineStamp(
            clock: commit.clock, replica: commit.replica, sequence: commit.sequence)
        for change in commit.changes {
            if let update = place(change.slot, stamp: stamp, value: change.value) {
                updates.append(update)
            }
        }
        heads[commit.replica] = TimelineHead(
            sequence: commit.sequence, clock: commit.clock, id: commit.id)
        last = max(last, commit.clock)
        return updates
    }

    private mutating func place(
        _ slot: TimelineSlot, stamp: TimelineStamp, value: Data?
    ) -> TimelineUpdate? {
        if let current = entries[slot], current.stamp >= stamp { return nil }
        let digest = value.map { Data(SHA256.hash(data: $0)) }
        let keeps = stamp.replica != replica || !forgetsOwnValues.contains(slot.collection)
        entries[slot] = Stored(stamp: stamp, digest: digest, value: keeps ? value : nil)
        if case .value(let staged)? = pending[slot], value == staged { pending[slot] = nil }
        return TimelineUpdate(slot: slot, value: value, stamp: stamp)
    }

    // MARK: Telling and catching up

    /// What this replica has merged, for the other side.
    public func state(request: TimelineRequest = []) -> TimelineMessage {
        .state(request: request, heads: heads)
    }

    /// Every entry after the requester's heads (timeline-v1.md §5), in parts
    /// that each fit a message; the last part is final and carries the heads.
    ///
    /// - Parameters:
    ///   - includingOwn: False leaves out this replica's own entries and head:
    ///     over the relay, when they are still on their way.
    ///   - values: Produces an own value this replica does not keep. A value
    ///     whose digest is not the entry's is left out; commit it again.
    public func catchUp(
        after requesterHeads: [ReplicaID: TimelineHead], includingOwn: Bool = true,
        values: (TimelineSlot) -> Data? = { _ in nil }
    ) -> [TimelineMessage] {
        var cursor = beginCatchUp(after: requesterHeads, includingOwn: includingOwn)
        return continueCatchUp(&cursor, maximumBytes: .max, values: values).parts
    }

    /// Starts a catch-up to be written a few parts at a time. Its final part
    /// carries the heads of now, so commits made while it is written are never
    /// taken as covered by it.
    public func beginCatchUp(
        after requesterHeads: [ReplicaID: TimelineHead], includingOwn: Bool = true
    ) -> TimelineCatchUpCursor {
        var finalHeads = heads
        if !includingOwn { finalHeads[replica] = nil }
        return TimelineCatchUpCursor(
            requesterHeads: requesterHeads, includingOwn: includingOwn, finalHeads: finalHeads)
    }

    /// The next parts of a catch-up, about `maximumBytes` of them; the call
    /// that reaches the end adds the final part and reports it finished.
    public func continueCatchUp(
        _ cursor: inout TimelineCatchUpCursor, maximumBytes: Int,
        values: (TimelineSlot) -> Data? = { _ in nil }
    ) -> (parts: [TimelineMessage], isFinished: Bool) {
        let partOverhead = 8
        var parts: [TimelineMessage] = []
        var batch: [TimelineStampedEntry] = []
        var size = partOverhead
        var produced = 0
        let slots = entries.keys.filter { slot in cursor.after.map { $0 < slot } ?? true }.sorted()
        for slot in slots {
            if produced >= maximumBytes {
                if !batch.isEmpty { parts.append(.catchUp(isFinal: false, heads: [:], entries: batch)) }
                return (parts, false)
            }
            cursor.after = slot
            let stored = entries[slot]!
            let origin = stored.stamp.replica
            if origin == replica, !cursor.includingOwn { continue }
            if let seen = cursor.requesterHeads[origin]?.sequence, stored.stamp.sequence <= seen {
                continue
            }
            var value: Data?
            if stored.digest != nil {
                guard let found = stored.value ?? values(slot),
                    Data(SHA256.hash(data: found)) == stored.digest
                else { continue }
                value = found
            }
            let item = TimelineStampedEntry(slot: slot, stamp: stored.stamp, value: value)
            if !batch.isEmpty, size + item.encodedLength > maximumMessageBytes {
                parts.append(.catchUp(isFinal: false, heads: [:], entries: batch))
                batch = []
                size = partOverhead
            }
            batch.append(item)
            size += item.encodedLength
            produced += item.encodedLength
        }
        if !batch.isEmpty, size + cursor.finalHeads.count * 64 > maximumMessageBytes {
            parts.append(.catchUp(isFinal: false, heads: [:], entries: batch))
            batch = []
        }
        parts.append(.catchUp(isFinal: true, heads: cursor.finalHeads, entries: batch))
        return (parts, true)
    }

    /// Records that the other side has this replica's commits through
    /// `sequence`, and drops queued commit messages it already holds.
    public mutating func noteConfirmed(_ sequence: UInt64) {
        relay.confirmed = max(relay.confirmed, sequence)
        let confirmed = relay.confirmed
        relay.outbox.removeAll { item in item.ownThrough.map { $0 <= confirmed } ?? false }
    }
}

// MARK: - At rest

extension Timeline {
    private static let magic = Data("ZBTL".utf8)

    /// Everything, for the app to save as one file. Not a wire format.
    public func encoded() -> Data {
        var writer = TimelineWriter()
        writer.bytes(Self.magic)
        writer.byte(1)
        writer.bytes(replica.bytes)
        writer.uint64(last)
        writer.byte(UInt8(forgetsOwnValues.count))
        for collection in forgetsOwnValues.sorted() {
            let bytes = Array(collection.utf8)
            writer.byte(UInt8(bytes.count))
            writer.data.append(contentsOf: bytes)
        }
        writer.uint32(UInt32(maximumMessageBytes))
        writer.heads(heads)
        writer.uint32(UInt32(entries.count))
        for slot in entries.keys.sorted() {
            let stored = entries[slot]!
            writer.slot(slot)
            writer.uint64(stored.stamp.clock)
            writer.bytes(stored.stamp.replica.bytes)
            writer.uint64(stored.stamp.sequence)
            switch (stored.digest, stored.value) {
            case (nil, _):
                writer.byte(0)
            case (let digest?, let value?):
                writer.byte(1)
                writer.bytes(digest)
                writer.uint32(UInt32(value.count))
                writer.bytes(value)
            case (let digest?, nil):
                writer.byte(2)
                writer.bytes(digest)
            }
        }
        writer.uint32(UInt32(pending.count))
        for slot in pending.keys.sorted() {
            writer.slot(slot)
            switch pending[slot]! {
            case .value(let data): writer.value(data)
            case .deletion: writer.value(nil)
            }
        }
        writer.uint64(relay.readThrough ?? 0)
        writer.uint64(relay.nextWrite ?? 0)
        writer.uint64(relay.confirmed)
        writer.uint32(UInt32(relay.outbox.count))
        for item in relay.outbox {
            writer.byte(item.kind.rawValue)
            writer.uint64(item.ownThrough ?? 0)
            writer.uint32(UInt32(item.message.count))
            writer.bytes(item.message)
        }
        writer.byte(relay.peerHeads == nil ? 0 : 1)
        writer.heads(relay.peerHeads ?? [:])
        writer.byte(relay.peerRequest.rawValue)
        writer.heads(relay.peerRequestHeads)
        writer.byte(relay.ownRequest.rawValue)
        if let cursor = relay.catchUp {
            writer.byte(cursor.includingOwn ? 3 : 1)
            writer.heads(cursor.requesterHeads)
            writer.heads(cursor.finalHeads)
            if let after = cursor.after {
                writer.byte(1)
                writer.slot(after)
            } else {
                writer.byte(0)
            }
        } else {
            writer.byte(0)
        }
        return writer.data
    }

    public init(encoded data: Data) throws {
        var reader = TimelineReader(data)
        guard try reader.take(4) == Self.magic, try reader.byte() == 1,
            let replica = ReplicaID(bytes: try reader.take(16))
        else { throw TimelineError.malformed }
        let last = try reader.uint64()
        var forgets: Set<String> = []
        for _ in 0..<(try reader.byte()) {
            guard let collection = String(bytes: try reader.take(Int(try reader.byte())), encoding: .utf8)
            else { throw TimelineError.malformed }
            forgets.insert(collection)
        }
        self.init(
            replica: replica, forgetsOwnValues: forgets,
            maximumMessageBytes: Int(try reader.uint32()))
        self.last = last
        heads = try reader.heads()
        for _ in 0..<(try reader.uint32()) {
            let slot = try reader.slot()
            let clock = try reader.uint64()
            guard let origin = ReplicaID(bytes: try reader.take(16)) else {
                throw TimelineError.malformed
            }
            let stamp = TimelineStamp(clock: clock, replica: origin, sequence: try reader.uint64())
            switch try reader.byte() {
            case 0:
                entries[slot] = Stored(stamp: stamp, digest: nil, value: nil)
            case 1:
                let digest = try reader.take(32)
                let value = try reader.take(Int(try reader.uint32()))
                entries[slot] = Stored(stamp: stamp, digest: digest, value: value)
            case 2:
                entries[slot] = Stored(stamp: stamp, digest: try reader.take(32), value: nil)
            default:
                throw TimelineError.malformed
            }
        }
        for _ in 0..<(try reader.uint32()) {
            let slot = try reader.slot()
            pending[slot] = try reader.value().map(Pending.value) ?? .deletion
        }
        let readThrough = try reader.uint64()
        let nextWrite = try reader.uint64()
        relay.readThrough = readThrough == 0 ? nil : readThrough
        relay.nextWrite = nextWrite == 0 ? nil : nextWrite
        relay.confirmed = try reader.uint64()
        for _ in 0..<(try reader.uint32()) {
            guard let kind = TimelineOutboxItem.Kind(rawValue: try reader.byte()) else {
                throw TimelineError.malformed
            }
            let through = try reader.uint64()
            let message = try reader.take(Int(try reader.uint32()))
            relay.outbox.append(
                TimelineOutboxItem(
                    kind: kind, message: message, ownThrough: through == 0 ? nil : through))
        }
        let hasPeerHeads = try reader.byte() == 1
        let peerHeads = try reader.heads()
        relay.peerHeads = hasPeerHeads ? peerHeads : nil
        relay.peerRequest = TimelineRequest(rawValue: try reader.byte())
        relay.peerRequestHeads = try reader.heads()
        relay.ownRequest = TimelineRequest(rawValue: try reader.byte())
        let catchUp = try reader.byte()
        if catchUp != 0 {
            let requesterHeads = try reader.heads()
            let finalHeads = try reader.heads()
            let after = try reader.byte() == 1 ? try reader.slot() : nil
            relay.catchUp = TimelineCatchUpCursor(
                requesterHeads: requesterHeads, includingOwn: catchUp == 3, finalHeads: finalHeads,
                after: after)
        }
        guard reader.isAtEnd else { throw TimelineError.malformed }
    }
}
