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

// ==== ------------------------------------------------------------------------------------------------------------

// MARK: ReplicatorShell

extension CRDT.Replicator {
    internal struct Shell {
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

        let replicator: Instance

        var settings: Settings {
            return self.replicator.settings
        }

        init(_ replicator: Instance) {
            self.replicator = replicator
        }

        init(settings: Settings) {
            self.init(Instance(settings))
        }

        var behavior: Behavior<Message> {
            return .receive { context, message in
                switch message {
                case .localCommand(let command):
                    self.receiveLocalCommand(context, command: command)
                    return .same
                case .remoteCommand(let command):
                    self.receiveRemoteCommand(context, command: command)
                    return .same
                }
            }
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Local command

        private func receiveLocalCommand(_ context: ActorContext<Message>, command: LocalCommand) {
            switch command {
            case .register(let ownerRef, let id, let data, let replyTo):
                self.handleLocalRegisterCommand(context, ownerRef: ownerRef, id: id, data: data, replyTo: replyTo)
            case .write(let id, let data, let consistency, let replyTo):
                self.handleLocalWriteCommand(context, id, data, consistency: consistency, replyTo: replyTo)
            case .read(let id, let consistency, let replyTo):
                self.handleLocalReadCommand(context, id, consistency: consistency, replyTo: replyTo)
            case .delete(let id, let consistency, let replyTo):
                self.handleLocalDeleteCommand(context, id, consistency: consistency, replyTo: replyTo)
            }
        }

        private func handleLocalRegisterCommand(_ context: ActorContext<Message>, ownerRef: ActorRef<OwnerMessage>, id: Identity, data: AnyStateBasedCRDT, replyTo: ActorRef<LocalRegisterResult>?) {
            // Register the owner first
            switch self.replicator.registerOwner(dataId: id, owner: ownerRef) {
            case .registered:
                // Then write the full CRDT so it is ready to be read
                switch self.replicator.write(id, data, deltaMerge: false) {
                case .applied:
                    replyTo?.tell(.success)
                case .inputAndStoredDataTypeMismatch(let stored):
                    replyTo?.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored)))
                case .unsupportedCRDT:
                    replyTo?.tell(.failed(.unsupportedCRDT))
                }
            }

