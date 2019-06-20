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

internal enum ClusterReceptionist {

    struct Replicate: Receptionist.Message, Codable {
        let key: AnyRegistrationKey
        let path: UniqueActorPath
    }

    struct FullStateRequest: Receptionist.Message, Codable {
        let replyTo: ActorRef<ClusterReceptionist.FullState>
    }

    struct FullState: Receptionist.Message, Codable {
        let registrations: [AnyRegistrationKey: [UniqueActorPath]]
    }

    struct Sync: Receptionist.Message {
    }

    static func behavior(syncInterval: TimeAmount) -> Behavior<Receptionist.Message> {
        return .setup { context in
            let storage = Receptionist.Storage()

            // FIXME: this one's pretty bad. When using context.myself instead, we get serialization errors,
            // because the meta key will be `ReceptionistMessage` and it can't find the correct serializer.
            let replicateAdapter = context.messageAdapter(for: ClusterReceptionist.FullState.self) {
                return $0
            }

            context.timers.startPeriodicTimer(key: "sync", message: ClusterReceptionist.Sync(), interval: syncInterval)

            return .receiveMessage {
                switch $0 {
                case let replicate as ClusterReceptionist.Replicate:
                    try ClusterReceptionist.onReplicate(context: context, message: replicate, storage: storage)

                case let fullStateRequest as ClusterReceptionist.FullStateRequest:
                    ClusterReceptionist.onFullStateRequest(context: context, request: fullStateRequest, storage: storage)

                case let fullState as ClusterReceptionist.FullState:
                    try ClusterReceptionist.onFullState(context: context, fullState: fullState, storage: storage)

                case _ as ClusterReceptionist.Sync:
                    try ClusterReceptionist.syncRegistrations(context: context, ref: replicateAdapter)

                case let message as _Register:
                    try ClusterReceptionist.onRegister(context: context, message: message, storage: storage)

                case let message as _Lookup:
                    try ClusterReceptionist.onLookup(context: context, message: message, storage: storage)

                // TODO: subcribe must be made cluster aware
                case let message as _Subscribe:
                    try ClusterReceptionist.onSubscribe(context: context, message: message, storage: storage)

                default:
                    context.log.warning("Received unexpected message \($0)")
                    return .ignore
                }
                return .same
            }
        }
    }

    private static func onRegister(context: ActorContext<Receptionist.Message>, message: _Register, storage: Receptionist.Storage) throws {
        try ClusterReceptionist.addRegistration(context: context, storage: storage, key: message._key.boxed, ref: message._addressableActorRef)

        try ClusterReceptionist.replicate(context: context, register: message)

        message.replyRegistered()
    }

    private static func addRegistration(context: ActorContext<Receptionist.Message>, storage: Receptionist.Storage, key: AnyRegistrationKey, ref: AddressableActorRef) throws {
        if storage.addRegistration(key: key, ref: ref) {
            let terminatedCallback = ClusterReceptionist.makeRemoveRegistrationCallback(context: context, key: key, ref: ref, storage: storage)
            try ClusterReceptionist.startWatcher(ref: ref, context: context, terminatedCallback: terminatedCallback.invoke(()))

            if let subscribed = storage.subscriptions(forKey: key) {
                let registrations = storage.registrations(forKey: key) ?? []
                for subscription in subscribed {
                    subscription._replyWith(registrations)
                }
            }
        }
    }

    private static func onSubscribe(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) throws {
        let boxedMessage = message._boxed
        let key = AnyRegistrationKey(from: message._key)
        if storage.addSubscription(key: key, subscription: boxedMessage) {
            let terminatedCallback = ClusterReceptionist.makeRemoveSubscriptionCallback(context: context, message: message, storage: storage)
            try ClusterReceptionist.startWatcher(ref: message._addressableActorRef, context: context, terminatedCallback: terminatedCallback.invoke(()))

            boxedMessage.replyWith(storage.registrations(forKey: key) ?? [])
        }
    }

    private static func onLookup(context: ActorContext<Receptionist.Message>, message: _Lookup, storage: Receptionist.Storage) throws {
        message.replyWith(storage.registrations(forKey: message._key.boxed) ?? [])
    }

    private static func onFullStateRequest(context: ActorContext<Receptionist.Message>, request: ClusterReceptionist.FullStateRequest, storage: Receptionist.Storage) {
        context.log.info("Received full state request from [\(request.replyTo)]")
        var registrations: [AnyRegistrationKey: [UniqueActorPath]] = [:]
        registrations.reserveCapacity(storage._registrations.count)
        for (key, values) in storage._registrations {
            var paths: [UniqueActorPath] = []
            paths.reserveCapacity(values.count)
            for ref in values {
                let path = ClusterReceptionist.makeRemotePath(ref.path, localAddress: context.system.settings.cluster.uniqueBindAddress)
                paths.append(path)
            }
            registrations[key] = paths
        }

        request.replyTo.tell(FullState(registrations: registrations))
    }

