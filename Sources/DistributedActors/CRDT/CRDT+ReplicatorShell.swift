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

import Foundation
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ReplicatorShell

extension CRDT.Replicator {
    internal class Shell {
        typealias Identity = CRDT.Identity
        typealias OperationConsistency = CRDT.OperationConsistency

        typealias OwnerMessage = CRDT.Replication.DataOwnerMessage
        typealias LocalRegisterResult = CRDT.Replicator.LocalCommand.RegisterResult
        typealias LocalWriteResult = CRDT.Replicator.LocalCommand.WriteResult
        typealias LocalReadResult = CRDT.Replicator.LocalCommand.ReadResult
        typealias LocalDeleteResult = CRDT.Replicator.LocalCommand.DeleteResult
        typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult
        typealias RemoteReadResult = CRDT.Replicator.RemoteCommand.ReadResult
        typealias RemoteDeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult

        private let directReplicator: CRDT.Replicator.Instance
        private var gossipReplication: GossipControl<Void, CRDT.Gossip>!

        // TODO: better name; this is the control from Gossip -> Local
        struct LocalControl {
            private let ref: ActorRef<CRDT.Replicator.Message>

            init(_ ref: ActorRef<Message>) {
                self.ref = ref
            }

            func tellGossipWrite(id: CRDT.Identity, data: StateBasedCRDT) {
                self.ref.tell(.localCommand(.gossipWrite(id, data)))
            }
        }

        var settings: Settings {
            self.directReplicator.settings
        }

        internal var remoteReplicators: Set<ActorRef<Message>> = []

        convenience init(settings: Settings) {
            self.init(CRDT.Replicator.Instance(settings)) // TODO: make it Direct Replicator
        }

        init(_ replicator: CRDT.Replicator.Instance) {
            self.directReplicator = replicator
            self.gossipReplication = nil // will be initialized in setup {}
        }

