//
//  TimelineRelay.swift
//  ZeroByte — Timeline v1
//
//  One run of a replica over the relay (timeline-v1.md §6): read and merge what
//  the other side wrote, commit what is pending, answer a catch-up request,
//  write. Every step is safe to repeat: a message written twice merges once,
//  so a run cut short anywhere only costs a repeat.
//

import Foundation
import ZeroByte

public struct TimelineSyncOutcome: Sendable {
    /// Keys whose entries changed this run, from the other side.
    public var updates: [TimelineUpdate] = []
    /// Commits merged from the other side.
    public var merged = 0
    /// Envelopes written.
    public var written = 0
    /// Messages still waiting, because the mailbox is full.
    public var waiting = 0
    /// The other side's heads, as it last reported them.
    public var peerHeads: [ReplicaID: TimelineHead]?
    /// Whether the other side said it has every commit of this replica.
    public var isPeerCurrent = false
}

public enum TimelineRelay {
    /// About how much of a catch-up one run writes when no budget is given.
    public static let catchUpBudget = 8 * 1_048_576
    /// - Parameters:
    ///   - sends: The direction this replica writes: `.primaryToCompanion` on
    ///     the primary, `.companionToPrimary` on the companion.
    ///   - commitBudget: Commit at most about this many bytes of pending
    ///     changes this run; the rest wait for the next.
    ///   - notify: Asked of the relay with the run's last envelope.
    ///   - values: Produces own values the timeline does not keep, for a
    ///     catch-up (`Timeline.forgetsOwnValues`).
    ///   - persist: Saves the timeline. Called after reading, before the
    ///     relay is pruned, and after writing.
    public static func sync(
        _ timeline: inout Timeline,
        credentials: Credentials,
        transport: any RelayTransport,
        sends: Direction,
        now: Date = Date(),
        commitBudget: Int? = nil,
        notify: Notify = .none,
        values: (TimelineSlot) -> Data? = { _ in nil },
        persist: (Timeline) async throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> TimelineSyncOutcome {
        try await transport.claim()
        var outcome = TimelineSyncOutcome()
        let reads = sends.reversed

        // 1. Read and merge.
        let started = timeline.relay.readThrough
        let headsBefore = timeline.heads
        var fetched = started
        var after = started
        while true {
            let page = try await transport.fetch(direction: reads, after: fetched)
            let before = fetched
            for envelope in page.envelopes {
                if let header = try? Envelope.header(of: envelope) {
                    fetched = max(fetched ?? 0, header.sequence)
                }
                // Not written by the other side under the link key: never applied.
                guard
                    let opened = try? Envelope.open(
                        envelope, direction: reads, after: after, credentials: credentials)
                else { continue }
                after = opened.sequence
                let message: TimelineMessage
                do {
                    message = try TimelineMessage(
                        decoding: opened.plaintext, maximumBytes: timeline.maximumMessageBytes)
                } catch TimelineError.unsupportedVersion {
                    // A newer peer: stop here, unread, until this app is updated.
                    throw TimelineError.unsupportedVersion
                } catch {
                    continue
                }
                let receipt = try timeline.receive(message)
                outcome.updates += receipt.updates
                outcome.merged += receipt.merged
                if receipt.foundGap { timeline.relay.ownRequest.insert(.gap) }
                if let confirmed = receipt.confirmed { timeline.noteConfirmed(confirmed) }
                if let state = receipt.peerState {
                    timeline.relay.peerHeads = state.heads
                    if !state.request.isEmpty {
                        timeline.relay.peerRequest.formUnion(state.request)
                        timeline.relay.peerRequestHeads = state.heads
                    }
                }
                timeline.relay.readThrough = opened.sequence
            }
            guard page.more, fetched != before else { break }
        }
        if let fetched, fetched != started {
            timeline.relay.readThrough = max(timeline.relay.readThrough ?? 0, fetched)
            try await persist(timeline)
            try? await transport.prune(direction: reads, through: fetched)
        }

        // 2. Commit, answer, tell.
        var queued = false
        let commits = timeline.commit(now: now, maximumBytes: commitBudget)
        for message in pack(commits, limit: timeline.maximumMessageBytes) {
            timeline.relay.outbox.append(message)
            queued = true
        }
        if !timeline.relay.peerRequest.isEmpty {
            let request = timeline.relay.peerRequest
            let heads = timeline.relay.peerRequestHeads
            let theirs = heads[timeline.replica]?.sequence ?? 0
            // A gap, or a head that went back: the other side lost what was sent.
            let lost = request.contains(.gap) || theirs < timeline.relay.confirmed
            // A newer request replaces a catch-up still being written.
            timeline.relay.outbox.removeAll { $0.kind == .catchUp }
            timeline.relay.catchUp = timeline.beginCatchUp(after: heads, includingOwn: lost)
            timeline.relay.peerRequest = []
            timeline.relay.peerRequestHeads = [:]
            queued = true
        }
        if var cursor = timeline.relay.catchUp,
            !timeline.relay.outbox.contains(where: { $0.kind == .catchUp })
        {
            let next = timeline.continueCatchUp(
                &cursor, maximumBytes: commitBudget ?? catchUpBudget, values: values)
            // Nothing the requester lacks: no answer at all.
            let isEmpty =
                next.parts.count == 1
                && {
                    guard case .catchUp(_, let heads, let entries) = next.parts[0] else {
                        return false
                    }
                    return entries.isEmpty
                        && heads.allSatisfy { replica, head in
                            (cursor.requesterHeads[replica]?.sequence ?? 0) >= head.sequence
                        }
                }()
            if !(next.isFinished && isEmpty) {
                for part in next.parts {
                    timeline.relay.outbox.append(
                        TimelineOutboxItem(kind: .catchUp, message: part.encoded()))
                }
            }
            timeline.relay.catchUp = next.isFinished ? nil : cursor
            queued = true
        }
        let merged = outcome.merged > 0 || !outcome.updates.isEmpty || timeline.heads != headsBefore
        if !timeline.relay.ownRequest.isEmpty || (merged && commits.isEmpty) {
            var request = timeline.relay.ownRequest
            timeline.relay.outbox.removeAll { item in
                guard item.kind == .state else { return false }
                if case .state(let earlier, _)? = try? TimelineMessage(decoding: item.message) {
                    request.formUnion(earlier)
                }
                return true
            }
            timeline.relay.outbox.append(
                TimelineOutboxItem(kind: .state, message: timeline.state(request: request).encoded()))
            timeline.relay.ownRequest = []
            queued = true
        }
        if queued { try await persist(timeline) }

        // 3. Write.
        if !timeline.relay.outbox.isEmpty {
            let last = try await transport.lastSequence(direction: sends)
            var sequence = max(timeline.relay.nextWrite ?? 1, (last ?? 0) + 1)
            var conflicts = 0
            write: while let item = timeline.relay.outbox.first {
                let envelope = try Envelope.seal(
                    item.message, direction: sends, sequence: sequence, credentials: credentials)
                do {
                    try await transport.put(
                        envelope, direction: sends, sequence: sequence,
                        notify: timeline.relay.outbox.count == 1 ? notify : .none)
                } catch RelayError.sequenceConflict(let last) {
                    conflicts += 1
                    guard conflicts <= 3 else { throw RelayError.sequenceConflict(last: last) }
                    sequence = (last ?? sequence) + 1
                    continue write
                } catch RelayError.quotaExceeded {
                    break write
                }
                timeline.relay.outbox.removeFirst()
                sequence += 1
                timeline.relay.nextWrite = sequence
                outcome.written += 1
            }
            if outcome.written > 0 { try await persist(timeline) }
        }

        outcome.waiting = timeline.relay.outbox.count
        outcome.peerHeads = timeline.relay.peerHeads
        outcome.isPeerCurrent =
            timeline.relay.confirmed >= (timeline.heads[timeline.replica]?.sequence ?? 0)
        return outcome
    }

    /// Queues commits made outside a relay run, on a direct channel for
    /// example, so the relay still carries them if the other side did not
    /// confirm them there (`Timeline.noteConfirmed` drops them once it does).
    public static func enqueue(_ commits: [TimelineCommit], in timeline: inout Timeline) {
        timeline.relay.outbox += pack(commits, limit: timeline.maximumMessageBytes)
    }

    /// Commits in as few messages as fit, in order.
    static func pack(_ commits: [TimelineCommit], limit: Int) -> [TimelineOutboxItem] {
        var items: [TimelineOutboxItem] = []
        var batch: [TimelineCommit] = []
        var size = 3
        func flush() {
            guard let last = batch.last else { return }
            items.append(
                TimelineOutboxItem(
                    kind: .commits, message: TimelineMessage.commits(batch).encoded(),
                    ownThrough: last.sequence))
            batch = []
            size = 3
        }
        for commit in commits {
            if !batch.isEmpty,
                size + 4 + commit.bytes.count > limit || batch.count == Int(UInt16.max)
            {
                flush()
            }
            batch.append(commit)
            size += 4 + commit.bytes.count
        }
        flush()
        return items
    }
}
