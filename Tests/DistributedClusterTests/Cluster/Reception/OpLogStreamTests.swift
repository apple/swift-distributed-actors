//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import Testing

struct OpLogStreamTests {
    enum TestOp: Equatable, OpLogStreamOp {
        case add(id: String)
        case rm(id: String)
    }

    @Test
    func test_ops_replay() {
        let stream = OpLog(of: TestOp.self, batchSize: 50)
        stream.add(.add(id: "one"))
        stream.add(.add(id: "two"))
        stream.add(.rm(id: "one"))
        stream.add(.add(id: "three"))

        let replayer = stream.replay(from: .beginning)
        Array(replayer.nextOpsChunk()).shouldEqual(
            [
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(1), op: TestOp.add(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(2), op: TestOp.add(id: "two")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(3), op: TestOp.rm(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(4), op: TestOp.add(id: "three")),
            ]
        )
    }

    @Test
    func test_ops_replay_beyondEnd() {
        let stream = OpLog(of: TestOp.self, batchSize: 50)
        stream.add(.add(id: "one"))
        stream.add(.add(id: "two"))
        stream.add(.rm(id: "one"))
        stream.add(.add(id: "three"))

        var replayer = stream.replay(from: .beginning)
        Array(replayer.nextOpsChunk()).shouldEqual(
            [
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(1), op: TestOp.add(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(2), op: TestOp.add(id: "two")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(3), op: TestOp.rm(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(4), op: TestOp.add(id: "three")),
            ]
        )
        replayer.confirm(until: 4)
        replayer.nextOpsChunk().shouldBeEmpty()
        replayer.nextOpsChunk().shouldBeEmpty()
        replayer.nextOpsChunk().shouldBeEmpty()
    }

    @Test
    func test_ops_replay_confirm_replay() {
        let stream = OpLog(of: TestOp.self, batchSize: 50)
        stream.add(.add(id: "one"))
        stream.add(.add(id: "two"))
        stream.add(.rm(id: "one"))
        stream.add(.add(id: "three"))

        var replayer = stream.replay(from: .beginning)

        Array(replayer.nextOpsChunk()).shouldEqual(
            [
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(1), op: TestOp.add(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(2), op: TestOp.add(id: "two")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(3), op: TestOp.rm(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(4), op: TestOp.add(id: "three")),
            ]
        )

        replayer.confirm(until: 2)
        Array(replayer.nextOpsChunk()).shouldEqual(
            [
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(3), op: TestOp.rm(id: "one")),
                OpLog<TestOp>.SequencedOp(sequenceRange: .single(4), op: TestOp.add(id: "three")),
            ]
        )
    }
}
