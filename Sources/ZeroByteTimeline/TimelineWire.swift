//
//  TimelineWire.swift
//  ZeroByte — Timeline v1
//
//  Commits and messages as bytes (timeline-v1.md §3, §5). Every list is
//  sorted and every field fixed-width or length-prefixed, so one change set
//  has exactly one encoding and every SDK computes the same commit id.
//

import CryptoKit
import Foundation

public enum TimelineError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case tooLarge
    /// A replica's history does not continue the one already merged.
    case diverged
}

public enum TimelineLimits {
    public static let maximumMessageBytes = 1_048_576
    public static let maximumCollectionBytes = 64
    public static let maximumKeyBytes = 1_024
    static let commitFixedBytes = 71
    static let commitsMessageOverhead = 7
}

/// A replica's name: 16 random bytes, drawn again after any loss of state.
public struct ReplicaID: Hashable, Comparable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = Data(bytes)
    }

    public static func random() -> ReplicaID {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            if let id = ReplicaID(bytes: bytes) { return id }
        }
    }

    public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Where an entry lives: the app's collection and key, compared as UTF-8 bytes.
public struct TimelineSlot: Hashable, Comparable, Sendable {
    public let collection: String
    public let key: String
    let collectionBytes: [UInt8]
    let keyBytes: [UInt8]

    public init(_ collection: String, _ key: String) {
        self.collection = collection
        self.key = key
        collectionBytes = Array(collection.utf8)
        keyBytes = Array(key.utf8)
    }

    init(collectionBytes: [UInt8], keyBytes: [UInt8]) throws {
        guard (1...TimelineLimits.maximumCollectionBytes).contains(collectionBytes.count),
            (1...TimelineLimits.maximumKeyBytes).contains(keyBytes.count),
            let collection = String(bytes: collectionBytes, encoding: .utf8),
            let key = String(bytes: keyBytes, encoding: .utf8)
        else { throw TimelineError.malformed }
        self.collection = collection
        self.key = key
        self.collectionBytes = collectionBytes
        self.keyBytes = keyBytes
    }

    var isValid: Bool {
        (1...TimelineLimits.maximumCollectionBytes).contains(collectionBytes.count)
            && (1...TimelineLimits.maximumKeyBytes).contains(keyBytes.count)
    }

    public static func == (lhs: TimelineSlot, rhs: TimelineSlot) -> Bool {
        lhs.collectionBytes == rhs.collectionBytes && lhs.keyBytes == rhs.keyBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(collectionBytes)
        hasher.combine(keyBytes)
    }

    public static func < (lhs: TimelineSlot, rhs: TimelineSlot) -> Bool {
        if lhs.collectionBytes != rhs.collectionBytes {
            return lhs.collectionBytes.lexicographicallyPrecedes(rhs.collectionBytes)
        }
        return lhs.keyBytes.lexicographicallyPrecedes(rhs.keyBytes)
    }

    var encodedLength: Int { 3 + collectionBytes.count + keyBytes.count }
}

/// The commit that wrote an entry. Ordered by clock, then replica id.
public struct TimelineStamp: Hashable, Comparable, Sendable {
    public let clock: UInt64
    public let replica: ReplicaID
    public let sequence: UInt64

    public init(clock: UInt64, replica: ReplicaID, sequence: UInt64) {
        self.clock = clock
        self.replica = replica
        self.sequence = sequence
    }

    public static func < (lhs: TimelineStamp, rhs: TimelineStamp) -> Bool {
        if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }
        if lhs.replica != rhs.replica { return lhs.replica < rhs.replica }
        return lhs.sequence < rhs.sequence
    }
}

/// The last commit merged from one replica.
public struct TimelineHead: Hashable, Sendable {
    public let sequence: UInt64
    public let clock: UInt64
    public let id: Data

    public init(sequence: UInt64, clock: UInt64, id: Data) {
        self.sequence = sequence
        self.clock = clock
        self.id = id
    }
}