        var behavior: Behavior<Message> {
            .setup { context in

                context.system.cluster.events.subscribe(
                    context.subReceive(Cluster.Event.self) { event in
                        self.receiveClusterEvent(context, event: event)
                    }
                )

                // TODO: make it enabled by a plugin? opt-in to gossiping the crdts?
                self.gossipReplication = try GossipShell.start(
                    context,
                    name: "gossip",
                    settings: GossipShell.Settings(
                        gossipInterval: .seconds(1),
                        peerDiscovery: .fromReceptionistListing(id: "crdt-gossip-replicator")
                    ),
                    makeLogic: { id in
                        CRDT.GossipReplicatorLogic(identifier: id, LocalControl(context.myself))
                    }
                )

                return .receive { context, message in
                    switch message {
                    case .localCommand(let command):
                        self.tracelog(context, .receive, message: command)
                        self.receiveLocalCommand(context, command: command)
                        return .same
                    case .remoteCommand(let command):
                        self.tracelog(context, .receive, message: command)
                        self.receiveRemoteCommand(context, command: command)
                        return .same
                    }
                }
            }
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Track replicators in the cluster

        private func receiveClusterEvent(_ context: ActorContext<Message>, event: Cluster.Event) {
            let makeReplicatorRef: (UniqueNode) -> ActorRef<Message> = { node in
                let resolveContext = ResolveContext<Message>(address: ._crdtReplicator(on: node), system: context.system)
                return context.system._resolve(context: resolveContext)
            }

            switch event {
            case .membershipChange(let change) where change.toStatus == .up:
                let member = change.member
                guard member.node != context.system.cluster.node else {
                    return // Skip adding member to replicator because it is the same as local node
                }

                self.tracelog(context, .addMember, message: member)
                let remoteReplicatorRef = makeReplicatorRef(member.node)
                self.remoteReplicators.insert(remoteReplicatorRef)

            case .membershipChange(let change) where change.toStatus >= .down:
                let member = change.member
                self.tracelog(context, .removeMember, message: member)
                let remoteReplicatorRef = makeReplicatorRef(member.node)
                self.remoteReplicators.remove(remoteReplicatorRef)

            case .snapshot(let snapshot):
                Cluster.Membership._diff(from: .empty, to: snapshot).changes.forEach { change in
                    self.receiveClusterEvent(context, event: .membershipChange(change))
                }

            case .membershipChange:
                context.log.trace("Ignoring cluster event \(event), only interested in >= .up events", metadata: self.metadata(context))
            default:
                return // ignore other events
            }
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Local command

        private func receiveLocalCommand(_ context: ActorContext<Message>, command: LocalCommand) {
            switch command {
            case .register(let ownerRef, let id, let data, let replyTo):
                self.handleLocalRegisterCommand(context, ownerRef: ownerRef, id: id, data: data, replyTo: replyTo)
            case .write(let id, let data, let consistency, let timeout, let replyTo):
                self.directReplicateLocalWrite(context, id, data, consistency: consistency, timeout: timeout, replyTo: replyTo)
                self.gossipReplicateLocalWrite(context, id, data)
            case .gossipWrite(let id, let data):
                self.acceptGossipWrite(context, id, data)
            case .read(let id, let consistency, let timeout, let replyTo):
                self.handleLocalReadCommand(context, id, consistency: consistency, timeout: timeout, replyTo: replyTo)
            case .delete(let id, let consistency, let timeout, let replyTo):
                self.handleLocalDeleteCommand(context, id, consistency: consistency, timeout: timeout, replyTo: replyTo)
            }
        }

        private func handleLocalRegisterCommand(
            _ context: ActorContext<Message>,
            ownerRef: ActorRef<OwnerMessage>,
            id: CRDT.Identity, data: StateBasedCRDT,
            replyTo: ActorRef<LocalRegisterResult>?
        ) {
            // ==== Direct Replicate -----------------------------------------------------------------------------------
            // Register the owner first
            switch self.directReplicator.registerOwner(dataId: id, owner: ownerRef) {
            case .registered:
                // Then write the full CRDT so it is ready to be read
                switch self.directReplicator.write(id, data, deltaMerge: false) {
                case .applied:
                    replyTo?.tell(.success)
                case .inputAndStoredDataTypeMismatch(let stored):
                    replyTo?.tell(.failure(.inputAndStoredDataTypeMismatch(stored)))
                case .unsupportedCRDT:
                    replyTo?.tell(.failure(.unsupportedCRDT))
                }
            }
            // We are initializing local store with the CRDT essentially, so there is no need to send `.updated` to
            // owners or propagate change to the cluster (i.e., local only).

            // ==== Gossip Replicate -----------------------------------------------------------------------------------
            // TODO: anything to do here? register with the gossiper?
        }

        private func directReplicateLocalWrite(
            _ context: ActorContext<Message>,
            _ id: CRDT.Identity,
            _ data: StateBasedCRDT,
            consistency: OperationConsistency,
            timeout: TimeAmount,
            replyTo: ActorRef<LocalWriteResult>
        ) {
            // TODO: keep track where we direct replicated, and we can de-prioritize gossip there (or don't at all even)
            switch self.directReplicator.write(id, data, deltaMerge: true) {
            // `isNew` should always be false. See details in `makeRemoteWriteCommand`.
            case .applied(let updatedData, let isNew):
                switch consistency {
                case .local: // we are done; no need to replicate
                    replyTo.tell(.success)
                    self.notifyOwnersOnUpdate(context, id, updatedData)
                case .atLeast, .quorum, .all:
                    // ==== Direct Replicate ---------------------------------------------------------------------------
                    do {
                        let performWriteFuture = try self.performOnRemoteMembers(
                            context,
                            for: id, with: consistency,
                            localConfirmed: true,
                            isSuccessful: { $0.isSuccess }
                        ) {
                            // Use `data`, NOT `updatedData`, to make `RemoteCommand`!!!
                            // We are replicating a specific change (e.g., `GCounter.increment`) made to a specific
                            // actor-owned CRDT (represented either by `data` as a whole or `data.delta`), not the
                            // collected changes made to the CRDT with the given `id` (represented by `updatedData`)--
                            // that would be done with gossip.
                            .remoteCommand(self.makeRemoteWriteCommand(context, id, data, isNewIdLocally: isNew, replyTo: $0))
                        }

                        // This uses `onResultAsync` and not `awaitResult` on purpose (see https://github.com/apple/swift-distributed-actors/pull/117#discussion_r324453628).
                        // With `onResultAsync` we might potentially run into a race here. Suppose there is a CRDT 'g1'
                        // and 5 nodes in the cluster:
                        // 1. g1 is updated locally and `LocalCommand.write` is sent to the local replicator.
                        // 2. Local replicator performs direct replication and sends `RemoteCommand` to 3 of 5 nodes ("update #1").
                        // 3. Local replicator only receives confirmations from 2 out of 3 nodes, so the operation
                        //    is not complete yet.
                        // 4. g1 is updated locally again and the local replicator receives another `LocalCommand.write`.
                        //    The local replicator repeats step 2 (i.e., "update #2"), but this time it gets all 3
                        //    confirmations right away. Meanwhile, "update #1" is still pending on that third confirmation...
                        //
                        // The question then is: should we guarantee ordering for local updates such that update #2
                        // cannot complete before #1? Can we offer the same guarantee for updates sent by other
                        // nodes? While it might be nice to have such guarantee because it provides predictability, is
                        // this what users expect with CRDTs in general?
                        //
                        // The current implementation does NOT guarantee ordering.
                        // Opened https://github.com/apple/swift-distributed-actors/issues/136 to track in case we do in the future.
                        //
                        // This is the only place in the call-chain where timeout != .effectivelyInfinite (see https://github.com/apple/swift-distributed-actors/issues/137).
                        context.onResultAsync(of: performWriteFuture, timeout: timeout) { result in
                            switch result {
                            case .success:
                                replyTo.tell(.success)
                                self.notifyOwnersOnUpdate(context, id, updatedData)
                            case .failure(let err): // : Error
                                let error = CRDT.OperationConsistency.Error.wrap(err)
                                context.log.warning("Failed to write [\(id.id)] \(type(of: data as Any)) with consistency \(consistency): \(error)")
                                replyTo.tell(.failure(.consistencyError(error)))
                            }
                            return .same
                        }
                    } catch let error as OperationConsistency.Error {
                        replyTo.tell(.failure(.consistencyError(error)))
                    } catch {
                        fatalError("Unexpected error while writing \(updatedData) to remote nodes. Replicator: \(self.debugDescription)")
                    }

                    // ==== Gossip Replicate ---------------------------------------------------------------------------
                    self.gossipReplication.update(id, metadata: (), payload: CRDT.Gossip(payload: updatedData)) // TODO: v2, allow tracking the deltas here
                }
            case .inputAndStoredDataTypeMismatch(let stored):
                replyTo.tell(.failure(.inputAndStoredDataTypeMismatch(stored)))
            case .unsupportedCRDT:
                replyTo.tell(.failure(.unsupportedCRDT))
            }
        }

        private func gossipReplicateLocalWrite(
            _ context: ActorContext<Message>,
            _ id: CRDT.Identity,
            _ data: StateBasedCRDT
        ) {
            self.gossipReplication.update(id, metadata: (), payload: CRDT.Gossip(payload: data))
        }

        private func acceptGossipWrite(
            _ context: ActorContext<Message>,
            _ id: CRDT.Identity,
            _ data: StateBasedCRDT
        ) {
            // TODO: keep track where we direct replicated, and we can de-prioritize gossip there (or don't at all even)
            switch self.directReplicator.write(id, data, deltaMerge: true) {
            // `isNew` should always be false. See details in `makeRemoteWriteCommand`.
            case .applied(let updatedData, _):
                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .inputAndStoredDataTypeMismatch:
                () // replyTo.tell(.failure(.inputAndStoredDataTypeMismatch(stored))) // FIXME: cleanup
            case .unsupportedCRDT:
                () // replyTo.tell(.failure(.inputAndStoredDataTypeMismatch(stored))) // FIXME: cleanup
            }
        }

        private func makeRemoteWriteCommand(
            _ context: ActorContext<Message>,
            _ id: CRDT.Identity, _ data: StateBasedCRDT, isNewIdLocally: Bool,
            replyTo: ActorRef<RemoteWriteResult>
        ) -> RemoteCommand {
            // Technically, `isNewIdLocally` should always be false because all CRDTs are `ActorOwned`, and therefore
            // must be registered (automatically done by the initializer calling `LocalCommand.register`). Since
            // `register` writes the CRDT to the local store, the `id` must exist by the time a `LocalCommand.write` is
            // issued. If, for whatever reasons, registration was not done on a remote node, then
            // `RemoteCommand.writeDelta` would fail with `.missingCRDTForDelta` error, but the overall result for the
            // direct replication might still be ok depending on the `OperationConsistency`--we send the `RemoteCommand`
            // to all remote nodes but it might not be necessary for all of them to succeed, so a failure might potentially
            // be compensated.
            // See https://github.com/apple/swift-distributed-actors/pull/117#discussion_r324449127

            let remoteCommand: RemoteCommand
            switch data {
            case let delta as AnyDeltaCRDT:
                // TODO: need to make anything special here?
                remoteCommand = .write(id, delta, replyTo: replyTo)

            case let full:
                remoteCommand = .write(id, full, replyTo: replyTo)
            }

//            switch data {
//            case let data as AnyCvRDT:
//                remoteCommand = .write(id, data, replyTo: replyTo)
//            case let data as AnyDeltaCRDT:
//                if isNewIdLocally {
//                    // Send full CRDT because remote replicator probably doesn't know about this CRDT
//                    // either and sending just the delta would not work.
//                    remoteCommand = .write(id, data, replyTo: replyTo)
//                } else {
//                    // Not new, so send delta only. `delta` shouldn't be nil but we will just send the full CRDT instead.
//                    if let delta = data.delta {
//                        // Note that for `.writeDelta` to succeed, the CRDT must be registered on the remote node!!!
//                        remoteCommand = .writeDelta(id, delta: delta, replyTo: replyTo)
//                    } else {
//                        context.log.warning("The delta for \(id) is nil, which is not expected")
//                        remoteCommand = .write(id, data, replyTo: replyTo)
//                    }
//                }
//            default: // neither AnyCvRDT nor AnyDeltaCRDT
//                fatalError("Cannot replicate to remote nodes. Unknown data type: \(data)")
//            }

            return remoteCommand
        }

        private func handleLocalReadCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, consistency: OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<LocalReadResult>) {
            switch consistency {
            case .local: // doesn't rely on remote members at all
                switch self.directReplicator.read(id) {
                case .data(let stored):
                    replyTo.tell(.success(stored))
                // No need to notify owners since it's a read-only operation
                case .notFound:
                    replyTo.tell(.failure(.notFound))
                }
            case .atLeast, .quorum, .all:
                let localConfirmed: Bool
                switch self.directReplicator.read(id) {
                case .data:
                    localConfirmed = true
                case .notFound:
                    // Not found locally but we might be able to make it up by reading from an additional remote member
                    localConfirmed = false
                }

                do {
                    // swiftformat:disable indent unusedArguments wrapArguments
                    let performReadFuture = try self.performOnRemoteMembers(
                        context,
                        for: id, with: consistency,
                        localConfirmed: localConfirmed,
                        isSuccessful: { $0.isSuccess }
                    ) {
                        .remoteCommand(.read(id, replyTo: $0))
                    }
                    // This is the only place in the call-chain where timeout != .effectivelyInfinite (see https://github.com/apple/swift-distributed-actors/issues/137).
                    context.onResultAsync(of: performReadFuture, timeout: timeout) { result in
                        switch result {
                        case .success(let remoteResults):
                            // We've read from the remote replicators, now merge their versions of the CRDT to local
                            for (_, remoteReadResult) in remoteResults {
                                guard case .success(let data) = remoteReadResult else {
                                    let msg = "Remote results should contain .success value only: \(remoteReadResult)"
                                    replyTo.tell(.failure(.remoteReadFailure(msg)))
                                    return .same
                                }

                                // Since we received read results, we take the opportunity to include their data in the values stored
                                // in the direct replicator.
                                guard case .applied = self.directReplicator.write(id, data) else {
                                    // TODO: really sure that we want to crash?
                                    fatalError("Failed to update \(id) locally with remote data \(remoteReadResult). Replicator: \(self.debugDescription)")
                                }
                            }

                            // Read the updated CRDT from the local data store
                            guard case .data(let updatedData) = self.directReplicator.read(id) else {
                                guard !remoteResults.isEmpty else {
                                    // If CRDT doesn't exist locally and we didn't get any remote results, return `.notFound`.
                                    // See also https://github.com/apple/swift-distributed-actors/issues/172
                                    replyTo.tell(.failure(.notFound))
                                    return .same
                                }
                                // Otherwise, if we have received remote results then CRDT should have been written to local.
                                fatalError("Expected \(id) to be found locally but it is not. Remote results: \(remoteResults), replicator: \(self.debugDescription)")
                            }

                            // Notify the initiator of this operation that it succeeded
                            replyTo.tell(.success(updatedData))

                            // Update the data stored in the replicator (yeah today we store 2 copies in the replicators, we could converge them into one with enough effort)
                            self.gossipReplication.update(id, metadata: (), payload: CRDT.Gossip(payload: updatedData)) // TODO: v2, allow tracking the deltas here

                            // Followed by notifying all owners since the CRDT might have been updated
                            // TODO: this notifies owners even when the CRDT hasn't changed
                            // TODO: implement "notify delay" i.e. that there's a 500ms window where we can aggregate more writes and flush them once to Owned values
                            self.notifyOwnersOnUpdate(context, id, updatedData)
                        case .failure(let err):
                            let error = CRDT.OperationConsistency.Error.wrap(err)
                            context.log.warning("Failed to read [\(id.id)] with consistency \(consistency): \(error)")
                            replyTo.tell(.failure(.consistencyError(error)))
                        }
                        return .same
                    }
                } catch let error as OperationConsistency.Error {
                    replyTo.tell(.failure(.consistencyError(error)))
                } catch {
                    fatalError("Unexpected error while reading \(id) from remote nodes. Replicator: \(self.debugDescription), error: \(error)")
                }
            }
        }

        private func handleLocalDeleteCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, consistency: OperationConsistency, timeout: TimeAmount, replyTo: ActorRef<LocalDeleteResult>) {
            switch self.directReplicator.delete(id) {
            case .applied:
                switch consistency {
                case .local: // we are done; no need to replicate
                    replyTo.tell(.success)
                    self.notifyOwnersOnDelete(context, id)
                case .atLeast, .quorum, .all:
                    do {
                        let remoteFuture = try self.performOnRemoteMembers(context, for: id, with: consistency, localConfirmed: true, isSuccessful: { $0 == RemoteDeleteResult.success }) {
                            .remoteCommand(.delete(id, replyTo: $0))
                        }
                        // This is the only place in the call-chain where timeout != .effectivelyInfinite (see https://github.com/apple/swift-distributed-actors/issues/137).
                        context.onResultAsync(of: remoteFuture, timeout: timeout) { result in
                            switch result {
                            case .success:
                                replyTo.tell(.success)
                                self.notifyOwnersOnDelete(context, id)
                            case .failure(let err):
                                let error = CRDT.OperationConsistency.Error.wrap(err)
                                context.log.warning("Failed to delete [\(id.id)] with consistency \(consistency): \(error)")
                                replyTo.tell(.failure(.consistencyError(error)))
                            }
                            return .same
                        }
                    } catch let error as OperationConsistency.Error {
                        replyTo.tell(.failure(.consistencyError(error)))
                    } catch {
                        fatalError("Unexpected error while deleting \(id) on remote nodes. Replicator: \(self.debugDescription), error: \(error)")
                    }
                }
            }
        }

