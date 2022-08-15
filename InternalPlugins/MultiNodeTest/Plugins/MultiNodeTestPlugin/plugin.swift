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

import Foundation
import PackagePlugin

func log(_ log: String, file: String = #fileID, line: UInt = #line) {
    print("[multi-node] \(log)")
}

@main
final class MultiNodeTestPlugin: CommandPlugin {
    var buildConfiguration: PackageManager.BuildConfiguration = .release

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        guard arguments.count > 0 else {
            try self.usage(arguments: arguments)
        }

        if let configIdx = arguments.firstIndex(of: "-c") {
            let configValueIdx = arguments.index(after: configIdx)
            if configValueIdx < arguments.endIndex {
                if arguments[configValueIdx] == "debug" {
                    self.buildConfiguration = .debug
                } else if arguments[configValueIdx] == "release" {
                    self.buildConfiguration = .release
                }
            }
        }

        // Kill all previous runners
        Process.killall(name: "MultiNodeTestKitRunner")

        switch self.buildConfiguration {
        case .debug:
            log("Building multi-node project for debugging...")
        case .release:
            log("Building multi-node project for production...")
        }

        let buildResult = try packageManager.build(
            .all(includingTests: true),
            parameters: .init(configuration: self.buildConfiguration)
        )

        guard buildResult.succeeded else {
            log(buildResult.logText)
            return
        }

        let multiNodeRunner = buildResult.builtArtifacts
            .filter { $0.kind == .executable }
            .first { $0.path.lastComponent.starts(with: "MultiNodeTestKitRunner") }
        guard let multiNodeRunner = multiNodeRunner else {
            throw MultiNodeTestPluginError(message: "Failed")
        }

        log("Detected multi-node test runner: \(multiNodeRunner.path.lastComponent)")

        let process = Process()
        process.binaryPath = "/usr/bin/swift"
        process.arguments = ["run", "MultiNodeTestKitRunner"]
        for arg in arguments {
            process.arguments?.append(arg)
        }

        do {
            log("> swift \(process.arguments?.joined(separator: " ") ?? "")")
            try process.runProcess()
            process.waitUntilExit()
        } catch {
            log("[error] Failed to execute multi-node [\(process.binaryPath!) \(process.arguments!)]! Error: \(error)")
        }
    }

    func usage(arguments: [String]) throws -> Never {
        throw UsageError(message: """
        ILLEGAL INVOCATION: \(arguments)
        USAGE:
        > swift package --disable-sandbox multi-node [OPTIONS] COMMAND

        OPTIONS:
            -c release/debug  - to build in release or debug mode (default: \(self.buildConfiguration))

        COMMAND:
            test - run multi-node tests
            _exec
        """)
    }
}

struct UsageError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        self.message
    }
}

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

extension Process {
    static func killall(name: String) {
        let killAllRunners = Process()
        killAllRunners.binaryPath = "/usr/bin/killall"
        killAllRunners.arguments = ["-9", "MultiNodeTestKitRunner"]
        try? killAllRunners.runProcess()
        killAllRunners.waitUntilExit()
    }
}

struct MultiNodeTestPluginError: Error {
    let message: String
    let file: String
    let line: UInt

    init(message: String, file: String = #file, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }
}
