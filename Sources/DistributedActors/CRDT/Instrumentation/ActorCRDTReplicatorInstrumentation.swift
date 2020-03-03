////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: ActorMailboxInstrumentation
//
//// TODO: all these to accept trace context or something similar
// public protocol ActorCRDTReplicatorInstrumentation {
//
//    func dataReplicateDirectStart<Element, Result>(id: AnyObject, _ data: CRDT.ORSet<Element>, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable
//    func dataReplicateDirectStop<Result>(id: AnyObject, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable
// }
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: Noop ActorCRDTReplicatorInstrumentation
//
// struct ActorCRDTReplicatorInstrumentation: ActorCRDTReplicatorInstrumentation {
//
//    func dataReplicateDirectStart<Element, Result>(id: AnyObject, _ data: CRDT.ORSet<Element>, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable {
//    }
//
//    func dataReplicateDirectStop<Result>(id: AnyObject, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable {
//    }
// }
