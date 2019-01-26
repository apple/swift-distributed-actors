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

import XCTest

/// Contains helper functions for testing Actor based code.
/// Due to their asynchronous nature Actors are sometimes tricky to write assertions for,
/// since all communication is asynchronous and no access to internal state is offered.
///
/// The [[ActorTestKit]] offers a number of helpers such as test probes and helper functions to
/// make testing actor based "from the outside" code manageable and pleasant.
final public class ActorTestKit {

    private let system: ActorSystem

    private let spawnProbesLock = Lock()

    private let testProbeNames = AtomicAnonymousNamesGenerator(prefix: "testProbe-")

    public init(_ system: ActorSystem) {
        self.system = system
    }

    // MARK: Test Probes

    /// Spawn an [[ActorTestProbe]] which offers various assertion methods for actor messaging interactions.
    public func spawnTestProbe<M>(name maybeName: String? = nil, expecting type: M.Type = M.self) -> ActorTestProbe<M> {
        self.spawnProbesLock.lock()
        defer {
            self.spawnProbesLock.unlock()
        }

        let name = maybeName ?? testProbeNames.nextName()
        return ActorTestProbe(spawn: { probeBehavior in

            // TODO: allow configuring dispatcher for the probe or always use the calling thread one
            var testProbeProps = Props()
            #if SACT_PROBE_CALLING_THREAD
            testProbeProps.dispatcher = .callingThread
            #endif

            return try system.spawn(probeBehavior, name: name, props: testProbeProps)
        })
    }

    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    public func makeFakeContext<M>(forType: M.Type = M.self) -> ActorContext<M> {
        return MockActorContext()
    }

    /// Creates a _fake_ `ActorContext` which can be used to pass around to fulfil type argument requirements,
    /// however it DOES NOT have the ability to perform any of the typical actor context actions (such as spawning etc).
    public func makeFakeContext<M>(for: Behavior<M>) -> ActorContext<M> {
        return self.makeFakeContext(forType: M.self)
    }

    // TODO: we could implement EffectfulContext most likely which should be able to perform all such actions and allow asserting on it.
    // It's quite harder to do and not entirely sure about safety of that so not attempting to do so for now
}

// MARK: Supervisor TestProbe

public extension ActorTestKit {

    /// Wrap the passed in `behavior` using a `Supervisor` which, in addition to applying the the provided `strategy` as usual,
    /// also sends `SupervisionProbeMessages` for inspection to the returned `ActorTestProbe`.
    ///
    /// Usage example:
    /// ```
    ///     let (supervisedBehavior, probe) testKit.superviseWithSupervisionTestProbe(behavior, withStrategy: ...)
    ///     system.spawnAnonymous(supervisedBehavior)
    ///
    ///     probe.expectHandledMessageFailure()
    /// ```
    public func superviseWithSupervisionTestProbe<M>(_ behavior: Behavior<M>, withStrategy strategy: SupervisionStrategy, for failureType: Error.Type = Supervise.AllFailures.self) -> (Behavior<M>, SupervisorTestProbe<M>) {
        let probe: ActorTestProbe<SupervisionProbeMessages<M>> = self.spawnTestProbe()
        let underlying: Supervisor<M> = Supervision.supervisorFor(behavior, strategy, failureType)
        let supervisorProbe = SupervisorTestProbe(probe: probe, underlying: underlying, failureType: failureType)

        let supervised: Behavior<M> = ._supervise(behavior, withSupervisor: supervisorProbe)
        return (supervised, supervisorProbe)
    }

    // TODO we COULD decide to offer a withSupervisor version as well; though I'm not keen on making it very prominent (withSupervisor) just yet
}

public final class SupervisorTestProbe<Message>: Supervisor<Message> {
    private let probe: ActorTestProbe<SupervisionProbeMessages<Message>>
    private let underlying: Supervisor<Message>

    public init(probe: ActorTestProbe<SupervisionProbeMessages<Message>>, underlying: Supervisor<Message>, failureType: Error.Type) {
        self.probe = probe
        self.underlying = underlying
        super.init(failureType: failureType)
    }

    override public func handleMessageFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        do {
            let decision = try self.underlying.handleSignalFailure(context, target: target, failure: failure)
            self.probe.tell(.handledMessageFailure(failure: failure, decision: decision))
            return decision
        } catch {
            self.probe.tell(.failedWhileHandlingMessageFailure(failure: failure, errorWhileHandling: error))
            throw error // escalate
        }
    }

    override public func handleSignalFailure(_ context: ActorContext<Message>, target: Behavior<Message>, failure: Supervision.Failure) throws -> Behavior<Message> {
        do {
            let decision = try self.underlying.handleSignalFailure(context, target: target, failure: failure)
            self.probe.tell(.handledSignalFailure(failure: failure, decision: decision))
            return decision
        } catch {
            self.probe.tell(.failedWhileHandlingSignalFailure(failure: failure, errorWhileHandling: error))
            throw error // escalate
        }
    }

    override public func isSame(as other: Interceptor<Message>) -> Bool {
        return false // TODO mock impl
    }
}

public extension SupervisorTestProbe {
    public func expectHandledMessageFailure() throws -> SupervisionProbeMessages<Message> {
        let got = try self.probe.expectMessage()
        switch got {
        case .handledMessageFailure:
            return got
        default:
            throw self.probe.error("Expected `handledMessageFailure`")
        }
    }
    func expectFailedWhileHandlingMessageFailure() throws -> SupervisionProbeMessages<Message> {
        let got = try self.probe.expectMessage()
        switch got {
        case .failedWhileHandlingMessageFailure:
            return got
        default:
            throw self.probe.error("Expected `failedWhileHandlingMessageFailure`")
        }
    }

    func expectHandledSignalFailure() throws -> SupervisionProbeMessages<Message> {
        let got = try self.probe.expectMessage()
        switch got {
        case .handledMessageFailure:
            return got
        default:
            throw self.probe.error("Expected `handledMessageFailure`")
        }
    }
    func expectFailedWhileHandlingSignalFailure() throws -> SupervisionProbeMessages<Message> {
        let got = try self.probe.expectMessage()
        switch got {
        case .failedWhileHandlingSignalFailure:
             return got
        default:
            throw self.probe.error("Expected `handledSignalFailure`")
        }
    }
}

public enum SupervisionProbeMessages<M> {
    case handledMessageFailure(failure: Supervision.Failure, decision: Behavior<M>)
    case failedWhileHandlingMessageFailure(failure: Supervision.Failure, errorWhileHandling: Error)

    case handledSignalFailure(failure: Supervision.Failure, decision: Behavior<M>)
    case failedWhileHandlingSignalFailure(failure: Supervision.Failure, errorWhileHandling: Error)
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
    override var path: UniqueActorPath {
        return super.path
    }
    override var name: String {
        return "MockActorContext<\(Message.self)>"
    }
    override var myself: ActorRef<Message> {
        fatalError("Failed: \(MockActorContextError())")
    }
    private lazy var _log: Logger = Logging.make("\(type(of: self))")
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
        fatalError("Failed: \(MockActorContextError())")
    }

    override func stop<M>(child ref: ActorRef<M>) throws {
        fatalError("Failed: \(MockActorContextError())")
    }
}
