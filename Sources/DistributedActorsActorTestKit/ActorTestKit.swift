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


import DistributedActorsConcurrencyHelpers
@testable import Swift Distributed ActorsActor
import Logging

import XCTest

/// Contains helper functions for testing Actor based code.
/// Due to their asynchronous nature Actors are sometimes tricky to write assertions for,
/// since all communication is asynchronous and no access to internal state is offered.
///
/// The `ActorTestKit` offers a number of helpers such as test probes and helper functions to
/// make testing actor based "from the outside" code manageable and pleasant.
final public class ActorTestKit {

    private let system: ActorSystem

    private let spawnProbesLock = Lock()

    private let testProbeNames = AtomicAnonymousNamesGenerator(prefix: "testProbe-")

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
    var expectationTimeout: TimeAmount = .milliseconds(300)
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test Probes

public extension ActorTestKit {

    /// Spawn an `ActorTestProbe` which offers various assertion methods for actor messaging interactions.
    // TODO rename expecting to "receiving"? -- ktoso
    func spawnTestProbe<M>(name maybeName: String? = nil, expecting type: M.Type = M.self) -> ActorTestProbe<M> {
        self.spawnProbesLock.lock()
        defer { self.spawnProbesLock.unlock() }

        let name = maybeName ?? testProbeNames.nextName()
        return ActorTestProbe(spawn: { probeBehavior in

            // TODO: allow configuring dispatcher for the probe or always use the calling thread one
            var testProbeProps = Props()
            #if SACT_PROBE_CALLING_THREAD
            testProbeProps.dispatcher = .callingThread
            #endif

            return try system.spawn(probeBehavior, name: name, props: testProbeProps)
        }, settings: self.settings)
    }
}

// MARK: Eventually

public extension ActorTestKit {

    /// Executes passed in block numerous times, until a the expected value is obtained or the `within` time limit expires,
    /// in which case an `EventuallyError` is thrown, along with the last encountered error thrown by block.
    ///
    /// TODO does not handle blocking longer than `within` well
    /// TODO: should use default `within` from TestKit
    @discardableResult
    func eventually<T>(within timeAmount: TimeAmount, interval: TimeAmount = .milliseconds(100),
                       file: StaticString = #file, line: UInt = #line, column: UInt = #column,
                       _ block: () throws -> T) throws -> T {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let deadline = self.system.deadline(fromNow: timeAmount) // TODO system time source?

        var lastError: Error? = nil
        var polledTimes = 0

        while deadline.hasTimeLeft() {
            do {
                polledTimes += 1
                let res  = try block()
                return res
            } catch {
                lastError = error
                usleep(useconds_t(interval.microseconds))
            }
        }

        // This dance is necessary to "nicely print" if we had an embedded call site error,
        // which include colour and formatting, so we have to print the \(msg) directly for that case.
        let lastErrorMessage: String
        switch lastError {
        case .none:
            lastErrorMessage = "Last error: <none>"
        case .some(CallSiteError.error(let message)):
            lastErrorMessage = "Last error: \(message)"
        case .some(let error):
            lastErrorMessage = "Last error: \(error)"
        }

        let message = callSite.detailedMessage("""
                                               No result within \(timeAmount.prettyDescription) for block at \(file):\(line). \
                                               Queried \(polledTimes) times. \
                                               \(lastErrorMessage)
                                               """)
        XCTFail(message, file: callSite.file, line: callSite.line)
        throw EventuallyError(message: message, lastError: lastError)
    }
}

public struct EventuallyError: Error {
    let message: String
    let lastError: Error?

    public init(message: String, lastError: Error?) {
        self.message = message
        self.lastError = lastError
    }
}

// MARK: assertHolds

public extension ActorTestKit {
    /// Executes passed in block numerous times, to check the assertion holds over time.
    /// Throws an `AssertionHoldsError` when the block fails within the specified tiem amount.
    func assertHolds(for timeAmount: TimeAmount, interval: TimeAmount = .milliseconds(100),
                       file: StaticString = #file, line: UInt = #line, column: UInt = #column,
                       _ block: () throws -> Void) throws {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let deadline = self.system.deadline(fromNow: timeAmount) // TODO system time source?

        var polledTimes = 0

        while deadline.hasTimeLeft() {
            do {
                polledTimes += 1
                try block()
                usleep(useconds_t(interval.microseconds))
            } catch {
                let message = callSite.detailedMessage("Failed within \(timeAmount.prettyDescription) for block at \(file):\(line). Queried \(polledTimes) times.")
                XCTFail(message, file: callSite.file, line: callSite.line)
                throw AssertionHoldsError(message: message)
            }
        }
    }
}

public struct AssertionHoldsError: Error {
    let message: String
}


// MARK: Internal "power" assertions, should not be used lightly as they are quite heavy and potentially racy

extension ActorTestKit {
    
