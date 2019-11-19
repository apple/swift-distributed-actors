//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Service Provider (using NSXPC)

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelloXPCServiceProtocol.self)

        let exportedObject = HelloXPCService()
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Impl

@objc class HelloXPCService: NSObject, HelloXPCServiceProtocol {

    func hello(withReply reply: @escaping (String) -> Void) {
        reply("Hello!")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: main

let listener = NSXPCListener.service()
let delegate = ServiceDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()

