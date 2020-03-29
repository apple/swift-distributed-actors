//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)

import SwiftyInstrumentsPackageDefinition

// package
fileprivate let packageID = "com.apple.dt.actors.ActorInstrumentsPackageDefinition"
fileprivate let packageVersion = "0.4.1"
fileprivate let packageTitle = "Actors"

// schema
fileprivate let subsystem = "com.apple.actors"

fileprivate let categoryLifecycle = "Lifecycle"
fileprivate let categoryMessages = "Messages"

// instrument
fileprivate let lifecycleInstrumentID = "com.apple.actors.instrument.lifecycles"
fileprivate let lifecycleInstrumentCategory = "Behavior"

@available(OSX 10.14, *)
@available(iOS 10.0, *)
@available(tvOS 10.0, *)
@available(watchOS 3.0, *)
public struct ActorInstrumentsPackageDefinition {
    struct Schemas {
        static let actorLifecycleInterval = PackageDefinition.OSSignpostIntervalSchema(
            id: "actor-lifecycle-interval",
            title: "Actor Lifecycle",

            subsystem: subsystem,
            category: categoryLifecycle,
            name: "Actor Lifecycle",

            startPattern: OSSignpostActorInstrumentation.actorSpawnedStartFormat,
            endPattern: OSSignpostActorInstrumentation.actorSpawnedEndFormat
        ) {
            Columns.actorAddress
            Columns.actorNode
            Columns.actorPath
            // is system
            // is user
            Columns.actorStopReason
            Columns.actorStopReasonImpact
        }

        static let actorLifecycleSpawn = PackageDefinition.OSSignpostPointSchema(
            id: "actor-lifecycle-spawn",
            title: "Actor Spawned",

            subsystem: subsystem,
            category: categoryLifecycle,
            name: "Actor Lifecycle",

            pattern: OSSignpostActorInstrumentation.actorSpawnedStartFormat
        ) {
            Columns.actorNode
            Columns.actorPath
            Columns.actorAddress
        }

        static let actorMessageReceived = PackageDefinition.OSSignpostPointSchema(
            id: "actor-message-received",
            title: "Actor Messages",

            subsystem: subsystem,
            category: categoryMessages,
            name: "Actor Messages (Received)",

            pattern: OSSignpostActorInstrumentation.actorReceivedEventPattern
        ) {
            Columns.recipientNode
            Columns.recipientPath
            Columns.recipientAddress

            Columns.senderNode
            Columns.senderPath
            Columns.senderAddress

            Columns.message
            Columns.messageType
        }

        static let actorMessageTold = PackageDefinition.OSSignpostPointSchema(
            id: "actor-message-told",
            title: "Actor Messages",

            subsystem: subsystem,
            category: categoryMessages,
            name: "Actor Messages (Told)",

            pattern: OSSignpostActorInstrumentation.actorToldEventPattern
        ) {
            Columns.recipientNode
            Columns.recipientPath
            Columns.recipientAddress

            Columns.senderNode
            Columns.senderPath
            Columns.senderAddress

            Columns.message
            Columns.messageType
        }

        static let actorAskedInterval = PackageDefinition.OSSignpostIntervalSchema(
            id: "actor-asked-interval",
            title: "Actor Asks",

            subsystem: subsystem,
            category: categoryMessages,
            name: "Actor Message (Ask)",

            startPattern: OSSignpostActorInstrumentation.actorAskedEventPattern,
            endPattern: OSSignpostActorInstrumentation.actorAskRepliedEventPattern
        ) {
            Columns.recipientNode
            Columns.recipientPath
            Columns.recipientAddress

            Columns.senderNode
            Columns.senderPath
            Columns.senderAddress

            Columns.message
            Columns.messageType

            Columns.error
            Columns.errorType
        }
    }

    struct Columns {
        static let actorNode = Column(
            mnemonic: "actor-node",
            title: "Actor Node",
            type: .string,
            expression: .mnemonic("node")
        )

        static let actorPath = Column(
            mnemonic: "actor-path",
            title: "Actor Path",
            type: .string,
            expression: .mnemonic("path")
        )

        static let actorAddress = Column(
            mnemonic: "actor-address",
            title: "Actor Address",
            type: .string,
            expression: "(str-cat ?node ?path)"
        )

        static let actorStopReason = Column(
            mnemonic: "actor-stop-reason",
            title: "Stop Reason",
            type: .string,
            expression: .mnemonic("reason")
        )

        /// If the reason we stopped is `stop` it was graceful, otherwise it was a crash
        static let actorStopReasonImpact = Column(
            mnemonic: "actor-stop-reason-impact",
            title: "Stop Reason (Impact)",
            type: .string,
            expression:
            """
            (if (eq ?reason "stop") then "Low" else "High")
            """
        )

