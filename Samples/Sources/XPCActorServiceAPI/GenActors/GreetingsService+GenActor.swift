// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====


// tag::xpc_example[]
import DistributedActors
import DistributedActorsXPC
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated GreetingsService messages 

extension GeneratedActor.Messages {
    public enum GreetingsService: ActorMessage {  
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Boxing GreetingsService for any inheriting actorable `A` 

extension Actor where Act: GreetingsService {

}
