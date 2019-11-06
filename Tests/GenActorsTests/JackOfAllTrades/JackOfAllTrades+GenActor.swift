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
        case parking(/*TODO: MODULE.*/GeneratedActor.Messages.Parking) 
        case ticketing(/*TODO: MODULE.*/GeneratedActor.Messages.Ticketing) 
    }

    
    /// Performs boxing of GeneratedActor.Messages.Parking messages such that they can be received by Actor<JackOfAllTrades>
    public static func _boxParking(_ message: GeneratedActor.Messages.Parking) -> JackOfAllTrades.Message {
        .parking(message)
    } 
    
    /// Performs boxing of GeneratedActor.Messages.Ticketing messages such that they can be received by Actor<JackOfAllTrades>
    public static func _boxTicketing(_ message: GeneratedActor.Messages.Ticketing) -> JackOfAllTrades.Message {
        .ticketing(message)
    } 
    
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated JackOfAllTrades behavior

extension JackOfAllTrades {

    // TODO: if overriden don't generate this?
    // public typealias Message = Actor<JackOfAllTrades>.JackOfAllTradesMessage

    public static func makeBehavior(instance: JackOfAllTrades) -> Behavior<Message> {
        return .setup { context in
            var instance = instance // TODO only var if any of the methods are mutating

            // /* await */ self.instance.preStart(context: context) // TODO: enable preStart

            return .receiveMessage { message in
                switch message { 
                
                case .hello(let replyTo):
                    instance.hello(replyTo: replyTo) 
                
                case .parking(.park):
                    instance.park() 
                case .ticketing(.makeTicket):
                    instance.makeTicket() 
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
