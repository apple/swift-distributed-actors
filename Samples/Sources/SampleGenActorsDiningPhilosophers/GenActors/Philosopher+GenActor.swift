// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated Philosopher messages 

/// DO NOT EDIT: Generated Philosopher messages
extension Philosopher {

    public enum Message: ActorMessage { 
        case attemptToTakeForks 
        case stopEating 
    }
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated Philosopher behavior

extension Philosopher {

    public static func makeBehavior(instance: Philosopher) -> Behavior<Message> {
        return .setup { _context in
            let context = Actor<Philosopher>.Context(underlying: _context)
            let instance = instance

            /* await */ instance.preStart(context: context)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .attemptToTakeForks:
                    instance.attemptToTakeForks()
 
                case .stopEating:
                    instance.stopEating()
 
                
                }
                return .same
            }.receiveSignal { _context, signal in 
                let context = Actor<Philosopher>.Context(underlying: _context)

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
// MARK: Extend Actor for Philosopher

extension Actor where A.Message == Philosopher.Message {

     func attemptToTakeForks() {
        self.ref.tell(.attemptToTakeForks)
    }
 

     func stopEating() {
        self.ref.tell(.stopEating)
    }
 

}
