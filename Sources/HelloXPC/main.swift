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
import Cocoa
import SwiftUI
import Dispatch


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: UI

if #available(macOS 10.15, *) {

    class AppDelegate: NSObject, NSApplicationDelegate {


        struct ContentView: View {

            let text: String

            var body: some View {
                Text(self.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        var window: NSWindow!

        func applicationDidFinishLaunching(_ aNotification: Notification) {

            let connection = NSXPCConnection(serviceName: "com.apple.distributedactorsHelloXPCService")
            connection.remoteObjectInterface = NSXPCInterface(with: HelloXPCServiceProtocol.self)
            connection.resume()

            let service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as? HelloXPCServiceProtocol

            service!.hello() { (greeting) in
                print("Greeted 0: \(greeting)")
            }
            service!.hello() { (greeting) in
                print("Greeted 1: \(greeting)")
            }

            service!.hello() { (greeting) in
                print("Greeted: \(greeting)")

                DispatchQueue.main.async {
                    // Create the SwiftUI view that provides the window contents.
                    let contentView = ContentView(text: greeting)

                    // Create the window and set the content view.
                    self.window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
                    self.window.center()
                    self.window.setFrameAutosaveName("Main Window")
                    self.window.contentView = NSHostingView(rootView: contentView)
                    self.window.makeKeyAndOrderFront(nil)
                }
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

//    while 1 == 1 {
//        ()
//    }
} else {
    print("WRONG VERSION")
}
