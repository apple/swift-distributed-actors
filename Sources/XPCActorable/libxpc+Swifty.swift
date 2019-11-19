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

import XPC
import Dispatch
import CXPCActorable

public enum XPCLibSupport {

    // typealias xpc_handler_t = (xpc_object_t) -> Void

    public static func connect(name: String) -> xpc_connection_t {
        print("\(#function)")
        return CXPCActorable.sact_xpc_get_connection()
    }

}
