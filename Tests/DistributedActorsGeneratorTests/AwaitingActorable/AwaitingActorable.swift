////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
//import DistributedActors
//import _Distributed
//import NIO
//
//extension AwaitingActorable.Message: NonTransportableActorMessage {}
//
//public distributed actor AwaitingActorable {
//
//    func awaitOnAFuture(f: EventLoopFuture<String>, replyTo: ActorRef<Result<String, AwaitingActorableError>>) {
//        context.awaitResult(of: f, timeout: .effectivelyInfinite) { result in
//            replyTo.tell(result.mapError { error in AwaitingActorableError.error(error) })
//        }
//    }
//
//    func onResultAsyncExample(f: EventLoopFuture<String>, replyTo: ActorRef<Result<String, AwaitingActorableError>>) {
//        context.onResultAsync(of: f, timeout: .effectivelyInfinite) { result in
//            replyTo.tell(result.mapError { error in AwaitingActorableError.error(error) })
//        }
//    }
//}
//
//// should not accidentally try to make this actorable
//public struct ExampleModel {
//    public struct ExampleData {}
//}
//
//public enum AwaitingActorableError: Error, NonTransportableActorMessage {
//    case error(Error)
//}
