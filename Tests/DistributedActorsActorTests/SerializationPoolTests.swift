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

class SerializationPoolTests: XCTestCase {
    struct Test1: Codable {
        // These locks are used to validate the different ordering guarantees
        // we give in the serialization pool. The locks are used to block
        // the serializer until we want it to complete serialization.
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

    override func tearDown() {
        system.terminate()
    }

    override func setUp() {
        self.actorPath1 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("bar")])
        self.actorPath2 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("baz")])
    }

    func test_serializationPool_shouldSerializeMessagesInDefaultGroupOnCallingThread() throws {
        let serializationPool = try SerializationPool(props: .default, serialization: system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        // We are locking here to validate that the object is being serialized
        // on the calling thread, because only then will it be able to reenter
        // the lock and return before `unlock` is called at the end of this
        // function
        let test1 = Test1()
        test1.lock.lock()
        defer { test1.lock.unlock() }
        let promise1: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        defer { test2.lock.unlock() }
        let promise2: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        try p.expectMessage("p1")
        serializationPool.serialize(message: test2, recepientPath: actorPath1, promise: promise2)
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldSerializeMessagesInTheSameNonDefaultGroupInSequence() throws {
        let serializationPool = try SerializationPool(props: SerializationPoolProps(serializationGroups: [[self.actorPath1, self.actorPath2]]), serialization: system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on the same, separate thread, because only then will we not receive
        // the "p2" message when unlocking `test2.lock`, because it will still
        // wait on the `test1.lock`
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

        serializationPool.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        serializationPool.serialize(message: test2, recepientPath: actorPath2, promise: promise2)

        test2.lock.unlock()
        try p.expectNoMessage(for: .milliseconds(20))

        test1.lock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldSerializeMessagesInDifferentNonDefaultGroupsInParallel() throws {
        let serializationPool = try SerializationPool(props: SerializationPoolProps(serializationGroups: [[self.actorPath1], [self.actorPath2]]), serialization: system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on different, separate threads, because only then will we receive
        // the "p2" message when unlocking `test2.lock` and afterwards "p1"
        // when unlocking `test1.lock`
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

        serializationPool.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        serializationPool.serialize(message: test2, recepientPath: actorPath2, promise: promise2)

        test2.lock.unlock()
        try p.expectMessage("p2")

        test1.lock.unlock()
        try p.expectMessage("p1")
    }

    func test_serializationPool_shouldDeserializeMessagesInDefaultGroupOnCallingThread() throws {
        let serializationPool = try SerializationPool(props: .default, serialization: system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let json = "{}"

        // We are locking here to validate that the object is being deserialized
        // on the calling thread, because only then will it be able to reenter
        // the lock and return before `unlock` is called at the end of this
        // function
        Test1.deserializerLock.lock()
        defer { Test1.deserializerLock.unlock() }

        var buffer1 = allocator.buffer(capacity: json.count)
        buffer1.write(string: json)
        let promise1: EventLoopPromise<Test1> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()
        defer { Test2.deserializerLock.unlock() }

        var buffer2 = allocator.buffer(capacity: json.count)
        buffer2.write(string: json)
        let promise2: EventLoopPromise<Test2> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.deserialize(Test1.self, from: buffer1, recepientPath: actorPath1, promise: promise1)
        try p.expectMessage("p1")
        serializationPool.deserialize(Test2.self, from: buffer2, recepientPath: actorPath1, promise: promise2)
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldDeserializeMessagesInTheSameNonDefaultGroupInSequence() throws {
        let serializationPool = try SerializationPool(props: SerializationPoolProps(serializationGroups: [[self.actorPath1, self.actorPath2]]), serialization: system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()
        let json = "{}"

        // We are locking here to validate that the objects are being deserialized
        // on the same, separate thread, because only then will we not receive
        // the "p2" message when unlocking `Test2.deserializationLock`, because
        // it will still wait on the `Test1.deserializerLock`
        Test1.deserializerLock.lock()

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

        serializationPool.deserialize(Test1.self, from: buffer1, recepientPath: actorPath1, promise: promise1)
        serializationPool.deserialize(Test2.self, from: buffer2, recepientPath: actorPath1, promise: promise2)

        Test2.deserializerLock.unlock()

        try p.expectNoMessage(for: .milliseconds(20))

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldDeserializeMessagesInDifferentNonDefaultGroupsInParallel() throws {
        let serializationPool = try SerializationPool(props: SerializationPoolProps(serializationGroups: [[self.actorPath1], [self.actorPath2]]), serialization: system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being deserialized
        // on different, separate threads, because only then will we receive
        // the "p2" message when unlocking `Test2.deserializerLock` and
        // afterwards "p1" when unlocking `Test1.deserializerLock`
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
        serializationPool.deserialize(Test1.self, from: buffer1, recepientPath: actorPath1, promise: promise1)
        serializationPool.deserialize(Test2.self, from: buffer2, recepientPath: actorPath2, promise: promise2)

        Test2.deserializerLock.unlock()
        try p.expectMessage("p2")

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
    }

    func test_serializationPool_shouldExecuteSerializationAndDeserializationGroupsOnSeparateWorkerPools() throws {
        let serializationPool = try SerializationPool(props: SerializationPoolProps(serializationGroups: [[self.actorPath1]]), serialization: system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on different, separate threads, than the objects being deserialized
        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<ByteBuffer> = el.newPromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        Test1.deserializerLock.lock()
        let json = "{}"

        var buffer = allocator.buffer(capacity: json.count)
        buffer.write(string: json)
        let promise2: EventLoopPromise<Test1> = el.newPromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        serializationPool.serialize(message: test1, recepientPath: actorPath1, promise: promise1)
        serializationPool.deserialize(Test1.self, from: buffer, recepientPath: actorPath1, promise: promise2)

        try p.expectNoMessage(for: .milliseconds(20))

        Test1.deserializerLock.unlock()
        try p.expectMessage("p2")

        test1.lock.unlock()
        try p.expectMessage("p1")
    }
}
