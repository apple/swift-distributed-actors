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
import Foundation
import Logging
import MultiNodeTestKit

struct PrettyMultiNodeLogHandler: LogHandler {
    let nodeName: String
    let settings: MultiNodeTestSettings.MultiNodeLogCaptureSettings

    init(nodeName: String, settings: MultiNodeTestSettings.MultiNodeLogCaptureSettings) {
        self.nodeName = nodeName
        self.settings = settings
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        var _metadata: Logger.Metadata = metadata ?? [:]

        for excludeGrep in self.settings.excludeGrep {
            if file.contains(excludeGrep) || "\(message)".contains(excludeGrep) {
                return
            }
        }

        let date = Date()
        _metadata.merge(metadata ?? [:], uniquingKeysWith: { _, r in r })

        var metadataString: String = ""
        var actorPath: String = ""
        if var metadata = metadata {
            if let path = metadata.removeValue(forKey: "actor/path") {
                actorPath = "[\(path)]"
            }

            metadata.removeValue(forKey: "label")
            if !metadata.isEmpty {
                metadataString = "\n"
                for key in metadata.keys.sorted() {
                    let value: Logger.MetadataValue = metadata[key]!
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
        }
        let dateStr = Self._createFormatter().string(from: date)
        let file = file.split(separator: "/").last ?? ""
        print("[\(dateStr)] [\(file):\(line)]\(actorPath) [\(level)] \(message)\(metadataString)")
    }

    internal func prettyPrint(metadata: Logger.MetadataValue) -> String {
        let CONSOLE_RESET = "\u{001B}[0;0m"
        let CONSOLE_BOLD = "\u{001B}[1m"

        var valueDescription = ""
        switch metadata {
        case .string(let string):
            valueDescription = string
        case .stringConvertible(let convertible as CustomPrettyStringConvertible):
            valueDescription = convertible.prettyDescription
        case .stringConvertible(let convertible):
            valueDescription = convertible.description
        case .array(let array):
            valueDescription = "\n  \(array.map { "\($0)" }.joined(separator: "\n  "))"
        case .dictionary(let metadata):
            for k in metadata.keys {
                valueDescription += "\(CONSOLE_BOLD)\(k)\(CONSOLE_RESET): \(self.prettyPrint(metadata: metadata[k]!))"
            }
        }

        return valueDescription
    }

    internal static func _createFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd H:m:ss.SSSS"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public var metadata: Logging.Logger.Metadata = [:]

    public var logLevel: Logger.Level {
        get {
            .trace
        }
        set {
            // ignore, we always collect all logs
        }
    }
}
