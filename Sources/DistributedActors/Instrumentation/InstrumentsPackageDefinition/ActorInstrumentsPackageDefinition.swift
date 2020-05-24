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

extension Column {
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

    static let askQuestion = Column(
        mnemonic: "actor-ask-question",
        title: "Question",
        type: .string,
        expression: "?question"
    )
    static let askQuestionType = Column(
        mnemonic: "actor-ask-question-type",
        title: "Question Type",
        type: .string,
        expression: "?question-type"
    )
    static let askAnswer = Column(
        mnemonic: "actor-ask-answer",
        title: "Answer",
        type: .string,
        expression: "?answer"
    )
    static let askAnswerType = Column(
        mnemonic: "actor-ask-answer-type",
        title: "Answer Type",
        type: .string,
        expression: "?answer-type"
    )
    static let askError = Column(
        mnemonic: "actor-ask-answer",
        title: "Error",
        type: .string,
        expression: "?error"
    )
    static let askErrorType = Column(
        mnemonic: "actor-ask-error-type",
        title: "Error Type",
        type: .string,
        expression: "?error-type"
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
            Column.actorAddress
            Column.actorNode
            Column.actorPath
            // is system
            // is user
            Column.actorStopReason
            Column.actorStopReasonImpact
        }

        static let actorLifecycleSpawn = PackageDefinition.OSSignpostPointSchema(
            id: "actor-lifecycle-spawn",
            title: "Actor Spawned",

            subsystem: subsystem,
            category: categoryLifecycle,
            name: "Actor Lifecycle",

            pattern: OSSignpostActorInstrumentation.actorSpawnedStartFormat
        ) {
            Column.actorNode
            Column.actorPath
            Column.actorAddress
        }

        static let actorMessageReceived = PackageDefinition.OSSignpostPointSchema(
            id: "actor-message-received",
            title: "Actor Messages",

            subsystem: subsystem,
            category: categoryMessages,
            name: "Actor Messages (Received)",

            pattern: OSSignpostActorInstrumentation.actorReceivedEventPattern
        ) {
            Column.recipientNode
            Column.recipientPath
            Column.recipientAddress

            Column.senderNode
            Column.senderPath
            Column.senderAddress

            Column.message
            Column.messageType
        }