        private func performOnRemoteMembers<RemoteCommandResult>(
            _ context: ActorContext<Message>,
            for id: CRDT.Identity,
            with consistency: OperationConsistency,
            localConfirmed: Bool,
            isSuccessful: @escaping (RemoteCommandResult) -> Bool,
            _ makeRemoteCommand: @escaping (ActorRef<RemoteCommandResult>) -> Message
        ) throws -> EventLoopFuture<[ActorRef<Message>: RemoteCommandResult]> {
            let promise = context.system._eventLoopGroup.next().makePromise(of: [ActorRef<Message>: RemoteCommandResult].self)

            // Determine the number of successful responses needed to satisfy consistency requirement.
            // The `RemoteCommand` is sent to *all* known remote replicators, but the consistency
            // requirement succeeds as long as this threshold is met.
            var execution: OperationExecution<RemoteCommandResult>
            do {
                execution = try .init(with: consistency, remoteMembersCount: self.remoteReplicators.count, localConfirmed: localConfirmed)
            } catch {
                // Initialization could fail (e.g., OperationConsistency.Error). In that case we fail the promise and return.
                promise.fail(error)
                return promise.futureResult
            }

//            let instrumentation = ActorCRDTReplicatorInstrumentation()
//            instrumentation.dataReplicateDirectStop(id: promise.futureResult, execution: execution)

            // It's possible for operation to be fulfilled without actually calling remote members.
            // e.g., when consistency = .atLeast(1) and localConfirmed = true
            if execution.fulfilled {
                promise.succeed(execution.remoteConfirmationsReceived) // empty dictionary
//                instrumentation.dataReplicateDirectStop(id: promise.futureResult, execution: execution)
                return promise.futureResult
            }
            // If execution is not fulfilled at this point based on the given parameters and there are no remote members
            // (i.e., we are not entering the for-loop below), then it's impossible to fulfill it.
            guard !self.remoteReplicators.isEmpty else {
                promise.fail(CRDT.OperationConsistency.Error.unableToFulfill(consistency: consistency, localConfirmed: localConfirmed, required: execution.confirmationsRequired, remaining: execution.remoteConfirmationsNeeded, obtainable: 0))
//                instrumentation.dataReplicateDirectStop(id: promise.futureResult, execution: execution)
                return promise.futureResult
            }

            // Send `RemoteCommand` to every remote replicator and wait for as many successful responses as needed
            for remoteReplicator: ActorRef<Message> in self.remoteReplicators {
                let remoteCommandResult = remoteReplicator.ask(for: RemoteCommandResult.self, timeout: .effectivelyInfinite, makeRemoteCommand)

                context.onResultAsync(of: remoteCommandResult, timeout: .effectivelyInfinite) { result in
                    switch result {
                    case .success(let remoteCommandResult):
                        if isSuccessful(remoteCommandResult) {
                            // TODO we could consider directly updating directReplicator with any received back data,
                            // after all, it definitely "adds information"; rather than performing the adding data only the entire operation succeeds
                            // this makes reusing this function a bit harder, but perhaps possible.
                            execution.confirm(from: remoteReplicator, result: remoteCommandResult)
                        } else {
                            context.log.warning("Operation failed for [\(id.id)] at \(remoteReplicator): \(remoteCommandResult)")
                            execution.failed(at: remoteReplicator)
                        }
                    case .failure(let error):
                        context.log.warning("Operation failed for [\(id.id)] at \(remoteReplicator): \(error)")
                        execution.failed(at: remoteReplicator)
                    }

                    // Check if we can mark promise succeed/fail
                    if execution.fulfilled {
                        promise.succeed(execution.remoteConfirmationsReceived)
//                        instrumentation.dataReplicateDirectStop(id: promise.futureResult, execution: execution)
                    } else if execution.failed {
                        promise.fail(CRDT.OperationConsistency.Error.tooManyFailures(allowed: execution.remoteFailuresAllowed, actual: execution.remoteFailuresCount))
//                        instrumentation.dataReplicateDirectStop(id: promise.futureResult, execution: execution)
                    } else {
                        // Indeterminate: we have not received enough results to mark execution success/failure.
                        // Eventually, either this operation will fail with timeout, or execution will be fulfilled or failed.
                        ()
                    }

                    return .same
                }
            }

            return promise.futureResult
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Remote command

        private func receiveRemoteCommand(_ context: ActorContext<Message>, command: RemoteCommand) {
            switch command {
            case .write(let id, let data, let replyTo):
                self.tracelog(context, .receive, message: command)
                self.handleRemoteWriteCommand(context, id, data, replyTo: replyTo)
            case .writeDelta(let id, let delta, let replyTo):
                self.tracelog(context, .receive, message: command)
                self.handleRemoteWriteDeltaCommand(context, id, delta, replyTo: replyTo)
            case .read(let id, let replyTo):
                self.tracelog(context, .receive, message: command)
                self.handleRemoteReadCommand(context, id, replyTo: replyTo)
            case .delete(let id, let replyTo):
                self.tracelog(context, .receive, message: command)
                self.handleRemoteDeleteCommand(context, id, replyTo: replyTo)
            }
        }

        private func handleRemoteWriteCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, _ data: StateBasedCRDT, replyTo: ActorRef<RemoteWriteResult>) {
            switch self.directReplicator.write(id, data, deltaMerge: false) {
            case .applied(let updatedData, _):
                replyTo.tell(.success)
                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .inputAndStoredDataTypeMismatch(let stored):
                replyTo.tell(.failure(.inputAndStoredDataTypeMismatch(hint: "\(stored)")))
            case .unsupportedCRDT:
                replyTo.tell(.failure(.unsupportedCRDT))
            }
        }

        private func handleRemoteWriteDeltaCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, _ delta: StateBasedCRDT, replyTo: ActorRef<RemoteWriteResult>) {
            switch self.directReplicator.writeDelta(id, delta) {
            case .applied(let updatedData):
                replyTo.tell(.success)
                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .missingCRDTForDelta:
                replyTo.tell(.failure(.missingCRDTForDelta))
            case .incorrectDeltaType(let expected):
                replyTo.tell(.failure(.incorrectDeltaType(hint: "\(expected)")))
            case .cannotWriteDeltaForNonDeltaCRDT:
                replyTo.tell(.failure(.cannotWriteDeltaForNonDeltaCRDT))
            }
        }

        private func handleRemoteReadCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, replyTo: ActorRef<RemoteReadResult>) {
            switch self.directReplicator.read(id) {
            case .data(let stored):
                // Send full CRDT back
                replyTo.tell(.success(stored))
            case .notFound:
                replyTo.tell(.failure(.notFound))
            }

            // Read-only command; nothing has changed so no need to notify anyone
        }

        private func handleRemoteDeleteCommand(_ context: ActorContext<Message>, _ id: CRDT.Identity, replyTo: ActorRef<RemoteDeleteResult>) {
            switch self.directReplicator.delete(id) {
            case .applied:
                replyTo.tell(.success)
                self.notifyOwnersOnDelete(context, id)
            }
        }

        // ==== --------------------------------------------------------------------------------------------------------
        // MARK: Notify owners

        private func notifyOwnersOnUpdate(_: ActorContext<Message>, _ id: CRDT.Identity, _ data: StateBasedCRDT) {
            if let owners = self.directReplicator.owners(for: id) {
                let message: OwnerMessage = .updated(data)
                for owner in owners {
                    owner.tell(message)
                }
            }
        }

        private func notifyOwnersOnDelete(_: ActorContext<Message>, _ id: CRDT.Identity) {
            if let owners = self.directReplicator.owners(for: id) {
                for owner in owners {
                    owner.tell(.deleted)
                }
            }
        }
    }
}

