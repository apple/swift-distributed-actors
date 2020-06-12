//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIO
import NIOFoundationCompat
import XCTest

final class SerializationPoolTests: XCTestCase {
    struct Test1: Codable {
        // These locks are used to validate the different ordering guarantees
        // we give in the serialization pool. The locks are used to block
        // the serializer until we want it to complete serialization.
        static let deserializerLock = _Mutex()
        let lock = _Mutex()

        enum CodingKeys: String, CodingKey {
            case test
        }

        func encode(to encoder: Encoder) throws {
            self.lock.lock()
            defer { self.lock.unlock() }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .test)
        }

        init(from decoder: Decoder) throws {
            Test1.deserializerLock.lock()
            Test1.deserializerLock.unlock()
        }

        init() {}
    }

    struct Test2: Codable {
        static let deserializerLock = _Mutex()
        let lock = _Mutex()

        enum CodingKeys: String, CodingKey {
            case test
        }

        func encode(to encoder: Encoder) throws {
            self.lock.lock()
            defer { self.lock.unlock() }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .test)
        }

        init(from decoder: Decoder) throws {
            Test2.deserializerLock.lock()
            Test2.deserializerLock.unlock()
        }

        init() {}
    }

    let manifest1 = Serialization.Manifest(serializerID: Serialization.SerializerID.foundationJSON, hint: String(reflecting: Test1.self))
    let manifest2 = Serialization.Manifest(serializerID: Serialization.SerializerID.foundationJSON, hint: String(reflecting: Test2.self))

    var system: ActorSystem!
    var testKit: ActorTestKit!

    var actorPath1: ActorPath!
    var actorPath2: ActorPath!

    var elg: MultiThreadedEventLoopGroup!
    var el: EventLoop!
    let allocator = ByteBufferAllocator()

    private func completePromise<T>(_: T.Type, _ promise: EventLoopPromise<T>) -> DeserializationCallback {
        DeserializationCallback {
            switch $0 {
            case .success(.message(let message as T)): promise.succeed(message)
            case .success(.message(let message)): promise.fail(TestError("Could not treat [\(message)]:\(type(of: message as Any)) as \(T.self)"))
            case .success(.deadLetter(let deadLetter)): promise.fail(TestError("Got unexpected dead letter: \(deadLetter)"))
            case .failure(let error): promise.fail(error)
            }
        }
    }

    override func setUp() {
        self.system = ActorSystem("SerializationTests") { settings in
            settings.logging.logger = NoopLogger.make()
            settings.serialization.register(Test1.self)
            settings.serialization.register(Test2.self)
        }
        self.testKit = ActorTestKit(self.system)
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.el = self.elg.next()
        self.actorPath1 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("bar")])
        self.actorPath2 = try! ActorPath([ActorPathSegment("foo"), ActorPathSegment("baz")])
    }

    override func tearDown() {
        self.system.shutdown().wait()
        try! self.elg.syncShutdownGracefully()
    }

    func test_serializationPool_shouldSerializeMessagesInDefaultGroupOnCallingThread() throws {
        let serializationPool = try SerializationPool(settings: .default, serialization: system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        // We are locking here to validate that the object is being serialized
        // on the calling thread, because only then will it be able to reenter
        // the lock and return before `unlock` is called at the end of this
        // function
        let test1 = Test1()
        test1.lock.lock()
        defer { test1.lock.unlock() }
        let promise1: NIO.EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        defer { test2.lock.unlock() }
        let promise2: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.serialize(message: test1, recipientPath: self.actorPath1, promise: promise1)
        try p.expectMessage("p1")
        serializationPool.serialize(message: test2, recipientPath: self.actorPath2, promise: promise2)
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldSerializeMessagesInTheSameNonDefaultGroupInSequence() throws {
        let serializationPool = try SerializationPool(settings: SerializationPoolSettings(serializationGroups: [[self.actorPath1, self.actorPath2]]), serialization: self.system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on the same, separate thread, because only then will we not receive
        // the "p2" message when unlocking `test2.lock`, because it will still
        // wait on the `test1.lock`
        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        let promise2: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.serialize(message: test1, recipientPath: self.actorPath1, promise: promise1)
        serializationPool.serialize(message: test2, recipientPath: self.actorPath2, promise: promise2)

        test2.lock.unlock()
        try p.expectNoMessage(for: .milliseconds(20))

        test1.lock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldSerializeMessagesInDifferentNonDefaultGroupsInParallel() throws {
        let serializationPool = try SerializationPool(settings: SerializationPoolSettings(serializationGroups: [[self.actorPath1], [self.actorPath2]]), serialization: self.system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on different, separate threads, because only then will we receive
        // the "p2" message when unlocking `test2.lock` and afterwards "p1"
        // when unlocking `test1.lock`
        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }

        let test2 = Test1()
        test2.lock.lock()
        let promise2: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.serialize(message: test1, recipientPath: self.actorPath1, promise: promise1)
        serializationPool.serialize(message: test2, recipientPath: self.actorPath2, promise: promise2)

        test2.lock.unlock()
        try p.expectMessage("p2")

        test1.lock.unlock()
        try p.expectMessage("p1")
    }

    func test_serializationPool_shouldDeserializeMessagesInDefaultGroupOnCallingThread() throws {
        let serializationPool = try SerializationPool(settings: .default, serialization: self.system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let json = "{}"

        // We are locking here to validate that the object is being deserialized
        // on the calling thread, because only then will it be able to reenter
        // the lock and return before `unlock` is called at the end of this
        // function
        Test1.deserializerLock.lock()
        defer { Test1.deserializerLock.unlock() }

        var buffer1 = self.allocator.buffer(capacity: json.count)
        buffer1.writeString(json)
        let promise1: EventLoopPromise<Test1> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()
        defer { Test2.deserializerLock.unlock() }

        var buffer2 = self.allocator.buffer(capacity: json.count)
        buffer2.writeString(json)
        let promise2: EventLoopPromise<Test2> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.deserializeAny(from: .nioByteBuffer(buffer1), using: self.manifest1, recipientPath: self.actorPath1, callback: self.completePromise(Test1.self, promise1))
        try p.expectMessage("p1")
        serializationPool.deserializeAny(from: .nioByteBuffer(buffer2), using: self.manifest2, recipientPath: self.actorPath2, callback: self.completePromise(Test2.self, promise2))
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldDeserializeMessagesInTheSameNonDefaultGroupInSequence() throws {
        let serializationPool = try SerializationPool(settings: SerializationPoolSettings(serializationGroups: [[self.actorPath1, self.actorPath2]]), serialization: self.system.serialization)
        defer { serializationPool.shutdown() }
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let json = "{}"

        // We are locking here to validate that the objects are being deserialized
        // on the same, separate thread, because only then will we not receive
        // the "p2" message when unlocking `Test2.deserializationLock`, because
        // it will still wait on the `Test1.deserializerLock`
        Test1.deserializerLock.lock()

        var buffer1 = self.allocator.buffer(capacity: json.count)
        buffer1.writeString(json)
        let promise1: EventLoopPromise<Test1> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()

        var buffer2 = self.allocator.buffer(capacity: json.count)
        buffer2.writeString(json)
        let promise2: EventLoopPromise<Test2> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }

        serializationPool.deserializeAny(from: .nioByteBuffer(buffer1), using: self.manifest1, recipientPath: self.actorPath1, callback: self.completePromise(Test1.self, promise1))
        serializationPool.deserializeAny(from: .nioByteBuffer(buffer2), using: self.manifest2, recipientPath: self.actorPath2, callback: self.completePromise(Test2.self, promise2))

        Test2.deserializerLock.unlock()

        try p.expectNoMessage(for: .milliseconds(20))

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
        try p.expectMessage("p2")
    }

    func test_serializationPool_shouldDeserializeMessagesInDifferentNonDefaultGroupsInParallel() throws {
        let serializationPool = try SerializationPool(settings: SerializationPoolSettings(serializationGroups: [[self.actorPath1], [self.actorPath2]]), serialization: self.system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being deserialized
        // on different, separate threads, because only then will we receive
        // the "p2" message when unlocking `Test2.deserializerLock` and
        // afterwards "p1" when unlocking `Test1.deserializerLock`
        Test1.deserializerLock.lock()
        let json = "{}"

        var buffer1 = self.allocator.buffer(capacity: json.count)
        buffer1.writeString(json)
        let promise1: EventLoopPromise<Test1> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        Test2.deserializerLock.lock()
        var buffer2 = self.allocator.buffer(capacity: json.count)
        buffer2.writeString(json)
        let promise2: EventLoopPromise<Test2> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        serializationPool.deserializeAny(from: .nioByteBuffer(buffer1), using: self.manifest1, recipientPath: self.actorPath1, callback: self.completePromise(Test1.self, promise1))
        serializationPool.deserializeAny(from: .nioByteBuffer(buffer2), using: self.manifest2, recipientPath: self.actorPath2, callback: self.completePromise(Test2.self, promise2))

        Test2.deserializerLock.unlock()
        try p.expectMessage("p2")

        Test1.deserializerLock.unlock()
        try p.expectMessage("p1")
    }

    func test_serializationPool_shouldExecuteSerializationAndDeserializationGroupsOnSeparateWorkerPools() throws {
        let serializationPool = try SerializationPool(settings: SerializationPoolSettings(serializationGroups: [[self.actorPath1]]), serialization: self.system.serialization)
        defer { serializationPool.shutdown() }

        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        // We are locking here to validate that the objects are being serialized
        // on different, separate threads, than the objects being deserialized
        let test1 = Test1()
        test1.lock.lock()
        let promise1: EventLoopPromise<Serialization.Serialized> = self.el.makePromise()
        promise1.futureResult.whenSuccess { _ in
            p.tell("p1")
        }
        Test1.deserializerLock.lock()
        let json = "{}"

        var buffer = self.allocator.buffer(capacity: json.count)
        buffer.writeString(json)
        let promise2: EventLoopPromise<Test1> = self.el.makePromise()
        promise2.futureResult.whenSuccess { _ in
            p.tell("p2")
        }
        promise1.futureResult.whenFailure { print("\($0)") }

        serializationPool.serialize(message: test1, recipientPath: self.actorPath1, promise: promise1)
        serializationPool.deserializeAny(from: .nioByteBuffer(buffer), using: self.manifest1, recipientPath: self.actorPath1, callback: self.completePromise(Test1.self, promise2))

        try p.expectNoMessage(for: .milliseconds(20))

        Test1.deserializerLock.unlock()
        try p.expectMessage("p2")

        test1.lock.unlock()
        try p.expectMessage("p1")
    }
}
