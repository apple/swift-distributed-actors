//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Swift Distributed ActorsActor

// tag::serialization_codable_messages[]
enum ParkingSpotMessages: String, Codable {
    case available
    case taken
}

// end::serialization_codable_messages[]

class SerializationDocExamples {

    lazy var system: ActorSystem = undefined(hint: "Examples, not intended to be run")

    func prepare_system_codable() throws {
        // tag::prepare_system_codable[]
        let system = ActorSystem("CodableExample") { settings in 
            settings.serialization.registerCodable(for: ParkingSpotMessages.self, underId: 1002) // TODO: simplify this
        }
        // end::prepare_system_codable[]
        _ = system // silence not-used warnings
    }
    func sending_serialized_messages() throws {
        let spotAvailable = false
        // tag::sending_serialized_messages[]
        func replyParkingSpotAvailability(driver: ActorRef<ParkingSpotMessages>) {
            if spotAvailable {
                driver.tell(.available)
            } else {
                driver.tell(.taken)
            }
        }
        // end::sending_serialized_messages[]
    }

    func configure_serialize_all() {
        // tag::configure_serialize_all[]
        let system = ActorSystem("SerializeAll") { settings in 
            settings.serialization.allMessages = true
        }
        // end::configure_serialize_all[]
        _ = system
    }

}
