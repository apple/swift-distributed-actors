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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ByteBuffer extensions

extension ByteBuffer {
    /// Intended for ad-hoc debugging purposes of network data or serialized payloads.
    internal var formatHexDump: String {
        self.formatHexDump()
    }

    /// Intended for ad-hoc debugging purposes of network data or serialized payloads.
    internal func formatHexDump(maxBytes: Int = 80, bytesPerLine: Int = 16) -> String {
        let padding = String(repeating: " ", count: 4)
        func asHex(_ byte: UInt8) -> String {
            let s = String(byte, radix: 16, uppercase: true)
            if byte < 16 {
                return "0\(s)" // poor-man's leftPad
            } else {
                return s
            }
        }
        func asASCII(_ byte: UInt8) -> String {
            if (0x20 ... 0x7F).contains(byte) {
                return "\(Character(UnicodeScalar(byte)))"
            } else {
                return "." // not ascii (e.g. binary data)
            }
        }

        func formatLine(_ bs: ArraySlice<UInt8>) -> String {
            var i = 0
            var hex = bs.map { b -> String in
                let space: String
                i += 1
                if i % 8 == 0 {
                    space = "  " // double space, to separate octets
                } else {
                    space = " "
                }
                return "\(asHex(b))\(space)"
            }.joined(separator: "")
            hex += String(repeating: " ", count: bytesPerLine * 3)
            hex = String(hex.prefix(bytesPerLine * 3))

            let ascii = bs.map { asASCII($0) }.joined(separator: "")
            return "\(padding)\(hex)  | \(ascii)"
        }
        func formatBytes(bytes: [UInt8]) -> String {
            var res: [String] = []

            var bs = bytes[...]
            while !bs.isEmpty {
                let group = bs.prefix(bytesPerLine)
                bs = bs.dropFirst(bytesPerLine)

                res.append(formatLine(group))
            }

            return res.joined(separator: "\n")
        }

        var buf = self
        var suffix = ""
        var limitMessage = ""
        if self.readableBytes > maxBytes, let limited = self.getSlice(at: 0, length: maxBytes) {
            limitMessage = ", shown: \(maxBytes)"
            buf = limited
            suffix = "\n\(padding)[ \(self.readableBytes - maxBytes) bytes truncated ... ]"
        }

        return "ByteBuffer(readableBytes: \(self.readableBytes)\(limitMessage)), formatHexDump:\n" +
            "\(formatBytes(bytes: buf.readBytes(length: buf.readableBytes)!))" + suffix
    }
}