    private static func onReplicate(context: ActorContext<Receptionist.Message>, message: ClusterReceptionist.Replicate, storage: Receptionist.Storage) throws {
        let ref: AddressableActorRef = context.system._resolveUntyped(context: ResolveContext(path: message.path, deadLetters: context.system.deadLetters))

        guard ref.isRemote() else {
            // is local ref and should be ignored
            return
        }

        try ClusterReceptionist.addRegistration(context: context, storage: storage, key: message.key, ref: ref)
    }

    private static func onFullState(context: ActorContext<Receptionist.Message>, fullState: ClusterReceptionist.FullState, storage: Receptionist.Storage) throws {
        context.log.info("Received full state \(fullState)")
        for (key, paths) in fullState.registrations {
            var anyAdded = false
            for path in paths {
                let ref: AddressableActorRef = context.system._resolveUntyped(context: ResolveContext(path: path, deadLetters: context.system.deadLetters))

                guard ref.isRemote() else {
                    // is local ref and should be ignored
                    continue
                }

                if storage.addRegistration(key: key, ref: ref) {
                    anyAdded = true
                    let terminatedCallback = ClusterReceptionist.makeRemoveRegistrationCallback(context: context, key: key, ref: ref, storage: storage)
                    try ClusterReceptionist.startWatcher(ref: ref, context: context, terminatedCallback: terminatedCallback.invoke(()))
                }
            }

            if anyAdded {
                if let subscribed = storage.subscriptions(forKey: key) {
                    let registrations = storage.registrations(forKey: key) ?? []
                    for subscription in subscribed {
                        subscription._replyWith(registrations)
                    }
                }
            }
        }
    }

    // TODO: use context aware watch once implemented. See: https://github.com/apple/swift-distributed-actors/issues/544
    private static func startWatcher<M>(ref: AddressableActorRef, context: ActorContext<M>, terminatedCallback: @autoclosure @escaping () -> Void) throws {
        let behavior: Behavior<Never> = .setup { context in
            context.watch(ref)
            return .receiveSignal { _, signal in
                if let signal = signal as? Signals.Terminated, signal.path == ref.path {
                    terminatedCallback()
                    return .stopped
                }
                return .ignore
            }
        }

        _ = try context.spawnAnonymous(behavior)
    }

    private static func makeRemoveRegistrationCallback(context: ActorContext<Receptionist.Message>, key: AnyRegistrationKey, ref: AddressableActorRef, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            let remainingRegistrations = storage.removeRegistration(key: key, ref: ref) ?? []

            if let subscribed = storage.subscriptions(forKey: key) {
                for subscription in subscribed {
                    subscription._replyWith(remainingRegistrations)
                }
            }
        }
    }

    private static func makeRemoveSubscriptionCallback(context: ActorContext<Receptionist.Message>, message: _Subscribe, storage: Receptionist.Storage) -> AsynchronousCallback<Void> {
        return context.makeAsynchronousCallback {
            storage.removeSubscription(key: message._key.boxed, subscription: message._boxed)
        }
    }

    private static func replicate(context: ActorContext<Receptionist.Message>, register: _Register) throws {
        let remoteControls = context.system._cluster!.associationRemoteControls

        guard !remoteControls.isEmpty else {
            return
        }

        for remoteControl in remoteControls {
            let remoteReceptionistPath = try UniqueActorPath(path: ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist")], address: remoteControl.remoteAddress), uid: ActorUID.wellKnown)
            let path = ClusterReceptionist.makeRemotePath(register._addressableActorRef.path, localAddress: context.system.settings.cluster.uniqueBindAddress)

            remoteControl.sendUserMessage(type: ClusterReceptionist.Replicate.self, envelope: Envelope(payload: .userMessage(Replicate(key: register._key.boxed, path: path))), recipient: remoteReceptionistPath)
        }
    }

    private static func syncRegistrations(context: ActorContext<Receptionist.Message>, ref: ActorRef<ClusterReceptionist.FullState>) throws {
        let remoteControls = context.system._cluster!.associationRemoteControls

        guard !remoteControls.isEmpty else {
            return
        }

        for remoteControl in remoteControls {
            let path = try UniqueActorPath(path: ActorPath([ActorPathSegment("system"), ActorPathSegment("receptionist")], address: remoteControl.remoteAddress), uid: ActorUID.wellKnown)
            remoteControl.sendUserMessage(type: ClusterReceptionist.FullStateRequest.self, envelope: Envelope(payload: .userMessage(ClusterReceptionist.FullStateRequest(replyTo: ref))), recipient: path)
        }
    }

    private static func makeRemotePath(_ _path: UniqueActorPath, localAddress: UniqueNodeAddress) -> UniqueActorPath {
        var path = _path
        if path.address == nil {
            path.address = localAddress
        }
        return path
    }
}