    // TODO how to better hide such more nasty assertions?
    // TODO: Not optimal since we always do traverseAll rather than follow the Path of the context
    public func _assertActorPathOccupied(_ path: String, file: StaticString = #file, line: UInt = #line, column: UInt = #column) throws {
        precondition(!path.contains("#"), "assertion path MUST NOT contain # id section of an unique path.")
        
        let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let res: TraversalResult<AddressableActorRef> = self.system._traverseAll { context, ref in
            if ref.path.path.description == path {
                return .accumulateSingle(ref) // TODO: could use the .return(...)
            } else {
                return .continue
            }
        }

        switch res {
        case .result:            return // good
        case .results(let refs): throw callSiteInfo.error("Found more than a single ref for assertion! Got \(refs).")
        case .completed:         throw callSiteInfo.error("Failed to find actor occupying [\(path)]!")
        case .failed(let err):   throw callSiteInfo.error("Path \(path) was not occupied by any actor! Error: \(err)")
        }
    }
}

// MARK: Fake and mock contexts

public extension ActorTestKit {

    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    func makeFakeContext<M>(forType: M.Type = M.self) -> ActorContext<M> {
        return MockActorContext(self.system)
    }

    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    func makeFakeContext<M>(for: Behavior<M>) -> ActorContext<M> {
        return self.makeFakeContext(forType: M.self)
    }

    // TODO: we could implement EffectfulContext most likely which should be able to perform all such actions and allow asserting on it.
    // It's quite harder to do and not entirely sure about safety of that so not attempting to do so for now
}

struct MockActorContextError: Error, CustomStringConvertible {
    var description: String {
        return "MockActorContextError(" +
            "A mock context can not be used to perform any real actions! " +
            "If you find yourself needing to perform assertions on an actor context please file a ticket." + // this would be "EffectfulContext"
            ")"
    }
}

final class MockActorContext<Message>: ActorContext<Message> {
    private let _system: ActorSystem

    init(_ system: ActorSystem) {
        self._system = system
    }

    override var system: ActorSystem {
        return self._system
    }
    override var path: UniqueActorPath {
        return super.path
    }
    override var name: String {
        return "MockActorContext<\(Message.self)>"
    }
    override var myself: ActorRef<Message> {
        return system.deadLetters.adapted()
    }
    private lazy var _log: Logger = Logger(label: "\(type(of: self))")
    override var log: Logger {
        get {
            return self._log
        }
        set {
            self._log = newValue
        }
    }
    override var dispatcher: MessageDispatcher {
        fatalError("Failed: \(MockActorContextError())")
    }

    override func watch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        return super.watch(watchee)
    }

    override func unwatch<M>(_ watchee: ActorRef<M>) -> ActorRef<M> {
        fatalError("Failed: \(MockActorContextError())")
    }

    override func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        fatalError("Failed: \(MockActorContextError())")
    }

    override func spawnWatched<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        fatalError("Failed: \(MockActorContextError())")
    }

    override func spawnWatchedAnonymous<M>(_ behavior: Behavior<M>, props: Props) throws -> ActorRef<M> {
        fatalError("Failed: \(MockActorContextError())")
    }

    override var children: Children {
        get {
            fatalError("Failed: \(MockActorContextError())")
        }
        set {
            fatalError("Failed: \(MockActorContextError())")
        }
    }

    override func stop<M>(child ref: ActorRef<M>) throws {
        fatalError("Failed: \(MockActorContextError())")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Error

extension ActorTestKit {
    /// Returns an error that can be used when coniditions in tests are not met. This is especially useful in
    /// calls to `testKit.eventually`, where a condition is checked multiple times, until it is successful
    /// or times out.
    ///
    /// Examples:
    ///
    ///     testkit.eventually(within: .seconds(1)) {
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
    ///     guard ... else { throw testKit.failure("failed to extract expected information") }
    public func fail(_ message: String? = nil, file: StaticString = #file, line: UInt = #line, column: UInt = #column) -> Error {
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)
        let fullMessage: String = message ?? "<no message>"
        return callSite.error(fullMessage, failTest: true)
    }
}
