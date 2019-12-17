// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

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

import DistributedActors
import class NIO.EventLoopFuture

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated TestActorable messages 

/// DO NOT EDIT: Generated TestActorable messages
extension TestActorable {

    public enum Message { 
        case ping 
        case greet(name: String) 
        case greetUnderscoreParam(String) 
        case greet2(name: String, surname: String) 
        case throwing 
        case passMyself(someone: ActorRef<Actor<TestActorable>>) 
        case _ignoreInGenActor 
        case parameterNames(first: String) 
        case greetReplyToActorRef(name: String, replyTo: ActorRef<String>) 
        case greetReplyToActor(name: String, replyTo: Actor<TestActorable>) 
        case greetReplyToReturnStrict(name: String, _replyTo: ActorRef<String>) 
        case greetReplyToReturnStrictThrowing(name: String, _replyTo: ActorRef<Result<String, Error>>) 
        case greetReplyToReturnNIOFuture(name: String, _replyTo: ActorRef<Result<String, Error>>) 
        case becomeStopped 
        case contextSpawnExample 
        case timer 
    }
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated TestActorable behavior

extension TestActorable {

    public static func makeBehavior(instance: TestActorable) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<TestActorable>.Context(underlying: _context)
            var instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .ping:
                    instance.ping()
 
                case .greet(let name):
                    instance.greet(name: name)
 
                case .greetUnderscoreParam(let name):
                    instance.greetUnderscoreParam(name)
 
                case .greet2(let name, let surname):
                    instance.greet2(name: name, surname: surname)
 
                case .throwing:
                    try instance.throwing()
 
                case .passMyself(let someone):
                    instance.passMyself(someone: someone)
 
                case ._ignoreInGenActor:
                    try instance._ignoreInGenActor()
 
                case .parameterNames(let second):
                    instance.parameterNames(first: second)
 
                case .greetReplyToActorRef(let name, let replyTo):
                    instance.greetReplyToActorRef(name: name, replyTo: replyTo)
 
                case .greetReplyToActor(let name, let replyTo):
                    instance.greetReplyToActor(name: name, replyTo: replyTo)
 
                case .greetReplyToReturnStrict(let name, let _replyTo):
                    let result = instance.greetReplyToReturnStrict(name: name)
                    _replyTo.tell(result)
 
                case .greetReplyToReturnStrictThrowing(let name, let _replyTo):
                    do {
                    let result = try instance.greetReplyToReturnStrictThrowing(name: name)
                    _replyTo.tell(.success(result))
                    } catch {
                        context.log.warning("Error thrown while handling [\(message)], error: \(error)")
                        _replyTo.tell(.failure(error))
                    }
 
                case .greetReplyToReturnNIOFuture(let name, let _replyTo):
                    instance.greetReplyToReturnNIOFuture(name: name)
                                    .whenComplete { res in _replyTo.tell(res) } 
                case .becomeStopped:
                    return /*become*/ instance.becomeStopped()
 
                case .contextSpawnExample:
                    try instance.contextSpawnExample()
 
                case .timer:
                    instance.timer()
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<TestActorable>.Context(underlying: _context)

                switch signal {
                case is Signals.PostStop: 
                    instance.postStop(context: context)
                    return .same
                case let terminated as Signals.Terminated:
                    switch try instance.receiveTerminated(context: context, terminated: terminated) {
                    case .unhandled: 
                        return .unhandled
                    case .stop: 
                        return .stop
                    case .ignore: 
                        return .same
                    }
                default:
                    try instance.receiveSignal(context: context, signal: signal)
                    return .same
                }
            }
        }
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for TestActorable

extension Actor where A.Message == TestActorable.Message {

    public func ping() {
        self.ref.tell(.ping)
    }
 

    public func greet(name: String) {
        self.ref.tell(.greet(name: name))
    }
 

    public func greetUnderscoreParam(_ name: String) {
        self.ref.tell(.greetUnderscoreParam(name))
    }
 

    public func greet2(name: String, surname: String) {
        self.ref.tell(.greet2(name: name, surname: surname))
    }
 

    public func throwing() {
        self.ref.tell(.throwing)
    }
 

     func passMyself(someone: ActorRef<Actor<TestActorable>>) {
        self.ref.tell(.passMyself(someone: someone))
    }
 

    public func _ignoreInGenActor() {
        self.ref.tell(._ignoreInGenActor)
    }
 

     func parameterNames(first second: String) {
        self.ref.tell(.parameterNames(first: second))
    }
 

    public func greetReplyToActorRef(name: String, replyTo: ActorRef<String>) {
        self.ref.tell(.greetReplyToActorRef(name: name, replyTo: replyTo))
    }
 

    public func greetReplyToActor(name: String, replyTo: Actor<TestActorable>) {
        self.ref.tell(.greetReplyToActor(name: name, replyTo: replyTo))
    }
 

    public func greetReplyToReturnStrict(name: String) -> Reply<String> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: String.self, timeout: .effectivelyInfinite) { _replyTo in
                .greetReplyToReturnStrict(name: name, _replyTo: _replyTo)}.nioFuture
        )
    }
 

    public func greetReplyToReturnStrictThrowing(name: String) -> Reply<String> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: Result<String, Error>.self, timeout: .effectivelyInfinite) { _replyTo in
                .greetReplyToReturnStrictThrowing(name: name, _replyTo: _replyTo)}.nioFuture.flatMapThrowing { result in
                switch result {
                case .success(let res): return res
                case .failure(let err): throw err
                }
            }
        )
    }
 

    public func greetReplyToReturnNIOFuture(name: String) -> Reply<String> {
        // TODO: FIXME perhaps timeout should be taken from context
        Reply(nioFuture:
            self.ref.ask(for: Result<String, Error>.self, timeout: .effectivelyInfinite) { _replyTo in
                .greetReplyToReturnNIOFuture(name: name, _replyTo: _replyTo)}.nioFuture.flatMapThrowing { result in
                switch result {
                case .success(let res): return res
                case .failure(let err): throw err
                }
            }
        )
    }
 

     func becomeStopped() {
        self.ref.tell(.becomeStopped)
    }
 

     func contextSpawnExample() {
        self.ref.tell(.contextSpawnExample)
    }
 

     func timer() {
        self.ref.tell(.timer)
    }
 

}
