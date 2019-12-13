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
//sa
//===----------------------------------------------------------------------===//

import DistributedActors
import XPCActorable
import it_XPCActorable_echo_api
import Files

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt")

public struct XPCEchoService: Actorable, XPCEchoServiceProtocol {

    let context: Myself.Context

    public func echo(string: String) -> String {
        try! _file.append("\(self.context.address) got \(string)\n")
        return "echo:\(string)"
    }
}