extension CRDT.Replicator {
    /// Track execution of an operation by tallying confirmations and failures received. "Confirm" implies successful
    /// execution of the operation in a replica. The number of confirmations needed is derived based on `OperationConsistency`,
    /// the number of members involved, and whether or not the operation has succeeded in the local replica. The number
    /// of failures allowed is the difference between this and the total remote members count.
    ///
    /// An operation is "fulfilled" when the number of received confirmations reaches or goes beyond what is required.
    /// An operation has failed if the failures count is greater than what is allowed.
    ///
    /// It is the responsibility of the caller to decide if the operation must succeed in the local replica or not
    /// (e.g., it might be ok for `read` because we can make it up by reading from an additional remote member).
    internal struct OperationExecution<Result> {
        let localConfirmed: Bool
        let confirmationsRequired: Int

        let remoteConfirmationsNeeded: Int
        var remoteConfirmationsReceived = [ActorRef<Message>: Result]()

        let remoteFailuresAllowed: Int
        var remoteFailuresCount: Int = 0

        var fulfilled: Bool {
            self.remoteConfirmationsReceived.count >= self.remoteConfirmationsNeeded // >= rather than == is deliberate
        }

        var failed: Bool {
            // Don't return true unless there is actually a failure
            self.remoteFailuresCount > 0 && self.remoteFailuresCount > self.remoteFailuresAllowed
        }

