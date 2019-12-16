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

#if os(macOS)

/// Keys used in xpc dictionaries sent as messages.
public enum ActorableXPCMessageField: String {
    case message = "M"
    case messageLength = "ML"

    case serializerId = "S"

    case recipientLength = "RL"
    case recipientAddress = "R"
}

#else
/// XPC is only available on Apple platforms
#endif
