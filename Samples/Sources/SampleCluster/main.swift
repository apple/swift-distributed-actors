//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// tag::cluster-sample[]
import DistributedActors
// end::cluster-sample[]

func parseHostPort(_ s: String) -> (String, Int) {
    let parts = s.split(separator: ":")
    let host: String
    let port: Int
    if parts.count == 1 {
        host = "127.0.0.1"
        port = Int(parts.first!)!
    } else {
        host = String(parts.first!)
        port = Int(parts.dropFirst().first!)!
    }

    return (host, port)
}

// tag::cluster-sample[]

let args = CommandLine.arguments
guard let port = (args.dropFirst().first.flatMap { n in Int(n) }) else {
    fatalError("no port provided; Example: swift run SampleCluster 8228 [[127.0.0.1:]7337]")
}

let joinAddress = args.dropFirst(2).first

let system = ActorSystem("SampleCluster") { settings in
    settings.cluster.enabled = true
    settings.cluster.bindPort = port

    settings.cluster.downingStrategy = .timeout(.default)

    // settings.serialization.register... <1>
}

if let joinAddress = joinAddress {
    let (host, port) = parseHostPort(joinAddress)
    system.cluster.join(host: host, port: port) // <2>
}

// system.spawn <3>

// end::cluster-sample[]

// tag::cluster-sample-event-listener[]
let eventsListener = try system.spawn(
    "eventsListener",
    of: Cluster.Event.self,
    .receive { context, event in
        context.log.info("Cluster Event: \(event)")
        return .same
    }
) // <1>

system.cluster.events.subscribe(eventsListener) // <2>
// end::cluster-sample-event-listener[]

// TODO: making this codable and making Chat Routlette example?
// enum ChatMessage {
//    case announcement(String)
//    case text(String, from: ActorRef<ChatMessage>)
// }
// tag::cluster-sample-actors-discover-and-chat[]
let chatter: ActorRef<String> = try system.spawn(
    "chatter",
    .receive { context, text in
        context.log.info("Received: \(text)")
        return .same
    }
)
let chatRoomId = "chat-room"
system.receptionist.register(chatter, key: chatRoomId) // <1>

if system.cluster.node.port == 7337 { // <2>
    let greeter = try system.spawn(
        "greeter",
        of: Receptionist.Listing<ActorRef<String>>.self,
        .setup { context in // <3>
            context.system.receptionist.subscribe(key: Receptionist.RegistrationKey(ActorRef<String>.self, id: chatRoomId), subscriber: context.myself)

            return .receiveMessage { chattersListing in // <4>
                for chatter in chattersListing.refs {
                    chatter.tell("Welcome to [chat-room]! chatters online: \(chattersListing.refs.count)")
                }
                return .same
            }
        }
    )
}

// end::cluster-sample-actors-discover-and-chat[]

system.park(atMost: .seconds(6000))
