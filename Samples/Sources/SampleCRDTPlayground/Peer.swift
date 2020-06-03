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

import DistributedActors

extension CRDTPlayground {

    func peer(
        writeConsistency: CRDT.OperationConsistency,
        stopWhen: @escaping (CRDT.ORSet<String>) -> Bool
    ) -> Behavior<String> {
        .setup { context in
            context.log.info("Ready: \(context.name)")

            let set: CRDT.ActorOwned<CRDT.ORSet<String>> = CRDT.ORSet.makeOwned(by: context, id: "set")

            var loggedComplete = false
            let actorStart = Deadline.now().uptimeNanoseconds

            set.onUpdate { id, state in
                // context.log.info("Updated [\(id)], state: \(state.elements)")
                if !loggedComplete && stopWhen(state) {
                    let end = Deadline.now().uptimeNanoseconds
                    loggedComplete = true
                    context.log.notice("Completed [\(id)]: \(TimeAmount.nanoseconds(end - actorStart).prettyDescription)")
                }
            }


            return .receiveMessage { element in
                let startWrite = Deadline.now().uptimeNanoseconds
                set.insert(element, writeConsistency: writeConsistency, timeout: .seconds(3)).onComplete { _ in
                    let endWrite = Deadline.now().uptimeNanoseconds
                    context.log.info(
                        """
                        Completed write [\(element)] @ \(writeConsistency)\
                        : \(set.lastObservedValue), \
                        took: \(TimeAmount.nanoseconds(endWrite - startWrite).prettyDescription)
                        """)
                }

                return .same
            }
        }
    }
}
