import DistributedActors
import Distributed

@main
struct Main {
    static func main() async throws {
        let system = await ClusterSystem()
        
        try await Greeter(actorSystem: system).hi(name: "Caplin")
    }
}

distributed actor Greeter {
    typealias ID = ActorSystem.ActorID
    typealias ActorSystem = ClusterSystem
    distributed func hi(name: String) {
        print("HELLO \(name)!")
    }
}
