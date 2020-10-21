//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import Logging

internal class VirtualActorPersonality<Message: Codable>: CellDelegate<Message> {
    let _system: ActorSystem
    override var system: ActorSystem {
        self._system
    }

    let _address: ActorAddress
    override var address: ActorAddress {
        self._address
    }

    private var uniqueName: String {
        self.address.name
    }

    let plugin: ActorRef<VirtualNamespacePluginActor.Message>
    // let namespace: ActorRef<VirtualNamespaceActor<Message>.Message>

    init(system: ActorSystem, plugin: ActorRef<VirtualNamespacePluginActor.Message>, address: ActorAddress) {
        precondition(address.path.starts(with: ._virtual), "Virtual actors MUST be nested under the \(ActorPath._virtual) actor path, was: \(address)")
        self.plugin = plugin
        self._system = system
        // self.namespace = namespace
        self._address = address
        super.init()
    }

    override func sendMessage(_ message: Message, file: String, line: UInt) {
        self.plugin.tell(.forward(namespaceType: Message.self, message: VirtualNamespaceActor<Message>.Message.forward(uniqueName: self.uniqueName, message)), file: #file, line: #line)
    }

    override func sendSystemMessage(_ message: _SystemMessage, file: String, line: UInt) {
        fatalError("\(#function) is not supported on remote or virtual actors.") // FIXME: it should be possible, we should be able to watch them I suppose?
    }

    override func sendClosure(file: String, line: UInt, _ f: @escaping () throws -> Void) {
        fatalError("\(#function) is not supported on remote or virtual actors.")
    }

    override func sendSubMessage<SubMessage>(_ message: SubMessage, identifier: AnySubReceiveId, subReceiveAddress: ActorAddress, file: String, line: UInt) {
        fatalError("\(#function) is not supported on remote or virtual actors.")
    }

    override func sendAdaptedMessage(_ message: Any, file: String, line: UInt) {
        fatalError("\(#function) is not supported on remote or virtual actors.")
    }
}
