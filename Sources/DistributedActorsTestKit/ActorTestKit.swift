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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import Foundation
import Logging

import XCTest

/// Contains helper functions for testing Actor based code.
/// Due to their asynchronous nature Actors are sometimes tricky to write assertions for,
/// since all communication is asynchronous and no access to internal state is offered.
///
/// The `ActorTestKit` offers a number of helpers such as test probes and helper functions to
/// make testing actor based "from the outside" code manageable and pleasant.
public final class ActorTestKit {
    public let system: ActorSystem

    private let spawnProbesLock = Lock()
    /// Access should be protected by `spawnProbesLock`, in order to guarantee unique names.
    private var namingContext = ActorNamingContext()

    public let settings: ActorTestKitSettings

    public init(_ system: ActorSystem, configuredWith configureSettings: (inout ActorTestKitSettings) -> Void = { _ in () }) {
        self.system = system

        var settings = ActorTestKitSettings()
        configureSettings(&settings)
        self.settings = settings
    }
}

/// Simple error type useful for failing tests / assertions
public struct TestError: Error, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TestKit settings

public struct ActorTestKitSettings {
    /// Timeout used by default by all the `expect...` and `within` functions defined on the testkit and test probes.
    var expectationTimeout: TimeAmount = .seconds(5)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test Probes

extension ActorTestKit {
    /// Spawn an `ActorTestProbe` which offers various assertion methods for actor messaging interactions.
    public func spawnTestProbe<Message: ActorMessage>(
        _ naming: ActorNaming? = nil,
        expecting type: Message.Type = Message.self,
        file: StaticString = #file, line: UInt = #line
    ) -> ActorTestProbe<Message> {
        self.spawnProbesLock.lock()
        defer { self.spawnProbesLock.unlock() }
        // we want to use our own sequence number for the naming here, so we make it here rather than let the
        // system use its own sequence number -- which should only be in use for the user actors.
        let name: String
        if let naming = naming {
            name = naming.makeName(&self.namingContext)
        } else {
            name = ActorTestProbe<Message>.naming.makeName(&self.namingContext)
        }

        return ActorTestProbe(
            spawn: { probeBehavior in

                // TODO: allow configuring dispatcher for the probe or always use the calling thread one
                var testProbeProps = Props()
                #if SACT_PROBE_CALLING_THREAD
                testProbeProps.dispatcher = .callingThread
                #endif

                return try system.spawn(.init(unchecked: .unique(name)), props: testProbeProps, probeBehavior)
            },
            settings: self.settings
        )
    }

    /// Spawn `ActorableTestProbe` which offers various assertions for actor messaging interactions.
    public func spawnActorableTestProbe<Act: Actorable>(
        _ naming: ActorNaming? = nil,
        of actorable: Act.Type = Act.self,
        file: StaticString = #file, line: UInt = #line
    ) -> ActorableTestProbe<Act> {
        self.spawnProbesLock.lock()
        defer { self.spawnProbesLock.unlock() }
        // we want to use our own sequence number for the naming here, so we make it here rather than let the
        // system use its own sequence number -- which should only be in use for the user actors.
        let name: String
        if let naming = naming {
            name = naming.makeName(&self.namingContext)
        } else {
            name = ActorTestProbe<Act.Message>.naming.makeName(&self.namingContext)
        }

        return ActorableTestProbe(
            spawn: { probeBehavior in

                // TODO: allow configuring dispatcher for the probe or always use the calling thread one
                var testProbeProps = Props()
                #if SACT_PROBE_CALLING_THREAD
                testProbeProps.dispatcher = .callingThread
                #endif

                return try system.spawn(.init(unchecked: .unique(name)), props: testProbeProps, probeBehavior)
            },
            settings: self.settings
        )
    }