        init(with consistency: CRDT.OperationConsistency, remoteMembersCount: Int, localConfirmed: Bool) throws {
            self.localConfirmed = localConfirmed

            let membersCount = remoteMembersCount + 1 // + 1 for local

            switch consistency {
            case .local:
                // Local is not allowed to fail for `.local`
                guard localConfirmed else {
                    throw CRDT.OperationConsistency.Error.unableToFulfill(consistency: consistency, localConfirmed: localConfirmed, required: 1, remaining: 1, obtainable: 0)
                }
                self.confirmationsRequired = 1
                // `.local` doesn't need any remote confirmation
                self.remoteConfirmationsNeeded = 0
                self.remoteFailuresAllowed = 0
            case .atLeast(let asked):
                guard asked > 0 else {
                    throw CRDT.OperationConsistency.Error.invalidNumberOfReplicasRequested(asked)
                }

                self.confirmationsRequired = asked
                self.remoteConfirmationsNeeded = localConfirmed ? asked - 1 : asked
                // This might fail when `localConfirmed` is false and there is not enough remote members to compensate
                guard self.remoteConfirmationsNeeded <= remoteMembersCount else {
                    throw CRDT.OperationConsistency.Error.unableToFulfill(consistency: consistency, localConfirmed: localConfirmed, required: asked, remaining: self.remoteConfirmationsNeeded, obtainable: remoteMembersCount)
                }

                self.remoteFailuresAllowed = remoteMembersCount - self.remoteConfirmationsNeeded
                guard self.remoteFailuresAllowed >= 0 else {
                    fatalError("Expected non-negative remoteFailuresAllowed, got \(self.remoteFailuresAllowed). This is a bug, please report.")
                }
            case .quorum:
                // Quorum by definition requires at least one remote member (see discussion in https://github.com/apple/swift-distributed-actors/issues/172)
                guard remoteMembersCount > 0 else { // FIXME: revisit, in practice this is too restrictive
                    throw CRDT.OperationConsistency.Error.remoteReplicasRequired
                }

                // When total = 4, quorum = 3. When total = 5, quorum = 3.
                let quorum = membersCount / 2 + 1
                self.confirmationsRequired = quorum

                self.remoteConfirmationsNeeded = localConfirmed ? quorum - 1 : quorum
                // This would only ever fail if `localConfirmed` is false and `remoteMembersCount` is 1 or less.
                guard self.remoteConfirmationsNeeded <= remoteMembersCount else {
                    throw CRDT.OperationConsistency.Error.unableToFulfill(consistency: consistency, localConfirmed: localConfirmed, required: quorum, remaining: self.remoteConfirmationsNeeded, obtainable: remoteMembersCount)
                }

                self.remoteFailuresAllowed = remoteMembersCount - self.remoteConfirmationsNeeded
                guard self.remoteFailuresAllowed >= 0 else {
                    fatalError("Expected non-negative remoteFailuresAllowed, got \(self.remoteFailuresAllowed). This is a bug, please report.")
                }
            case .all:
                // `.all` requires confirmation from local and all remote members.
                guard localConfirmed else {
                    throw CRDT.OperationConsistency.Error.unableToFulfill(consistency: consistency, localConfirmed: localConfirmed, required: membersCount, remaining: membersCount, obtainable: remoteMembersCount)
                }

                self.confirmationsRequired = membersCount
                self.remoteConfirmationsNeeded = remoteMembersCount
                self.remoteFailuresAllowed = 0
            }
        }

