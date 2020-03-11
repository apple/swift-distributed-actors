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

import Logging

import Foundation // for Codable

public protocol Messageable {}

// : CustomReflectable
// extension Codable: Messageable {
//    public var customMirror: Mirror {
//        let children: DictionaryLiteral<String, Any> = [
//            "init(from:)": type(of: Self.init(from:))
//        ]
//
//        // Mirror(Self.self, children: children, displayStyle: .class)
//        return Mirror(self.self, children: children, displayStyle: .class)
//    }
// }
