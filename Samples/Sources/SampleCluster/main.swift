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
import Logging
import SWIM

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

LoggingSystem.bootstrap(_SWIMPrettyMetadataLogHandler.init) // just much much nicer log printouts

let system = ActorSystem("SampleCluster") { settings in
    settings.cluster.enabled = true
    settings.cluster.bindPort = port

    settings.logging.logLevel = .info
//    settings.cluster.swim.logger.logLevel = .trace

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
    .setup { context in
        var membership: Cluster.Membership = .empty
        return .receive { context, event in
            try? membership.apply(event: event)

            let member: String
            let status: String
            switch event {
            case Cluster.Event.membershipChange(let change):
                member = "\(change.member.uniqueNode.debugDescription)"
                status = "\(change.status)"
            default:
                member = ""
                status = ""
            }
            context.log.info("Cluster Event: \(event)", metadata: [
                "member": "\(member)",
                "status": "\(status)",
                "membership": Logger.MetadataValue.array(membership.members(atLeast: .joining).map { "\(String(reflecting: $0))" }),
            ])
            return .same
        }
    }
) // <1>

system.cluster.events.subscribe(eventsListener) // <2>
// end::cluster-sample-event-listener[]

// tag::cluster-sample-actors-discover-and-chat[]
let chatter: ActorRef<String> = try system.spawn(
    "chatter",
    .receive { context, text in
        context.log.info("Received: \(text)")
        return .same
    }
)
system._receptionist.register(chatter, with: "chat-room") // <1>

if system.cluster.uniqueNode.port == 7337 { // <2>
    try system.spawn(
        "greeter",
        of: Reception.Listing<ActorRef<String>>.self,
        .setup { context in // <3>
            context.receptionist.subscribeMyself(to: "chat-room")

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

try! system.park(atMost: .seconds(6000))
