//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import NIO
import NIOFoundationCompat
import SwiftDistributedActorsActorTestKit

class SerializationPipelineTests: XCTestCase {
    struct Test1: Codable {
        static let deserializerLock = Mutex()
        let lock = Mutex()

        enum CodingKeys: String, CodingKey {
            case test
        }

        func encode(to encoder: Encoder) throws {
            self.lock.lock()
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .test)
            defer { self.lock.unlock() }
        }

        init(from decoder: Decoder) throws {
            Test1.deserializerLock.lock()
            defer { Test1.deserializerLock.unlock() }
        }

        init() {}
    }

    struct Test2: Codable {
        static let deserializerLock = Mutex()
        let lock = Mutex()

        enum CodingKeys: String, CodingKey {
            case test
        }

        func encode(to encoder: Encoder) throws {
            self.lock.lock()
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .test)
            defer { self.lock.unlock() }
        }

        init(from decoder: Decoder) throws {
            Test2.deserializerLock.lock()
            defer { Test2.deserializerLock.unlock() }
        }

        init() {}
    }

    let system = ActorSystem("SerializationTests") { settings in
        settings.serialization.registerCodable(for: Test1.self, underId: 1001)
        settings.serialization.registerCodable(for: Test2.self, underId: 1002)
    }
    lazy var testKit = ActorTestKit(system)
    var actorPath1: ActorPath! = nil
    var actorPath2: ActorPath! = nil

    let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
    lazy var el = self.elg.next()
    let allocator = ByteBufferAllocator()
    let serializationWorkerCount = 4

    override func tearDown() {
        system.terminate()
    }

    override func setUp() {
        func workerHash(_ p: ActorPath) -> Int {
            return SerializationPipeline.workerHash(path: p, workerCount: self.serializationWorkerCount)
        }

        self.actorPath1 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("bar")])
        // We need to ensure that the worker hashes between `actorPath1` and
        // `actorPath2` are always different, so we randomly generate paths
        // until they are
        repeat {
            self.actorPath2 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("\(UInt.random(in: .min ... .max))")])
        } while workerHash(self.actorPath1) == workerHash(self.actorPath2)
    }

    func test_serializationPipeline_shouldSerializeMessagesForSameRecepientInSequence() throws {
        let pipeline = try SerializationPipeline(workerCount: serializationWorkerCount, serialization: system.serialization)
        defer { pipeline.shutdown() }
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        let promise2: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        pipeline.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        pipeline.serialize(message: test2, recepientPath: actorPath1, promise: promise2)

        test2.lock.unlock()

        try p.expectNoMessage(for: .milliseconds(20))

        test1.lock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPipeline_shouldSerializeMessagesForDifferentRecepientInParallel() throws {
        let pipeline = try SerializationPipeline(workerCount: serializationWorkerCount, serialization: system.serialization)
        defer { pipeline.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        let promise2: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        pipeline.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        pipeline.serialize(message: test2, recepientPath: actorPath2, promise: promise2)

        test2.lock.unlock()
        try p.expectMessage("p2")

        test1.lock.unlock()
        try p.expectMessage("p1")
    }

    func test_serializationPipeline_shouldDeserializeMessagesForSameRecepientInSequence() throws {
        let pipeline = try SerializationPipeline(workerCount: serializationWorkerCount, serialization: system.serialization)
        defer { pipeline.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        Test1.deserializerLock.lock()
        let json = "{}"

        var buffer1 = allocator.buffer(capacity: json.count)
        buffer1.write(string: json)
        let promise1: EventLoopPromise<Test1> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()
        var buffer2 = allocator.buffer(capacity: json.count)
        buffer2.write(string: json)
        let promise2: EventLoopPromise<Test2> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        pipeline.deserialize(to: Test1.self, bytes: buffer1, recepientPath: actorPath1, promise: promise1)
        pipeline.deserialize(to: Test2.self, bytes: buffer2, recepientPath: actorPath1, promise: promise2)

        Test2.deserializerLock.unlock()

        try p.expectNoMessage(for: .milliseconds(20))

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPipeline_shoulDeserializeMessagesForDifferentRecepientInParallel() throws {
        let pipeline = try SerializationPipeline(workerCount: serializationWorkerCount, serialization: system.serialization)
        defer { pipeline.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        Test1.deserializerLock.lock()
        let json = "{}"

        var buffer1 = allocator.buffer(capacity: json.count)
        buffer1.write(string: json)
        let promise1: EventLoopPromise<Test1> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()
        var buffer2 = allocator.buffer(capacity: json.count)
        buffer2.write(string: json)
        let promise2: EventLoopPromise<Test2> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        pipeline.deserialize(to: Test1.self, bytes: buffer1, recepientPath: actorPath1, promise: promise1)
        pipeline.deserialize(to: Test2.self, bytes: buffer2, recepientPath: actorPath2, promise: promise2)

        Test2.deserializerLock.unlock()
        try p.expectMessage("p2")

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
    }
}
