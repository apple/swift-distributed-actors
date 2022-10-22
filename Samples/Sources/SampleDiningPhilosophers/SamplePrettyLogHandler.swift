//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
@testable import DistributedCluster
import Logging

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Windows)
import CRT
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#else
#error("Unsupported runtime")
#endif

/// Logger that prints "pretty" for showcasing the cluster nicely in sample applications.
struct SamplePrettyLogHandler: LogHandler {
    static let CONSOLE_RESET = "\u{001B}[0;0m"
    static let CONSOLE_BOLD = "\u{001B}[1m"

    public static func make(label: String) -> SamplePrettyLogHandler {
        return SamplePrettyLogHandler(label: label)
    }

    private let label: String

    public var logLevel: Logger.Level = .info

    public var metadata = Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    // internal for testing only
    internal init(label: String) {
        self.label = label
    }

    // TODO: this implementation of getting a nice printout is a bit messy, but good enough for our sample apps
    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var metadataString = ""
        var nodeInfo = ""

        var effectiveMetadata = (metadata ?? [:]).merging(self.metadata, uniquingKeysWith: { _, new in new })
        if let node = effectiveMetadata.removeValue(forKey: "cluster/node") {
            nodeInfo += "\(node)"
        }
        let label: String
        if let path = effectiveMetadata.removeValue(forKey: "actor/path")?.description {
            label = path
        } else {
            label = ""
        }

        if !effectiveMetadata.isEmpty {
            metadataString = "\n// metadata:\n"
            for key in effectiveMetadata.keys.sorted() {
                let value: Logger.MetadataValue = effectiveMetadata[key]!
                let valueDescription = self.prettyPrint(metadata: value)

                var allString = "\n// \"\(key)\": \(valueDescription)"
                if allString.contains("\n") {
                    allString = String(
                        allString.split(separator: "\n").map { valueLine in
                            if valueLine.starts(with: "// ") {
                                return "\(valueLine)\n"
                            } else {
                                return "// \(valueLine)\n"
                            }
                        }.joined(separator: "")
                    )
                }
                metadataString.append(allString)
            }
            metadataString = String(metadataString.dropLast(1))
        }

        let file = file.split(separator: "/").last ?? ""
        let line = line
        print("\(self.timestamp()) [\(file):\(line)] [\(nodeInfo)\(Self.CONSOLE_BOLD)\(label)\(Self.CONSOLE_RESET)] [\(level)] \(message)\(metadataString)")
    }

    internal func prettyPrint(metadata: Logger.MetadataValue) -> String {
        var valueDescription = ""
        switch metadata {
        case .string(let string):
            valueDescription = string
        case .stringConvertible(let convertible):
            valueDescription = convertible.description
        case .array(let array):
            valueDescription = "\n  \(array.map { "\($0)" }.joined(separator: "\n  "))"
        case .dictionary(let metadata):
            for k in metadata.keys {
                valueDescription += "\(Self.CONSOLE_BOLD)\(k)\(Self.CONSOLE_RESET): \(self.prettyPrint(metadata: metadata[k]!))"
            }
        }

        return valueDescription
    }

    private func timestamp() -> String {
        var buffer = [Int8](repeating: 0, count: 255)
        var timestamp = time(nil)
        let localTime = localtime(&timestamp)
        // This format is pleasant to read in local sample apps:
        strftime(&buffer, buffer.count, "%H:%M:%S", localTime)
        // The usual full format is:
        // strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)
        return buffer.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) {
                String(cString: $0.baseAddress!)
            }
        }
    }
}

extension DistributedActor where Self: CustomStringConvertible {
    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}
