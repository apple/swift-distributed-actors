// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====



import DistributedActors
import NIO
import XPCActorServiceAPI

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated GreetingsServiceImpl messages 

/// DO NOT EDIT: Generated GreetingsServiceImpl messages
extension GreetingsServiceImpl {

    public enum Message: ActorMessage { 
        case greetingsService(/*TODO: MODULE.*/GeneratedActor.Messages.GreetingsService) 
    }
    
    /// Performs boxing of GeneratedActor.Messages.GreetingsService messages such that they can be received by Actor<GreetingsServiceImpl>
    public static func _boxGreetingsService(_ message: GeneratedActor.Messages.GreetingsService) -> GreetingsServiceImpl.Message {
        .greetingsService(message)
    } 
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated GreetingsServiceImpl behavior

extension GreetingsServiceImpl {

    public static func makeBehavior(instance: GreetingsServiceImpl) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<GreetingsServiceImpl>.Context(underlying: _context)
            let instance = instance

            instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                
                case .greetingsService(.logGreeting(let name)):
                    try instance.logGreeting(name: name)
 
                case .greetingsService(.greet(let name, let _replyTo)):
                    do {
                    let result = try instance.greet(name: name)
                    _replyTo.tell(.success(result))
                    } catch {
                        context.log.warning("Error thrown while handling [\(message)], error: \(error)")
                        _replyTo.tell(.failure(ErrorEnvelope(error)))
                    }
 
                case .greetingsService(.fatalCrash):
                    instance.fatalCrash()
 
                case .greetingsService(.greetDirect(let who)):
                    instance.greetDirect(who: who)
 
                case .greetingsService(.greetFuture(let name, let _replyTo)):
                    instance.greetFuture(name: name)
                        .whenComplete { res in
                            switch res {
                            case .success(let value):
                                _replyTo.tell(.success(value))
                            case .failure(let error):
                                _replyTo.tell(.failure(ErrorEnvelope(error)))
                            }
                        } 
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<GreetingsServiceImpl>.Context(underlying: _context)

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
// MARK: Extend Actor for GreetingsServiceImpl

extension Actor where A.Message == GreetingsServiceImpl.Message {

}
