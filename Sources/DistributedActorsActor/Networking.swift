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

import NIO

// Actors engage in 'Networking' - the process of interacting with others to exchange information and develop contacts.

// MARK: Actor System Network Settings

public struct NetworkSettings {

    public static var `default`: NetworkSettings {
        return NetworkSettings(bindAddress: .init(systemName: "ActorSystem", host: "127.0.0.1", port: 7337))
    }

    var bindAddress: Network.Address
}


// MARK: Internal Network Kernel, which owns and administers all connections of this system

internal class NetworkKernel {

    enum Messages {
        case bind(Network.Address)
    }

    static var behavior: Behavior<Messages> {
        let kernel = NetworkKernel()
        return kernel.bootstrap()
    }

    var props: Props {
        return Props().addSupervision(strategy: .restart(atMost: 10, within: .seconds(10)))
    }

    // MARK: Internal state machine entry point

    internal func bootstrap() -> Behavior<Messages> {
        return .setup { context in
            let chanElf = self.bootstrapServer(settings: context.system.settings.network)
            chanElf.map { channel in
                return self.bound(channel)
            }

            return .same
        }
    }

    // TODO: abstract into `Transport`
    internal func bound(_ channel: Channel) -> Behavior<Messages> {


        return .same
    }
}


// TODO: Or "WireProtocol" or "Networking"
enum Network {

    struct Envelope {
        // let version: Version

        var recipient: UniqueActorPath
        // let headers: [String: String]

        var serializerId: Int
        var payload: [UInt8]
    }

    struct Version {
        var reserved: UInt8 = 0
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var patch: UInt8 = 0
    }

    struct RemoteAssociation {
        let address: Network.Address
        let uid: Int64
    }

    struct Address {
        let `protocol`: String = "sact"
        var systemName: String
        var host: String
        var port: UInt

    }

    struct RemotingState {
        var associations: RemoteAssociation
    }


}

extension Network.Address: CustomStringConvertible {
    var description: String {
        return "\(`protocol`)://\(systemName)@\(host):\(port)"
    }
}