        static let actorMessageTold = PackageDefinition.OSSignpostPointSchema(
            id: "actor-message-told",
            title: "Actor Messages",

            subsystem: subsystem,
            category: categoryMessages,
            name: "Actor Messages (Told)",

            pattern: OSSignpostActorInstrumentation.actorToldEventPattern
        ) {
            Column.recipientNode
            Column.recipientPath
            Column.recipientAddress

            Column.senderNode
            Column.senderPath
            Column.senderAddress

            Column.message
            Column.messageType
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
            Column.recipientNode
            Column.recipientPath
            Column.recipientAddress

            Column.senderNode
            Column.senderPath
            Column.senderAddress

            Column.message
            Column.messageType

            Column.error
            Column.errorType
        }
    }

    public init() {}

    public var packageDefinition: PackageDefinition {
        // TODO: move into Instrument once able to; limitation:
        // error: closure containing a declaration cannot be used with function builder 'PackageDefinitionBuilder'
        //            let tableActorLifecycleIntervals = Schemas.actorLifecycleInterval.createTable()
        //            ^
        let tableActorLifecycleIntervals = Schemas.actorLifecycleInterval.createTable()
        let tableActorLifecycleSpawns = Schemas.actorLifecycleSpawn.createTable()
        let tableActorMessageReceived = Instrument.CreateTable(Schemas.actorMessageReceived) {
            TableAttribute(name: "target-recipient", value: Mnemonic("target-pid"))
        }
        let tableActorMessageTold = Instrument.CreateTable(Schemas.actorMessageTold)
        let tableActorAskedInterval = Instrument.CreateTable(Schemas.actorAskedInterval)

        return PackageDefinition(
            id: packageID,
            version: packageVersion,
            title: packageTitle,
            owner: Owner(name: "Konrad 'ktoso' Malawski", email: "ktoso@apple.com")
        ) {
            // ==== Schemas --------------------------------------------------------------------------------------------

            // lifecycle
            Schemas.actorLifecycleInterval
            Schemas.actorLifecycleSpawn

            // messages (tell)
            Schemas.actorMessageReceived
            Schemas.actorMessageTold

            // messages (ask)
            Schemas.actorAskedInterval

            // ==== Instruments ----------------------------------------------------------------------------------------

            Instrument(
                id: lifecycleInstrumentID,
                title: "Actor Lifecycle",
                category: lifecycleInstrumentCategory,
                purpose: "Monitor lifecycle of actors (start, stop, fail, restart etc.)",
                icon: "Activity Monitor"
            ) {
                // --- tables ---
                tableActorLifecycleIntervals
                tableActorLifecycleSpawns

                Graph(title: "Lifecycles") {
                    Graph.Lane(
                        title: "Spawns Lane",
                        table: tableActorLifecycleSpawns
                    ) {
                        Graph.PlotTemplate(
                            instanceBy: "actor-path", // TODO: more well typed
                            valueFrom: "actor-path"
                        )
                    }

                    Graph.Lane(
                        title: "Spawns Lane",
                        table: tableActorLifecycleSpawns
                    ) {
                        Graph.PlotTemplate(
                            instanceBy: Column.actorPath, // TODO: more well typed
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
                    "start"
                    "duration"
                    Column.actorNode
                    Column.actorPath
                }

                Instrument.List(
                    title: "Lifetimes",
                    table: tableActorLifecycleIntervals
                ) {
                    "start"
                    "duration"
                    Column.actorNode
                    Column.actorPath
                }
            }

            Instrument(
                id: "com.apple.actors.instrument.messages.received",
                title: "Actor Messages Received",
                category: "Behavior",
                purpose: "Marks points in time where messages are received",
                icon: "Network"
            ) {
                Instrument.ImportParameter(fromScope: "trace", name: "target-pid")

                // --- tables ---
                tableActorMessageReceived

                Graph(title: "Received") {
                    Graph.Lane(title: "Received", table: tableActorMessageReceived) {
                        Graph.PlotTemplate(
                            instanceBy: Column.recipientPath,
                            labelFormat: "%s",
                            valueFrom: Column.messageType,
                            labelFrom: Column.recipientPath
                        )
                    }
                }

                Instrument.List(
                    title: "List: Messages (Received)",
                    table: tableActorMessageReceived
                ) {
                    "timestamp"
                    Column.senderNode
                    Column.senderPath
                    Column.recipientNode
                    Column.recipientPath
                    Column.message
                    Column.messageType
                }
            }

            Instrument(
                id: "com.apple.actors.instrument.messages.told",
                title: "Actor Messages Told",
                category: "Behavior",
                purpose: "Points in time where actor messages are told (sent)",
                icon: "Network"
            ) {
                // --- tables ---
                tableActorMessageTold

                Graph(title: "Messages: Told") {
                    Graph.Lane(title: "Told", table: tableActorMessageTold) {
                        Graph.PlotTemplate(
                            instanceBy: .recipientPath,
                            labelFormat: "%s",
                            valueFrom: .messageType,
                            labelFrom: .recipientPath
                        )

                        // TODO: unlock once we have sender propagation
//                        Graph.PlotTemplate(
//                            instanceBy: Column.senderPath,
//                            labelFormat: "%s",
//                            valueFrom: Column.messageType,
//                            valueFrom: Column.senderPath
//                        )
                    }
                }

                Instrument.List(title: "List: Messages (Told)", table: tableActorMessageTold) {
                    "timestamp"
                    Column.senderNode
                    Column.senderPath
                    Column.recipientNode
                    Column.recipientPath
                    Column.message
                    Column.messageType
                }
            }

            Instrument(
                id: "com.apple.actors.instrument.messages.asked",
                title: "Actor Messages Asked",
                category: "Behavior",
                purpose: "Analyze ask (request/response) interactions",
                icon: "Network"
            ) {
                tableActorAskedInterval

                Graph(title: "Messages Asked") {
                    Graph.Lane(title: "Asked", table: tableActorAskedInterval) {
                        Graph.Plot(valueFrom: "duration", labelFrom: Column.askQuestion)
                        // TODO: for the plot, severity from if it was a timeout or not
                    }
                }

                let askedList = List(title: "List: Messages (Asked)", table: tableActorAskedInterval) {
                    "start"
                    "duration"
                    Column.senderNode
                    Column.senderPath
                    Column.recipientNode
                    Column.recipientPath
                    Column.askQuestionType
                    Column.askQuestion
                    Column.askAnswer
                    Column.askAnswerType
                    Column.error
                    Column.errorType
                }
                askedList

                Aggregation(
                    title: "Summary: By Message Type",
                    table: tableActorAskedInterval,
                    hierarchy: [
                        .column(.askQuestionType),
                    ],
//                    <hierarchy>
//                <level>
//                <column>actor-ask-question-type</column>
//                </level>
//                </hierarchy>
                    visitOnFocus: askedList,
                    columns: [
                        .count(.senderNode),
                    ]
                )
            }
        }
    }
}

#endif