/// One change in a commit: a value, or nil for a deletion.
public struct TimelineChange: Hashable, Sendable {
    public let slot: TimelineSlot
    public let value: Data?

    public init(slot: TimelineSlot, value: Data?) {
        self.slot = slot
        self.value = value
    }

    var encodedLength: Int { slot.encodedLength + 1 + (value.map { 4 + $0.count } ?? 0) }
}

public enum TimelineClock {
    /// `max(last + 1, now_ms << 16)` (timeline-v1.md §2).
    public static func next(after last: UInt64, nowMilliseconds: UInt64) -> UInt64 {
        let wall = nowMilliseconds >= UInt64(1) << 48 ? UInt64.max : nowMilliseconds << 16
        return max(last == .max ? .max : last + 1, wall)
    }

    public static func next(after last: UInt64, now: Date) -> UInt64 {
        let milliseconds = max(0, (now.timeIntervalSince1970 * 1000).rounded())
        return next(
            after: last,
            nowMilliseconds: milliseconds >= Double(UInt64(1) << 48)
                ? UInt64(1) << 48 : UInt64(milliseconds))
    }
}

public struct TimelineCommit: Hashable, Sendable {
    public let replica: ReplicaID
    public let sequence: UInt64
    public let parent: Data
    public let clock: UInt64
    /// The other replicas' sequences merged before this commit.
    public let seen: [ReplicaID: UInt64]
    public let changes: [TimelineChange]
    public let bytes: Data
    public let id: Data

    static let zeroParent = Data(count: 32)

    init(
        replica: ReplicaID, sequence: UInt64, parent: Data, clock: UInt64,
        seen: [ReplicaID: UInt64], changes: [TimelineChange]
    ) {
        var writer = TimelineWriter()
        writer.byte(1)
        writer.bytes(replica.bytes)
        writer.uint64(sequence)
        writer.bytes(parent)
        writer.uint64(clock)
        writer.uint16(UInt16(seen.count))
        for other in seen.keys.sorted() {
            writer.bytes(other.bytes)
            writer.uint64(seen[other]!)
        }
        let sorted = changes.sorted { $0.slot < $1.slot }
        writer.uint32(UInt32(sorted.count))
        for change in sorted { writer.change(change) }
        self.replica = replica
        self.sequence = sequence
        self.parent = parent
        self.clock = clock
        self.seen = seen
        self.changes = sorted
        bytes = writer.data
        id = Data(SHA256.hash(data: writer.data))
    }

    /// Reads and checks one commit (timeline-v1.md §3).
    public init(decoding data: Data, maximumBytes: Int = TimelineLimits.maximumMessageBytes) throws {
        guard data.count >= TimelineLimits.commitFixedBytes else { throw TimelineError.malformed }
        var reader = TimelineReader(data)
        guard try reader.byte() == 1 else { throw TimelineError.unsupportedVersion }
        guard let replica = ReplicaID(bytes: try reader.take(16)) else {
            throw TimelineError.malformed
        }
        let sequence = try reader.uint64()
        let parent = try reader.take(32)
        let clock = try reader.uint64()
        guard sequence > 0, (sequence == 1) == (parent == Self.zeroParent) else {
            throw TimelineError.malformed
        }
        var seen: [ReplicaID: UInt64] = [:]
        var previous: ReplicaID?
        for _ in 0..<(try reader.uint16()) {
            guard let other = ReplicaID(bytes: try reader.take(16)), other != replica else {
                throw TimelineError.malformed
            }
            let otherSequence = try reader.uint64()
            guard otherSequence > 0, previous.map({ $0 < other }) ?? true else {
                throw TimelineError.malformed
            }
            seen[other] = otherSequence
            previous = other
        }
        let count = try reader.uint32()
        guard count > 0 else { throw TimelineError.malformed }
        var changes: [TimelineChange] = []
        var previousSlot: TimelineSlot?
        for _ in 0..<count {
            let slot = try reader.slot()
            let value = try reader.value()
            guard previousSlot.map({ $0 < slot }) ?? true else { throw TimelineError.malformed }
            changes.append(TimelineChange(slot: slot, value: value))
            previousSlot = slot
        }
        guard reader.isAtEnd else { throw TimelineError.malformed }
        guard data.count <= maximumBytes - TimelineLimits.commitsMessageOverhead else {
            throw TimelineError.tooLarge
        }
        self.replica = replica
        self.sequence = sequence
        self.parent = parent
        self.clock = clock
        self.seen = seen
        self.changes = changes
        bytes = Data(data)
        id = Data(SHA256.hash(data: data))
    }
}

