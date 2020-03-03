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
// #if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
// import Foundation
// import os.log
// import os.signpost
//
// @available(OSX 10.14, *)
// @available(iOS 10.0, *)
// @available(tvOS 10.0, *)
// @available(watchOS 3.0, *)
// public struct OSSignpostActorCRDTReplicatorInstrumentation: ActorCRDTReplicatorInstrumentation {
//
// }
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//// MARK: Instrumentation: CRDT
//
// @available(OSX 10.14, *)
// @available(iOS 10.0, *)
// @available(tvOS 10.0, *)
// @available(watchOS 3.0, *)
// extension OSSignpostActorCRDTReplicatorInstrumentation {
//
//    func dataReplicateDirectStart<Element, Result>(id: AnyObject, _ data: CRDT.ORSet<Element>, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable {
//    }
//
//    func dataReplicateDirectStop<Result>(id: AnyObject, execution: CRDT.Replicator.OperationExecution<Result>)
//        where Element: Hashable {
//    }
//
// }
// #endif
