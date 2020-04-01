//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Cocoa
import Dispatch
import Foundation
import HelloXPCProtocol
import SwiftUI

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UI

if #available(macOS 10.15, *) {
    class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ aNotification: Notification) {
            let connection = NSXPCConnection(serviceName: "com.apple.distributedactors.HelloXPCService")
            connection.remoteObjectInterface = NSXPCInterface(with: HelloXPCServiceProtocol.self)
            connection.resume()

            let service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as? HelloXPCServiceProtocol

            service!.hello { greeting in
                print("Greeted 0: \(greeting)")
            }
            service!.hello { greeting in
                print("Greeted 1: \(greeting)")
            }

            service!.hello { greeting in
                print("Greeted 3: \(greeting)")
            }
        }

        func applicationWillTerminate(_ aNotification: Notification) {
            // Insert code here to tear down your application
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Using

    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate

    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
} else {
    print("WRONG VERSION")
}