        mutating func confirm(from remoteMember: ActorRef<Message>, result: Result) {
            self.remoteConfirmationsReceived[remoteMember] = result
        }

        mutating func failed(at remoteMember: ActorRef<Message>, result: Result? = nil, error: Error? = nil) {
            self.remoteFailuresCount = self.remoteFailuresCount + 1
        }
    }
}

extension CRDT.Replicator.Shell: CustomDebugStringConvertible {
    public var debugDescription: String {
        "CRDT.Replicator.Shell(remoteReplicators: \(self.remoteReplicators)), \(self.directReplicator.debugDescription)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal "trace-logging" for debugging purposes

extension CRDT.Replicator.Shell {
    /// Optional "dump all messages" logging.
    /// Enabled by `CRDT.Replicator.Settings.traceLogLevel`
    func tracelog(_ context: ActorContext<CRDT.Replicator.Message>, _ type: TraceLogType, message: Any,
                  file: String = #file, function: String = #function, line: UInt = #line) {
        if let level = self.settings.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:\(CRDT.Replicator.name)] \(type.description): \(message)",
                metadata: self.metadata(context),
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case receive
        case addMember
        case removeMember

        var description: String {
            switch self {
            case .receive:
                return "RECV"
            case .addMember:
                return "ADD_MBR"
            case .removeMember:
                return "REM_MBR"
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Replicator path / address

extension ActorAddress {
    internal static func _crdtReplicator(on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._crdtReplicator, incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static let _crdtReplicator = try! ActorPath._system.appending(CRDT.Replicator.name)
}
