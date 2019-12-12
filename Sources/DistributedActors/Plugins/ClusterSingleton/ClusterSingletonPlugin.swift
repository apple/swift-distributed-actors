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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton plugin

public class ClusterSingletonPlugin {
    /// All `ClusterSingleton`s defined in `PluginsSettings`
    private let singletons: [String: ClusterSingleton]

    /// `LazyStart` and the actual `ActorRef` for `ClusterSingletonPluginShell`
    private var lazyShell: LazyStart<ClusterSingletonPluginShell.Message>?
    private var ref: ActorRef<ClusterSingletonPluginShell.Message>!

    /// Creates `ClusterSingletonPlugin` from `settings`.
    public init(settings: ClusterSingletonPluginSettings) {
        self.singletons = settings.singletons
    }

    /// Returns the `ActorRef` for cluster singleton identified by `name`.
    ///
    /// The cluster singleton must have been set up via  `PluginsSettings.add(clusterSingleton:)`.
    public func ref<Message>(name: String) -> Result<ActorRef<Message>, ClusterSingletonError> {
        guard let singleton = self.singletons[name], let proxy = singleton.proxy as? ActorRef<Message> else {
            return .failure(.unknown(name: name))
        }
        return .success(proxy)
    }

    /// Adds `subscriber` to `AllocationStrategy`-relevant events, sent by `ClusterSingletonShell`.
    internal func subscribeToAllocationStrategyEvents(_ subscriber: ActorRef<AllocationStrategyEvent>) {
        self.ref.tell(.subscribeToAllocationStrategyEvents(subscriber))
    }
}

extension ClusterSingletonPlugin: Plugin {
    internal static let name: String = "clusterSingleton"

    func onSystemInit(_ system: ActorSystem) -> Result<Void, Error> {
        do {
            let lazyShell = try! system._prepareSystemActor(ClusterSingletonPluginShell.naming, ClusterSingletonPluginShell().behavior, perpetual: true)
            self.lazyShell = lazyShell // Woken up later (in `onSystemInitComplete`)
            self.ref = lazyShell.ref

            try self.singletons.values.forEach { singleton in
                singleton.proxy = try singleton._spawnProxy(system)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func onSystemInitComplete(_: ActorSystem) -> Result<Void, Error> {
        self.lazyShell?.wakeUp()
        return .success(())
    }

    func onSystemShutdown(_: ActorSystem) -> Result<Void, Error> {
        return .success(())
    }
}

public enum ClusterSingletonError: Error {
    /// A cluster singleton with `name` already exists.
    case nameAlreadyExists(String)
    /// There is no registered cluster singleton identified by `name`.
    case unknown(name: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton plugin settings

public struct ClusterSingletonPluginSettings {
    public static var `default`: ClusterSingletonPluginSettings {
        .init()
    }

    internal var singletons: [String: ClusterSingleton] = [:]

    public init() {}

    /// Adds a `ClusterSingleton`.
    internal mutating func add(_ singleton: ClusterSingleton) -> Result<Void, ClusterSingletonError> {
        guard self.singletons[singleton.settings.name] == nil else {
            return .failure(.nameAlreadyExists(singleton.settings.name))
        }

        self.singletons[singleton.settings.name] = singleton

        return .success(())
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Shell for `ClusterSingletonPlugin`

internal class ClusterSingletonPluginShell {
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
}

internal enum AllocationStrategyEvent {
    case clusterEvent(ClusterEvent)
}