/// An entry with the stamp of the commit that wrote it, as a catch-up carries it.
public struct TimelineStampedEntry: Hashable, Sendable {
    public let slot: TimelineSlot
    public let stamp: TimelineStamp
    public let value: Data?

    public init(slot: TimelineSlot, stamp: TimelineStamp, value: Data?) {
        self.slot = slot
        self.stamp = stamp
        self.value = value
    }

    var encodedLength: Int { slot.encodedLength + 33 + (value.map { 4 + $0.count } ?? 0) }
}

/// Why a replica asks the other for a catch-up (timeline-v1.md §5).
public struct TimelineRequest: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// This replica is new or lost its state.
    public static let newReplica = TimelineRequest(rawValue: 1)
    /// A commit arrived after a sequence that never did.
    public static let gap = TimelineRequest(rawValue: 2)
}

public enum TimelineMessage: Hashable, Sendable {
    case commits([TimelineCommit])
    case state(request: TimelineRequest, heads: [ReplicaID: TimelineHead])
    case catchUp(isFinal: Bool, heads: [ReplicaID: TimelineHead], entries: [TimelineStampedEntry])

    public func encoded() -> Data {
        var writer = TimelineWriter()
        switch self {
        case .commits(let commits):
            writer.byte(1)
            writer.uint16(UInt16(commits.count))
            for commit in commits {
                writer.uint32(UInt32(commit.bytes.count))
                writer.bytes(commit.bytes)
            }
        case .state(let request, let heads):
            writer.byte(2)
            writer.byte(request.rawValue)
            writer.heads(heads)
        case .catchUp(let isFinal, let heads, let entries):
            writer.byte(3)
            writer.byte(isFinal ? 1 : 0)
            writer.heads(isFinal ? heads : [:])
            let sorted = entries.sorted { $0.slot < $1.slot }
            writer.uint32(UInt32(sorted.count))
            for entry in sorted {
                writer.slot(entry.slot)
                writer.uint64(entry.stamp.clock)
                writer.bytes(entry.stamp.replica.bytes)
                writer.uint64(entry.stamp.sequence)
                writer.value(entry.value)
            }
        }
        return writer.data
    }

