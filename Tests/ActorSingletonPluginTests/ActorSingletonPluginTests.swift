//
// Created by Yim Lee on 12/13/19.
//

import ActorSingletonPlugin
import DistributedActors
import XCTest

final class ActorSingletonPluginTests: XCTestCase {
    func test_example() throws {
        let system = ActorSystem("X") { settings in

            // able to host the singletons:
            settings.plugins += ActorSingleton(MySingleton.name, MySingleton.behavior)
            settings.plugins += ActorSingleton("different", MySingleton.behavior)
            // settings.plugins += ActorSingleton("different", MySingleton.behavior) // same name + Message type => BOOM!
        }
        defer { system.shutdown() }

        let ref = try system.singleton.ref(name: MySingleton.name, of: MySingleton.Message.self)
        ref.tell("Hello")

        // user-defined convenience:
        try system.singleton.mySingletonRef().tell("Hello")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

enum MySingleton {
    static let name = "charlie"

    typealias Message = String

    static let behavior: Behavior<String> = .receive { context, message in
        context.log.info("message: \(message)")
        return .same
    }
}

extension ActorSingletonLookup {
    /// Users may build such convenience extensions for the lookups
    func mySingletonRef() throws -> ActorRef<MySingleton.Message> {
        try self.ref(name: MySingleton.name, of: MySingleton.Message.self)
    }
}
