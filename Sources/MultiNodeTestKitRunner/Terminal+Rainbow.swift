//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import DistributedCluster
import struct Foundation.Date
import class Foundation.FileHandle
import class Foundation.Process
import struct Foundation.URL
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

enum Rainbow: String {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case `default` = "\u{001B}[0;0m"

    func name() -> String {
        switch self {
        case .black: return "Black"
        case .red: return "Red"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .blue: return "Blue"
        case .magenta: return "Magenta"
        case .cyan: return "Cyan"
        case .white: return "White"
        case .default: return "Default"
        }
    }
}

extension String {
    var black: String {
        self.colored(as: .black)
    }

    var red: String {
        self.colored(as: .red)
    }

    var green: String {
        self.colored(as: .green)
    }

    var yellow: String {
        self.colored(as: .yellow)
    }

    var blue: String {
        self.colored(as: .blue)
    }

    var magenta: String {
        self.colored(as: .magenta)
    }

    var cyan: String {
        self.colored(as: .cyan)
    }

    var white: String {
        self.colored(as: .white)
    }

    var `default`: String {
        self.colored(as: .default)
    }

    func colored(as color: Rainbow) -> String {
        "\(color.rawValue)\(self)\(Rainbow.default.rawValue)"
    }
}
