//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
// FIXME(regex): rdar://98705227 can't use regex on 5.7 on Linux because of a bug that crashes String.starts(with:) at runtime then
import RegexBuilder
import XCTest

internal struct InspectKit {
    private static var baseDir: String {
        FileManager.default.currentDirectoryPath
    }

    private static func runCommand(
        cmd: String,
        args: String...
    ) -> (output: [Substring], error: [Substring], exitCode: Int32) {
        var output: [Substring] = []
        var error: [Substring] = []

        let task = Process()
        task.launchPath = cmd
        task.arguments = args

        let outPipe = Pipe()
        task.standardOutput = outPipe
        let errPipe = Pipe()
        task.standardError = errPipe

        task.launch()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        if var string = String(data: outData, encoding: .utf8) {
            string = string.trimmingCharacters(in: .whitespacesAndNewlines)
            output = string.split(separator: "\n")
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if var string = String(data: errData, encoding: .utf8) {
            string = string.trimmingCharacters(in: .whitespacesAndNewlines)
            error = string.split(separator: "\n")
        }

        task.waitUntilExit()
        let status = task.terminationStatus

        return (output, error, status)
    }

    struct ActorStats {
        var stats: [String: Row] = [:]

        func dump() {
            for v in self.stats.values {
                v.dump()
            }
        }

        func dumpString() -> String {
            var s = ""
            for v in self.stats.values {
                s += v.dumpString()
            }
            return s
        }

        var totalCount: Int {
            var c = 0
            for v in self.stats.values {
                c += v.count
            }
            return c
        }

        func detectLeaks(latest: ActorStats) -> ActorsLeakedError? {
            var diff = latest

            for v in self.stats.values {
                if var lv = latest.stats[v.typeName] {
                    lv.count -= v.count
                    for vid in v.objectIDs {
                        lv.objectIDs.remove(vid)
                    }

                    if lv.count > 0 {
                        diff.stats[v.typeName] = lv
                    }
                }
            }

            if diff.totalCount > 0 {
                var s = ""
                s += "!!!!!! DETECTED LEAKED ACTORS: \(diff.totalCount) !!!!\n"
                s += "BEFORE ============================================\n"
                s += self.dumpString()
                s += "NOW ===============================================\n"
                s += latest.dumpString()
                s += "DIFF ==============================================\n"
                s += diff.dumpString()
                s += "DIFF ==============================================\n"
                s += "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"

                return ActorsLeakedError(message: s, before: self, after: latest)
            }

            return nil
        }

        struct ActorsLeakedError: Error {
            let message: String

            let before: ActorStats
            let after: ActorStats
        }

        struct Row {
            let typeName: String
            // Count of this type of actor
            var count: Int
            // Object identifiers of the actors
            var objectIDs: Set<String>

            func dump() {
                print(self.dumpString())
            }

            func dumpString() -> String {
                """
                \(self.typeName)
                  - count: \(self.count)
                  - ids: \(self.objectIDs)\n
                """
            }
        }
    }

    /// Actor names to their counts
    static func actorStats() throws -> ActorStats {
        // FIXME(regex): rdar://98705227 can't use regex on 5.7 on Linux because of a bug that crashes String.starts(with:) at runtime then
        let (out, err, _) = Self.runCommand(cmd: "\(self.baseDir)/scripts/dump_actors.sh")

        var stats: [String: ActorStats.Row] = [:]
        for line in out {
            let line = line.drop(while: { $0 == " " })

            guard let idAndType = line.firstMatch(of: try Regex(".*?(?= state)"))?.0 else {
                continue
            }

            let split = idAndType.split(separator: " ")
            guard let id = split.first else {
                continue
            }
            let name = split.dropFirst().joined(separator: " ")

            var stat = stats[String(name)] ?? .init(typeName: String(name), count: 0, objectIDs: [])
            stat.count += 1
            stat.objectIDs.insert(String(id))
            stats[String(name)] = stat
        }

        for line in err {
            print("[InspectKit:error] \(line)")
        }

        return ActorStats(stats: stats)
    }
}

extension [Substring: InspectKit.ActorStats] {}

// Compatible with Swift on all macOS versions as well as Linux
extension Process {
    var binaryPath: String? {
        get {
            if #available(macOS 10.13, /* Linux */ *) {
                return self.executableURL?.path
            } else {
                return self.launchPath
            }
        }
        set {
            if #available(macOS 10.13, /* Linux */ *) {
                self.executableURL = newValue.map { URL(fileURLWithPath: $0) }
            } else {
                self.launchPath = newValue
            }
        }
    }

    func runProcess() throws {
        if #available(macOS 10.13, *) {
            try self.run()
        } else {
            self.launch()
        }
    }
}
