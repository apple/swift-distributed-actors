//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Cluster singleton ensures that there is no more than one actor of a specific type running in the cluster.
///
/// Actor types that are cluster singletons must be registered during system setup, via `ActorSystemSettings.plugins`. The `ActorRef`
/// of the cluster singleton can later be obtained by calling `ActorContext<Message>.plugins.clusterSingleton.ref(name:)`.
///
/// A cluster singleton may run on any node in the cluster. Use `ClusterSingletonSettings.allocationStrategy` to control node allocation.
/// The `ActorRef` returned by `ref(name:)` is actually a proxy in order to handle situations where the singleton is shifted to different nodes.
public struct ClusterSingleton {
    private let system: ActorSystem

    private let ref: ActorRef<ClusterSingletonShell.Message>

    private var proxies: [String: AddressableActorRef] = [:]

    internal init(_ system: ActorSystem, ref: ActorRef<ClusterSingletonShell.Message>) {
        self.system = system
        self.ref = ref
    }

    /// Adds `subscriber` to `AllocationStrategy`-relevant events, sent by `ClusterSingletonShell`.
    internal func subscribeToAllocationStrategyEvents(_ subscriber: ActorRef<ClusterSingletonShell.AllocationStrategyEvent>) {
        self.ref.tell(.subscribeToAllocationStrategyEvents(subscriber))
    }

    /// Registers `behavior` as cluster singleton identified by `name`.
    ///
    /// The `ActorRef` can be obtained by calling `ref<Message>(name:)`.
    public mutating func register<Message>(_ name: String, props: Props = Props(), _ behavior: Behavior<Message>) -> Result<Void, Error> {
        let settings = ClusterSingletonSettings(name: name)
        return self.register(settings: settings, props: props, behavior)
    }

    /// Registers `behavior` as cluster singleton with `settings`.
    ///
    /// The `ActorRef` can be obtained by calling `ref<Message>(name:)`.
    public mutating func register<Message>(settings: ClusterSingletonSettings, props: Props = Props(), _ behavior: Behavior<Message>) -> Result<Void, Error> {
        guard self.proxies[settings.name] == nil else {
            return .failure(ClusterSingletonError.alreadyRegistered(name: settings.name))
        }

        do {
            // Spawn manager and proxy
            let allocationStrategy = settings.allocationStrategy.make(self.system.settings.cluster, settings)
            let managerRef = try self.system.spawn(
                "$singletonManager-\(settings.name)",
                ClusterSingletonManager(settings: settings, allocationStrategy: allocationStrategy, props: props, behavior).behavior
            )
            let proxyRef = try self.system.spawn("$singletonProxy-\(settings.name)", ClusterSingletonProxy(settings: settings, manager: managerRef).behavior)

            // Save the proxy
            self.proxies[settings.name] = proxyRef.asAddressable()

            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Returns the `ActorRef` for cluster singleton identified by `name`.
    ///
    /// The cluster singleton must have already been registered via one of the `register<Message>` methods.
    public func ref<Message>(name: String) -> Result<ActorRef<Message>, ClusterSingletonError> {
        guard let proxyAddressable = self.proxies[name], let proxyRef = proxyAddressable.asReceivesSystemMessages() as? ActorRef<Message> else {
            return .failure(.unknown(name: name))
        }
        return .success(proxyRef)
    }
}

public enum ClusterSingletonError: Error {
    /// There is no registered cluster singleton identified by `name`.
    case unknown(name: String)
    /// A cluster singleton with `name` has already been registered.
    case alreadyRegistered(name: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingleton settings

/// Setting for a cluster singleton.
public struct ClusterSingletonSettings {
    /// Unique name for the cluster singleton
    public let name: String

    /// Capacity of temporary message buffer in case cluster singleton is unavailable.
    /// If the buffer becomes full, the *oldest* messages would be disposed to make room for the newer messages.
    public var bufferCapacity: Int = 2048 {
        willSet(newValue) {
            precondition(newValue > 0, "bufferCapacity must be greater than 0")
        }
    }

    /// Controls allocation of the node on which the cluster singleton runs.
    public var allocationStrategy: AllocationStrategySettings = .leadership

    public init(name: String) {
        self.name = name
    }
}

/// Cluster singleton node allocation strategies.
public enum AllocationStrategySettings {
    /// Cluster singletons will run on the cluster leader
    case leadership

    func make(_: ClusterSettings, _: ClusterSingletonSettings) -> AllocationStrategy {
        switch self {
        case .leadership:
            return AllocationByLeadership()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingletonShell

internal class ClusterSingletonShell {
    static let naming: ActorNaming = .unique("clusterSingleton")

    init() {}

    var behavior: Behavior<Message> {
        .setup { context in
            var subscribers: [ActorAddress: ActorRef<AllocationStrategyEvent>] = [:]

            // Publish `AllocationStrategy`-relevant events to `subscribers`
            context.system.cluster.events.subscribe(context.subReceive(ClusterEvent.self) { event in
                subscribers.values.forEach { $0.tell(.clusterEvent(event)) }
            })

            return Behavior<Message>.receiveMessage { message in
                switch message {
                case .subscribeToAllocationStrategyEvents(let ref):
                    subscribers[ref.address] = ref
                    context.watch(ref)
                    context.log.trace("Successfully subscribed [\(ref)] to AllocationStrategyEvent stream")
                }

                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                if subscribers.removeValue(forKey: signal.address) != nil {
                    context.log.trace("Removed subscriber [\(signal.address)] because it terminated")
                } else {
                    context.log.warning("Received unexpected termination signal for non-subscriber [\(signal.address)]")
                }
                return .same
            }
        }
    }

    enum Message {
        case subscribeToAllocationStrategyEvents(ActorRef<AllocationStrategyEvent>)
    }

    enum AllocationStrategyEvent {
        case clusterEvent(ClusterEvent)
    }
}
