//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

internal protocol OpLogStreamOp {
    // TODO: compacting ([+A, -A] -> no need to store A)
}

internal class OpLog<Op: OpLogStreamOp> {
    typealias SequenceNr = UInt64

    // TODO: optimize the "op / delta buffer" which this really is, kins of like in Op based CRDTs
    var ops: [SequencedOp]
    var minSeqNr: SequenceNr
    var maxSeqNr: SequenceNr

    /// Size of a single batch update (element of operations)
    let batchSize: Int

    internal init(of: Op.Type = Op.self, batchSize: Int) {
        self.ops = []
        self.batchSize = batchSize
        self.minSeqNr = 0
        self.maxSeqNr = 0
    }

    @discardableResult
    func add(_ op: Op) -> SequencedOp {
        self.maxSeqNr += 1
        let sequencedOp = SequencedOp(sequenceRange: .single(self.maxSeqNr), op: op)
        self.ops.append(sequencedOp)
        return sequencedOp
    }

    // TODO: how to better express this; so it can be maintained by the OpLog itself
    func compact(_ compaction: ([SequencedOp]) -> ([SequencedOp])) {
        self.ops = compaction(self.ops)
        // TODO: update the min
    }

    public var count: Int {
        self.ops.count
    }

    func replay(from: ReplayFrom) -> Replayer {
        .init(opStream: self, atIndex: self.ops.startIndex, atSeqNr: self.minSeqNr)
    }

    internal enum ReplayFrom {
        case beginning
        case sequenceNr(SequenceNr)
    }

    /// Per stream replayer holding the index and sequenceNr at which we know the recipient is.
    /// Will keep replaying the same chunk of ops until they get confirmed
    internal struct Replayer {
        private let opStream: OpLog<Op>
        private var atIndex: Array<Op>.Index
        internal var atSeqNr: SequenceNr

        internal init(opStream: OpLog<Op>, atIndex: Array<Op>.Index, atSeqNr: SequenceNr) {
            self.opStream = opStream
            self.atIndex = atIndex
            self.atSeqNr = atSeqNr
        }

        mutating func confirm(until newSeqNr: SequenceNr) {
            guard newSeqNr > self.atSeqNr else {
                return
            }

            self.atSeqNr = newSeqNr
            for op in self.opStream.ops[self.atIndex...] {
                // scan forward to locate the new index -- we do this in case we did gaps (e.g. if we compacted away removals etc)
                self.atIndex += 1
                if op.sequenceRange.includes(newSeqNr) {
                    return
                }
            }
        }

        func nextOpsChunk() -> ArraySlice<SequencedOp> {
            guard self.atIndex < self.opStream.ops.endIndex else {
                return .init() // no more chunks
            }
            return self.opStream.ops[self.atIndex...].prefix(self.opStream.batchSize)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Sequenced Ops

extension OpLog {
    /// The `Op` operation along with a sequence range i.e. the sequence number it was performed at,
    /// or a range, if the op is a compressed version of a few operations.
    struct SequencedOp {
        typealias SequenceNr = UInt64

        let sequenceRange: SequenceRange
        let op: Op

        enum SequenceRange: Equatable {
            case single(SequenceNr)
            case inclusiveRange(SequenceNr, SequenceNr)

            var max: SequenceNr {
                switch self {
                case .single(let seqNr):
                    return seqNr
                case .inclusiveRange(_, let untilSeqNr):
                    return untilSeqNr
                }
            }

            var min: SequenceNr {
                switch self {
                case .single(let seqNr):
                    return seqNr
                case .inclusiveRange(let fromSeqNr, _):
                    return fromSeqNr
                }
            }

            func includes(_ seqNr: SequenceNr) -> Bool {
                switch self {
                case .single(let nr):
                    return seqNr == nr
                case .inclusiveRange(let from, let to):
                    return from <= seqNr && seqNr <= to
                }
            }
        }
    }
}

extension OpLog.SequencedOp: Codable where Op: Codable {
    // Codable: synthesized conformance
}

extension OpLog.SequencedOp: Equatable where Op: Equatable {}

extension OpLog.SequencedOp.SequenceRange: Codable {
    enum DiscriminatorKeys: String, Codable {
        case single
        case inclusiveRange
    }

    enum CodingKeys: CodingKey {
        case _case

        case single_value
        case inclusiveRange_from
        case inclusiveRange_to
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .single:
            let value = try container.decode(UInt64.self, forKey: .single_value)
            self = .single(value)
        case .inclusiveRange:
            let from = try container.decode(UInt64.self, forKey: .inclusiveRange_from)
            let to = try container.decode(UInt64.self, forKey: .inclusiveRange_to)
            self = .inclusiveRange(from, to)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .single(let single):
            try container.encode(DiscriminatorKeys.single, forKey: ._case)
            try container.encode(single, forKey: .single_value)
        case .inclusiveRange(let from, let to):
            try container.encode(DiscriminatorKeys.inclusiveRange, forKey: ._case)
            try container.encode(from, forKey: .inclusiveRange_from)
            try container.encode(to, forKey: .inclusiveRange_to)
        }
    }
}