            // We are initializing local store with the CRDT essentially, so there is no need to send `.updated` to
            // owners or propagate change to the cluster (i.e., local only).
        }

        private func handleLocalWriteCommand(_ context: ActorContext<Message>, _ id: Identity, _ data: AnyStateBasedCRDT, consistency: OperationConsistency, replyTo: ActorRef<LocalWriteResult>) {
            switch self.replicator.write(id, data, deltaMerge: true) {
            case .applied(let updatedData):
                // Propagate change to the cluster if needed
                switch consistency {
                case .local: // We are done
                    replyTo.tell(.success)
                case .atLeast, .quorum, .all:
                    // TODO: send update to a subset of remote replicators based on consistency then send reply
                    // if CvRDT send full CRDT (`RemoteCommand.write`); if DeltaCRDT send data.delta (not replicator's
                    // delta, but the received CRDT's) (`ClusterCommand.writeDelta`)
                    // if CRDT is new locally, send full regardless if it is a DeltaCRDT. the id might be unknown to
                    // remote replicator as well and sending just the delta would not work in that case.
                    replyTo.tell(.success)
                }

                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .inputAndStoredDataTypeMismatch(let stored):
                replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored)))
            case .unsupportedCRDT:
                replyTo.tell(.failed(.unsupportedCRDT))
            }
        }

        private func handleLocalReadCommand(_ context: ActorContext<Message>, _ id: Identity, consistency: OperationConsistency, replyTo: ActorRef<LocalReadResult>) {
            switch self.replicator.read(id) {
            case .data(let stored):
                switch consistency {
                case .local:
                    replyTo.tell(.success(stored.underlying))
                case .atLeast, .quorum, .all:
                    // TODO: read (RemoteCommand.read) from a subset of remote replicators based on consistency then send reply
                    // remote replicator sends full CRDT

                    // TODO: local merge of all responses
                    // TODO: write CRDT to dataStore
                    // TODO: insert real implementation then delete this code
                    replyTo.tell(.success(stored.underlying))

                    // Notify owners about the change
                    // TODO: this notifies owners even when the CRDT hasn't changed
                    self.notifyOwnersOnUpdate(context, id, stored)
                }
            case .notFound:
                replyTo.tell(.failed(.notFound))
            }
        }

        private func handleLocalDeleteCommand(_ context: ActorContext<Message>, _ id: Identity, consistency: OperationConsistency, replyTo: ActorRef<LocalDeleteResult>) {
            switch self.replicator.delete(id) {
            case .applied:
                // Propagate change to the cluster if needed
                switch consistency {
                case .local:
                    replyTo.tell(.success)
                case .atLeast, .quorum, .all:
                    // TODO: send delete (RemoteCommand.delete) to a subset of remote replicators based on consistency then send reply
                    replyTo.tell(.success)
                }

                self.notifyOwnersOnDelete(context, id)
            }
        }

        // ==== ------------------------------------------------------------------------------------------------------------
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

        private func handleRemoteWriteCommand(_ context: ActorContext<Message>, _ id: Identity, _ data: AnyStateBasedCRDT, replyTo: ActorRef<RemoteWriteResult>) {
            switch self.replicator.write(id, data, deltaMerge: false) {
            case .applied(let updatedData):
                replyTo.tell(.success)
                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .inputAndStoredDataTypeMismatch(let stored):
                replyTo.tell(.failed(.inputAndStoredDataTypeMismatch(stored: stored)))
            case .unsupportedCRDT:
                replyTo.tell(.failed(.unsupportedCRDT))
            }
        }

        private func handleRemoteWriteDeltaCommand(_ context: ActorContext<Message>, _ id: Identity, _ delta: AnyStateBasedCRDT, replyTo: ActorRef<RemoteWriteResult>) {
            switch self.replicator.writeDelta(id, delta) {
            case .applied(let updatedData):
                replyTo.tell(.success)
                self.notifyOwnersOnUpdate(context, id, updatedData)
            case .missingCRDTForDelta:
                replyTo.tell(.failed(.missingCRDTForDelta))
            case .incorrectDeltaType(let expected):
                replyTo.tell(.failed(.incorrectDeltaType(expected: expected)))
            case .cannotWriteDeltaForNonDeltaCRDT:
                replyTo.tell(.failed(.cannotWriteDeltaForNonDeltaCRDT))
            }
        }

        private func handleRemoteReadCommand(_ context: ActorContext<Message>, _ id: Identity, replyTo: ActorRef<RemoteReadResult>) {
            switch self.replicator.read(id) {
            case .data(let stored):
                // Send full CRDT back
                replyTo.tell(.success(stored))
            case .notFound:
                replyTo.tell(.failed(.notFound))
            }

            // Read-only command; nothing has changed so no need to notify anyone
        }

        private func handleRemoteDeleteCommand(_ context: ActorContext<Message>, _ id: Identity, replyTo: ActorRef<RemoteDeleteResult>) {
            switch self.replicator.delete(id) {
            case .applied:
                replyTo.tell(.success)
                self.notifyOwnersOnDelete(context, id)
            }
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Notify owners

        private func notifyOwnersOnUpdate(_: ActorContext<Message>, _ id: Identity, _ data: AnyStateBasedCRDT) {
            if let owners = self.replicator.owners(for: id) {
                let message: OwnerMessage = .updated(data.underlying)
                for owner in owners {
                    owner.tell(message)
                }
            }
        }

        private func notifyOwnersOnDelete(_: ActorContext<Message>, _ id: Identity) {
            if let owners = self.replicator.owners(for: id) {
                for owner in owners {
                    owner.tell(.deleted)
                }
            }
        }
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
                "[tracelog:replicator] \(type.description): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case receive

        var description: String {
            switch self {
            case .receive:
                return "RECV"
            }
        }
    }
}
