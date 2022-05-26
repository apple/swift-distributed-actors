import DistributedActors
import Distributed

distributed actor Greeter: CustomStringConvertible {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem
    distributed func hi(name: String) -> String {
        let message = "HELLO \(name)!"
        print(">>> \(self): \(message)")
        return message
    }

    nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

@main
enum Main {
    static func main() async throws {
//        LoggingSystem.bootstrap(_SWIMPrettyMetadataLogHandler.init)

        let system = await ClusterSystem("FirstSystem") { settings in
            settings.node.host = "127.0.0.1"
            settings.node.port = 7337
            settings.logging.useBuiltInFormatter = true
        }
        let second = await ClusterSystem("SecondSystem") { settings in
            settings.node.host = "127.0.0.1"
            settings.node.port = 8228
            settings.logging.useBuiltInFormatter = true
        }

        system.cluster.join(node: second.cluster.uniqueNode)

        print("LOCAL:")
        let greeter = Greeter(actorSystem: system)
        try await greeter.hi(name: "Caplin")

        print("RESOLVE:")
        let resolved = try Greeter.resolve(id: greeter.id, using: system)
        print("Resolved: \(resolved)")
        try await resolved.hi(name: "Caplin")

        // ------------------------------------------
        print("REMOTE:")
        let remote = try Greeter.resolve(id: greeter.id, using: second)
        print("Resolve remote: \(remote)")

        let reply = try await remote.hi(name: "Remotely")
        print("Received reply from remote \(remote): \(reply)")

        try await Task.sleep(until: .now + .seconds(5), clock: .continuous)
        print("================ DONE ================")
    }
}