    public init(decoding data: Data, maximumBytes: Int = TimelineLimits.maximumMessageBytes) throws {
        guard !data.isEmpty else { throw TimelineError.malformed }
        guard data.count <= maximumBytes else { throw TimelineError.tooLarge }
        var reader = TimelineReader(data)
        switch try reader.byte() {
        case 1:
            let count = try reader.uint16()
            guard count > 0 else { throw TimelineError.malformed }
            var raw: [Data] = []
            for _ in 0..<count { raw.append(try reader.take(Int(try reader.uint32()))) }
            guard reader.isAtEnd else { throw TimelineError.malformed }
            self = .commits(try raw.map { try TimelineCommit(decoding: $0, maximumBytes: maximumBytes) })
        case 2:
            let flags = try reader.byte()
            guard flags & ~0b11 == 0 else { throw TimelineError.malformed }
            let heads = try reader.heads()
            guard reader.isAtEnd else { throw TimelineError.malformed }
            self = .state(request: TimelineRequest(rawValue: flags), heads: heads)
        case 3:
            let flags = try reader.byte()
            guard flags & ~0b1 == 0 else { throw TimelineError.malformed }
            let isFinal = flags & 1 == 1
            let heads = try reader.heads()
            guard isFinal || heads.isEmpty else { throw TimelineError.malformed }
            var entries: [TimelineStampedEntry] = []
            var previous: TimelineSlot?
            for _ in 0..<(try reader.uint32()) {
                let slot = try reader.slot()
                let clock = try reader.uint64()
                guard let replica = ReplicaID(bytes: try reader.take(16)) else {
                    throw TimelineError.malformed
                }
                let sequence = try reader.uint64()
                guard sequence > 0 else { throw TimelineError.malformed }
                let value = try reader.value()
                guard previous.map({ $0 < slot }) ?? true else { throw TimelineError.malformed }
                entries.append(
                    TimelineStampedEntry(
                        slot: slot,
                        stamp: TimelineStamp(clock: clock, replica: replica, sequence: sequence),
                        value: value))
                previous = slot
            }
            guard reader.isAtEnd else { throw TimelineError.malformed }
            self = .catchUp(isFinal: isFinal, heads: heads, entries: entries)
        default:
            throw TimelineError.unsupportedVersion
        }
    }
}

struct TimelineWriter {
    var data = Data()

    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func uint16(_ value: UInt16) { integer(value, width: 2) }
    mutating func uint32(_ value: UInt32) { integer(value, width: 4) }
    mutating func uint64(_ value: UInt64) { integer(value, width: 8) }

    private mutating func integer<T: FixedWidthInteger>(_ value: T, width: Int) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> T(shift)))
        }
    }

    mutating func slot(_ slot: TimelineSlot) {
        byte(UInt8(slot.collectionBytes.count))
        data.append(contentsOf: slot.collectionBytes)
        uint16(UInt16(slot.keyBytes.count))
        data.append(contentsOf: slot.keyBytes)
    }

    mutating func value(_ value: Data?) {
        guard let value else { return byte(0) }
        byte(1)
        uint32(UInt32(value.count))
        bytes(value)
    }

    mutating func change(_ change: TimelineChange) {
        slot(change.slot)
        value(change.value)
    }

    mutating func heads(_ heads: [ReplicaID: TimelineHead]) {
        uint16(UInt16(heads.count))
        for replica in heads.keys.sorted() {
            let head = heads[replica]!
            bytes(replica.bytes)
            uint64(head.sequence)
            uint64(head.clock)
            bytes(head.id)
        }
    }
}

struct TimelineReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else { throw TimelineError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint16() throws -> UInt16 { UInt16(try integer(2)) }
    mutating func uint32() throws -> UInt32 { UInt32(try integer(4)) }
    mutating func uint64() throws -> UInt64 { try integer(8) }

    private mutating func integer(_ width: Int) throws -> UInt64 {
        try take(width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func slot() throws -> TimelineSlot {
        let collection = [UInt8](try take(Int(try byte())))
        let key = [UInt8](try take(Int(try uint16())))
        return try TimelineSlot(collectionBytes: collection, keyBytes: key)
    }

    mutating func value() throws -> Data? {
        switch try byte() {
        case 0: return nil
        case 1: return try take(Int(try uint32()))
        default: throw TimelineError.malformed
        }
    }

    mutating func heads() throws -> [ReplicaID: TimelineHead] {
        var heads: [ReplicaID: TimelineHead] = [:]
        var previous: ReplicaID?
        for _ in 0..<(try uint16()) {
            guard let replica = ReplicaID(bytes: try take(16)) else { throw TimelineError.malformed }
            let sequence = try uint64()
            let clock = try uint64()
            let id = try take(32)
            guard sequence > 0, previous.map({ $0 < replica }) ?? true else {
                throw TimelineError.malformed
            }
            heads[replica] = TimelineHead(sequence: sequence, clock: clock, id: id)
            previous = replica
        }
        return heads
    }
}
