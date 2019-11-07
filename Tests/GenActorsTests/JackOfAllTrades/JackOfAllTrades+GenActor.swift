// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

import DistributedActors
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated JackOfAllTrades messages 

/// DO NOT EDIT: Generated JackOfAllTrades messages
extension JackOfAllTrades {
    public enum Message { 
        case hello(replyTo: ActorRef<String>) 
        case ticketing(/*TODO: MODULE.*/GeneratedActor.Messages.Ticketing) 
        case parking(/*TODO: MODULE.*/GeneratedActor.Messages.Parking) 
    }

    
    /// Performs boxing of GeneratedActor.Messages.Ticketing messages such that they can be received by Actor<JackOfAllTrades>
    public static func _boxTicketing(_ message: GeneratedActor.Messages.Ticketing) -> JackOfAllTrades.Message {
        .ticketing(message)
    } 
    
    /// Performs boxing of GeneratedActor.Messages.Parking messages such that they can be received by Actor<JackOfAllTrades>
    public static func _boxParking(_ message: GeneratedActor.Messages.Parking) -> JackOfAllTrades.Message {
        .parking(message)
    } 
    
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated JackOfAllTrades behavior

extension JackOfAllTrades {

    public static func makeBehavior(instance: JackOfAllTrades) -> Behavior<Message> {
        return .setup { context in
            var ctx = Actor<JackOfAllTrades>.Context(underlying: context)
            var instance = instance // TODO only var if any of the methods are mutating

            /* await */ instance.preStart(context: ctx)

            return Behavior<Message>.receiveMessage { message in
                switch message { 
                
                case .hello(let replyTo):
                    instance.hello(replyTo: replyTo) 
                
                case .ticketing(.makeTicket):
                    instance.makeTicket() 
                case .parking(.park):
                    instance.park() 
                }
                return .same
            }.receiveSignal { context, signal in 
                if signal is Signals.PostStop {
                    var ctx = Actor<JackOfAllTrades>.Context(underlying: context)
                    instance.postStop(context: ctx)
                }
                return .same
            }
        }
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Extend Actor for JackOfAllTrades

extension Actor where A.Message == JackOfAllTrades.Message {
    
    public func hello(replyTo: ActorRef<String>) { 
        self.ref.tell(.hello(replyTo: replyTo))
    } 
    
}