        static let recipientNode = Column(
            mnemonic: "actor-recipient-node",
            title: "Recipient Node",
            type: .string,
            expression: "?recipient-node"
        )
        static let recipientPath = Column(
            mnemonic: "actor-recipient-path",
            title: "Recipient Path",
            type: .string,
            expression: "?recipient-path"
        )
        static let recipientAddress = Column(
            mnemonic: "actor-recipient-address",
            title: "Recipient Address",
            type: .string,
            expression: "(str-cat ?recipient-node ?recipient-path)"
        )

        static let senderNode = Column(
            mnemonic: "actor-sender-node",
            title: "Sender Node",
            type: .string,
            expression: "?sender-node"
        )
        static let senderPath = Column(
            mnemonic: "actor-sender-path",
            title: "Sender Path",
            type: .string,
            expression: "?sender-path"
        )
        static let senderAddress = Column(
            mnemonic: "actor-sender-address",
            title: "Sender Address",
            type: .string,
            expression: "(str-cat ?sender-node ?sender-path)"
        )

        static let message = Column(
            mnemonic: "actor-message",
            title: "Message",
            type: .string,
            expression: "?message"
        )
        static let messageType = Column(
            mnemonic: "actor-message-type",
            title: "Message Type",
            type: .string,
            expression: "?message-type"
        )

        static let error = Column(
            mnemonic: "actor-error",
            title: "Error",
            type: .string,
            expression: "?error"
        )
        static let errorType = Column(
            mnemonic: "actor-error-type",
            title: "Error Type",
            type: .string,
            expression: "?error-type"
        )
    }

    public init() {}

    public var packageDefinition: PackageDefinition {
        // TODO: move into Instrument once able to; limitation:
        // error: closure containing a declaration cannot be used with function builder 'PackageDefinitionBuilder'
        //            let tableActorLifecycleIntervals = Schemas.actorLifecycleInterval.createTable()
        //            ^
        let tableActorLifecycleIntervals = Schemas.actorLifecycleInterval.createTable()
        let tableActorLifecycleSpawns = Schemas.actorLifecycleSpawn.createTable()

        return PackageDefinition(
            id: packageID,
            version: packageVersion,
            title: packageTitle,
            owner: Owner(name: "Konrad 'ktoso' Malawski", email: "ktoso@apple.com")
        ) {
            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: Schemas

            // lifecycle
            // - spawn -> (stop/crash)
            Schemas.actorLifecycleInterval
            Schemas.actorLifecycleSpawn

            // messages
            // - received
            Schemas.actorMessageReceived
            // - told
            Schemas.actorMessageTold
            // - asked
            Schemas.actorAskedInterval

            // ==== ----------------------------------------------------------------------------------------------------
            // MARK: Instruments

            Instrument(
                id: lifecycleInstrumentID,
                title: "Actor Lifecycle",
                category: lifecycleInstrumentCategory,
                purpose: "Monitor lifecycle of actors (start, stop, fail, restart etc.)",
                icon: "Activity Monitor"
            ) {
                // TODO: do this once functionBuilders can support it
//                let tableActorLifecycleIntervals = Schemas.actorLifecycleInterval.createTable()
//                let tableActorLifecycleSpawns = Schemas.actorLifecycleSpawn.createTable()

                tableActorLifecycleIntervals
                tableActorLifecycleSpawns

                Instrument.Graph(title: "Lifecycles") {
                    Instrument.Graph.Lane(
                        title: "Spawns Lane",
                        table: tableActorLifecycleSpawns
                    ) {
                        Instrument.Graph.PlotTemplate(
                            instanceBy: "actor-path", // TODO: more well typed
                            valueFrom: "actor-path"
                        )
                    }

                    Instrument.Graph.Lane(
                            title: "Spawns Lane",
                            table: tableActorLifecycleSpawns
                    ) {
                        Instrument.Graph.PlotTemplate(
                                instanceBy: "actor-path", // TODO: more well typed
                                labelFormat: "%s",
                                valueFrom: "actor-path",
                                colorFrom: "actor-stop-reason-impact",
                                labelFrom: "actor-path"
                        )
                    }
                }

                Instrument.List(
                    title: "Spawns",
                    table: tableActorLifecycleSpawns
                ) {
                    [
                        "start",
                        "duration",
                        "actor-node",
                        "actor-path",
                    ]
                }

                Instrument.List(
                    title: "Lifetimes",
                    table: tableActorLifecycleIntervals
                ) {
                    [
                        "start",
                        "duration",
                        "actor-node",
                        "actor-path",
                    ]
                }
            }
        }
    }
}

#endif
