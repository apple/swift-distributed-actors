//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import AsyncAlgorithms
import XCTest

@available(macOS 15.0, *)
final class DistributedSequenceTests: SingleClusterSystemXCTestCase {
    
    func test_distributed_sequence() async throws {
        let (first, second) = await self.setUpPair { settings in
            settings.enabled = true
        }
        
        let secondProbe = self.testKit(second).makeTestProbe(expecting: Int.self)
        
        // Create an "emitter" on the `first` node
        // Make it return a sequence of a few numbers...
        let expectedSequence = [1, 2, 3]
        let emitter = Emitter(seq: expectedSequence, actorSystem: first)
        
        // The consumer is on the `second` node...
        let consumer: Consumer<Int, ClusterSystem> = Consumer(actorSystem: second)
        
        // Consume the stream in the second
        let stream = try await emitter.getStream()
        let all = try await consumer.consume(stream, probe: secondProbe)
        
        // Verify we got all the messages in the response as well as the probe received them
        all.shouldEqual(expectedSequence)
        _ = try secondProbe.expectMessages(count: expectedSequence.count)
    }
    
}

@available(macOS 15.0, *)
distributed actor Emitter<Element> where Element: Sendable & Codable {
    typealias ActorSystem = ClusterSystem
    let seq: any Sequence<Element>
    
    init(seq: any Sequence<Element>, actorSystem: ActorSystem) {
        self.seq = seq
        self.actorSystem = actorSystem
    }
    
    distributed func getStream() -> some DistributedSequence<Element> {
        DistributedSequenceImpl(self.seq, actorSystem: self.actorSystem)
    }
}

@available(macOS 15.0, *)
distributed actor Consumer<Element, ActorSystem> where ActorSystem: DistributedActorSystem<any Codable>, Element: Sendable & Codable {
    distributed func consume(_ seq: some DistributedSequence<Element>, probe: ActorTestProbe<Element>) async throws -> [Element] {
        var all: [Element] = []
        for try await element in seq {
            all.append(element)
            probe.tell(element)
        }
        
        return all
    }
}