    /// Spawns an `ActorTestProbe` and immediately subscribes it to the passed in event stream.
    ///
    /// - Hint: Use `fishForMessages` and `fishFor` to filter expectations for specific events.
    public func spawnEventStreamTestProbe<Event: ActorMessage>(
        _ naming: ActorNaming? = nil,
        subscribedTo eventStream: EventStream<Event>,
        file: String = #file, line: UInt = #line, column: UInt = #column
    ) -> ActorTestProbe<Event> {
        let p = self.spawnTestProbe(naming ?? ActorNaming.prefixed(with: "\(eventStream.ref.path.name)-subscriberProbe"), expecting: Event.self)
        eventStream.subscribe(p.ref)
        return p
    }
}

/// A test probe pretends to be the `Actorable` and allows expecting messages be sent to it.
///
/// - SeeAlso: `ActorTestProbe` which is the equivalent API for `ActorRef`s.
public final class ActorableTestProbe<Act: Actorable>: ActorTestProbe<Act.Message> {
    /// `Actor` reference to the underlying test probe actor.
    /// All message sends invoked on this Actor will result in messages in the probe available to be `expect`-ed.
    public var actor: Actor<Act> {
        Actor(ref: self.ref)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Eventually

public extension ActorTestKit {
    /// Executes passed in block numerous times, until a the expected value is obtained or the `within` time limit expires,
    /// in which case an `EventuallyError` is thrown, along with the last encountered error thrown by block.
    ///
    /// `eventually` is designed to be used with the `expectX` functions on `ActorTestProbe`.
    ///
    /// **CAUTION**: Using `shouldX` matchers in an `eventually` block will fail the test on the first failure.
    ///
    // TODO: does not handle blocking longer than `within` well
    // TODO: should use default `within` from TestKit
    @discardableResult
    func eventually<T>(
        within timeAmount: TimeAmount, interval: TimeAmount = .milliseconds(100),
        file: StaticString = #file, line: UInt = #line, column: UInt = #column,
        _ block: () throws -> T
    ) throws -> T {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let deadline = self.system.deadline(fromNow: timeAmount) // TODO: system time source?

        var lastError: Error?
        var polledTimes = 0

        ActorTestKit.enterRepeatableContext()
        while deadline.hasTimeLeft() {
            do {
                polledTimes += 1
                let res = try block()
                return res
            } catch {
                lastError = error
                usleep(useconds_t(interval.microseconds))
            }
        }
        ActorTestKit.leaveRepeatableContext()

        let error = EventuallyError(callSite, timeAmount, polledTimes, lastError: lastError)
        if !ActorTestKit.isInRepeatableContext() {
            XCTFail("\(error)", file: callSite.file, line: callSite.line)
        }
        throw error
    }
}

/// Thrown by `ActorTestKit.eventually` when the encapsulated assertion fails enough times that the eventually rethrows it.
///
/// Intended to be pretty printed in command line test output.
public struct EventuallyError: Error, CustomStringConvertible, CustomDebugStringConvertible {
    let callSite: CallSiteInfo
    let timeAmount: TimeAmount
    let polledTimes: Int
    let lastError: Error?

    init(_ callSite: CallSiteInfo, _ timeAmount: TimeAmount, _ polledTimes: Int, lastError: Error?) {
        self.callSite = callSite
        self.timeAmount = timeAmount
        self.polledTimes = polledTimes
        self.lastError = lastError
    }

    public var description: String {
        var message = ""

        // This dance is necessary to "nicely print" if we had an embedded call site error,
        // which include colour and formatting, so we have to print the \(msg) directly for that case.
        let lastErrorMessage: String
        if let error = lastError {
            lastErrorMessage = "Last error: \(error)"
        } else {
            lastErrorMessage = "Last error: <none>"
        }

        message += """
        No result within \(self.timeAmount.prettyDescription) for block at \(self.callSite.file):\(self.callSite.line). \
        Queried \(self.polledTimes) times, within \(self.timeAmount.prettyDescription). \
        \(lastErrorMessage)
        """

        return message
    }

    public var debugDescription: String {
        let error = self.callSite.error(
            """
            Eventually block failed, after \(self.timeAmount) (polled \(self.polledTimes) times), last error: \(optional: self.lastError)
            """)
        return "\(error)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: assertHolds

public extension ActorTestKit {
    /// Executes passed in block numerous times, to check the assertion holds over time.
    /// Throws an error when the block fails within the specified time amount.
    func assertHolds(
        for timeAmount: TimeAmount, interval: TimeAmount = .milliseconds(100),
        file: StaticString = #file, line: UInt = #line, column: UInt = #column,
        _ block: () throws -> Void
    ) throws {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let deadline = self.system.deadline(fromNow: timeAmount) // TODO: system time source?

        var polledTimes = 0

        while deadline.hasTimeLeft() {
            do {
                polledTimes += 1
                try block()
                usleep(useconds_t(interval.microseconds))
            } catch {
                let error = callSite.error(
                    """
                    Failed within \(timeAmount.prettyDescription) for block at \(file):\(line). \
                    Queried \(polledTimes) times, within \(timeAmount.prettyDescription). \
                    Error: \(error)
                    """
                )
                XCTFail("\(error)", file: callSite.file, line: callSite.line)
                throw error
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Power" assertions, should not be used lightly as they are quite heavy and potentially racy

extension ActorTestKit {
    // TODO: how to better hide such more nasty assertions?
    // TODO: Not optimal since we always do traverseAll rather than follow the Path of the context
    public func _assertActorPathOccupied(_ path: String, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        precondition(!path.contains("#"), "assertion path MUST NOT contain # id section of an unique path.")

        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let res: _TraversalResult<AddressableActorRef> = self.system._traverseAll { _, ref in
            if ref.address.path.description == path {
                return .accumulateSingle(ref)
            } else {
                return .continue
            }
        }

        switch res {
        case .result: return // good
        case .results(let refs): throw callSiteInfo.error("Found more than a single ref for assertion! Got \(refs).")
        case .completed: throw callSiteInfo.error("Failed to find actor occupying [\(path)]!")
        case .failed(let err): throw callSiteInfo.error("Path \(path) was not occupied by any actor! Error: \(err)")
        }
    }

    /// Similar to the internal `system._resolve` however keeps retrying to resolve the passed in address until a not-dead ref is resolved.
    /// If unable to resolve a not-dead reference, this function throws, rather than returning the dead reference.
    ///
    /// This is useful when the resolution might be racing against the startup of the actor we are trying to resolve.
    public func _eventuallyResolve<Message>(address: ActorAddress, of: Message.Type = Message.self, within: TimeAmount = .seconds(5)) throws -> ActorRef<Message> {
        let context = ResolveContext<Message>(address: address, system: self.system)

        return try self.eventually(within: .seconds(3)) {
            let resolved = self.system._resolve(context: context)

            if resolved.address.starts(with: ._dead) {
                throw self.error("Attempting to resolve not-dead [\(address)] yet resolved: \(resolved)")
            } else {
                return resolved
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Fake and mock contexts

public extension ActorTestKit {
    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    func makeFakeContext<M: ActorMessage>(of: M.Type = M.self) -> ActorContext<M> {
        MockActorContext(self.system)
    }

    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    func makeFakeContext<M: ActorMessage>(for: Behavior<M>) -> ActorContext<M> {
        self.makeFakeContext(of: M.self)
    }
}

struct MockActorContextError: Error, CustomStringConvertible {
    var description: String {
        "MockActorContextError(" +
            "A mock context can not be used to perform any real actions! " +
            "If you find yourself needing to perform assertions on an actor context please file a ticket." + // this would be "EffectfulContext"
            ")"
    }
}

public final class MockActorContext<Message: ActorMessage>: ActorContext<Message> {
    private let _system: ActorSystem

    public init(_ system: ActorSystem) {
        self._system = system
    }

    public override var system: ActorSystem {
        self._system
    }

    public override var path: ActorPath {
        super.path
    }

    public override var name: String {
        "MockActorContext<\(Message.self)>"
    }

    public override var myself: ActorRef<Message> {
        self.system.deadLetters.adapted()
    }

    private lazy var _log: Logger = Logger(label: "\(type(of: self))")
    public override var log: Logger {
        get {
            self._log
        }
        set {
            self._log = newValue
        }
    }

    public override var props: Props {
        .init() // mock impl
    }

    @discardableResult
    public override func watch<Watchee>(
        _ watchee: Watchee,
        with terminationMessage: Message? = nil,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DeathWatchable {
        fatalError("Failed: \(MockActorContextError())")
    }

    @discardableResult
    public override func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DeathWatchable {
        fatalError("Failed: \(MockActorContextError())")
    }

    @discardableResult
    public override func spawn<M>(
        _ naming: ActorNaming, of type: M.Type = M.self, props: Props = Props(),
        file: String = #file, line: UInt = #line,
        _ behavior: Behavior<M>
    ) throws -> ActorRef<M>
        where M: ActorMessage {
        fatalError("Failed: \(MockActorContextError())")
    }

    @discardableResult
    public override func spawnWatch<M>(
        _ naming: ActorNaming, of type: M.Type = M.self, props: Props = Props(),
        file: String = #file, line: UInt = #line,
        _ behavior: Behavior<M>
    ) throws -> ActorRef<M>
        where M: ActorMessage {
        fatalError("Failed: \(MockActorContextError())")
    }

    public override var children: Children {
        get {
            fatalError("Failed: \(MockActorContextError())")
        }
        set {
            fatalError("Failed: \(MockActorContextError())")
        }
    }

    public override func stop<M>(child ref: ActorRef<M>) throws {
        fatalError("Failed: \(MockActorContextError())")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Error

extension ActorTestKit {
    /// Returns an error that can be used when conditions in tests are not met. This is especially useful in
    /// calls to `testKit.eventually`, where a condition is checked multiple times, until it is successful
    /// or times out.
    ///
    /// Examples:
    ///
    ///     testKit.eventually(within: .seconds(3)) {
    ///         guard ... else { throw testKit.error("failed to extract expected information") }
    ///     }
    public func error(_ message: String? = nil, file: StaticString = #file, line: UInt = #line, column: UInt = #column) -> Error {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let fullMessage: String = message ?? "<no message>"
        return callSite.error(fullMessage, failTest: false)
    }

    /// Returns a failure with additional callsite information and fails the test.
    ///
    /// Examples:
    ///
    ///     guard ... else { throw testKit.fail("failed to extract expected information") }
    public func fail(_ message: String? = nil, file: StaticString = #file, line: UInt = #line, column: UInt = #column) -> Error {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let fullMessage: String = message ?? "<no message>"
        return callSite.error(fullMessage, failTest: true)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: repeatable context

// Used to mark a repeatable context, in which `ActorTestProbe.expectX` does not
// immediately fail the test, but instead lets the `ActorTestKit.eventually`
// block handle it.
internal extension ActorTestKit {
    static let threadLocalContextKey: String = "SACT_TESTKIT_REPEATABLE_CONTEXT"

    // Sets a flag that can be checked with `isInRepeatableContext`, to avoid
    // failing a test from within blocks that continuously check conditions,
    // e.g. `ActorTestKit.eventually`. This is safe to use in nested calls.
    static func enterRepeatableContext() {
        let currentDepth = self.currentRepeatableContextDepth
        Foundation.Thread.current.threadDictionary[self.threadLocalContextKey] = currentDepth + 1
    }

    // Unsets the flag and causes `isInRepeatableContext` to return `false`.
    // This is safe to use in nested calls.
    static func leaveRepeatableContext() {
        let currentDepth = self.currentRepeatableContextDepth
        precondition(currentDepth > 0, "Imbalanced `leaveRepeatableContext` detected. Depth was \(currentDepth)")
        Foundation.Thread.current.threadDictionary[self.threadLocalContextKey] = currentDepth - 1
    }

    // Returns `true` if we are currently executing a code clock that repeatedly
    // checks conditions. Used in `ActorTestProbe.expectX` and `ActorTestKit.error`
    // to avoid failing the test on the first iteration in e.g. an
    // `ActorTestKit.eventually` block.
    static func isInRepeatableContext() -> Bool {
        self.currentRepeatableContextDepth > 0
    }

    // Returns the current depth of nested repeatable context calls.
    static var currentRepeatableContextDepth: Int {
        guard let currentValue = Foundation.Thread.current.threadDictionary[self.threadLocalContextKey] else {
            return 0
        }

        guard let intValue = currentValue as? Int else {
            fatalError("Expected value under key [\(self.threadLocalContextKey)] to be [\(Int.self)], but found [\(currentValue)]:\(type(of: currentValue))")
        }

        return intValue
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receptionist

extension ActorTestKit {
    /// Ensures that a given number of refs are registered with the Receptionist under `key`.
    /// If `expectedRefs` is specified, also compares it to the listing for `key` and requires an exact match.
    public func ensureRegistered<Message>(
        key: Reception.Key<ActorRef<Message>>,
        expectedCount: Int = 1,
        expectedRefs: Set<ActorRef<Message>>? = nil,
        within: TimeAmount = .seconds(3)
    ) throws {
        let lookupProbe = self.spawnTestProbe(expecting: Reception.Listing<ActorRef<Message>>.self)

        try self.eventually(within: within) {
            self.system.receptionist.lookup(key, replyTo: lookupProbe.ref)

            let listing = try lookupProbe.expectMessage()
            guard listing.refs.count == expectedCount else {
                throw self.error("Expected Reception.Listing for key [\(key)] to have count [\(expectedCount)], but got [\(listing.refs.count)]")
            }
            if let expectedRefs = expectedRefs {
                guard Set(listing.refs) == expectedRefs else {
                    throw self.error("Expected Reception.Listing for key [\(key)] to have refs \(expectedRefs), but got \(listing.refs)")
                }
            }
        }
    }

    /// `Actorable` version of `ensureRegistered()`.
    public func ensureRegistered<Actorable>(
        key: Reception.Key<Actor<Actorable>>,
        expectedCount: Int = 1,
        expectedActors: Set<Actor<Actorable>>? = nil,
        within: TimeAmount = .seconds(3)
    ) throws {
        let lookupProbe = self.spawnTestProbe(expecting: Reception.Listing<Actor<Actorable>>.self)

        try self.eventually(within: within) {
            self.system.receptionist.lookup(key, replyTo: lookupProbe.ref)

            let listing = try lookupProbe.expectMessage()
            guard listing.actors.count == expectedCount else {
                throw self.error("Expected Reception.Listing for key [\(key)] to have count [\(expectedCount)], but got [\(listing.actors.count)]")
            }
            if let expectedActors = expectedActors {
                guard Set(listing.actors) == expectedActors else {
                    throw self.error("Expected Reception.Listing for key [\(key)] to have actors \(expectedActors), but got \(listing.actors)")
                }
            }
        }
    }
}
