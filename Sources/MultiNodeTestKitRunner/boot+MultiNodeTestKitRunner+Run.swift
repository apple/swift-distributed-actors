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
import DistributedActors
import struct Foundation.Date
import class Foundation.FileHandle
import class Foundation.Process
import struct Foundation.URL
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Code executing on each specific process/node

extension MultiNodeTestKitRunnerBoot {
    static let OK = "\("test passed".green)"
    static let FAIL = "\("test failed".red)"

    func runMultiNodeTest(_ name: String, suite: String, binary: String) async throws -> InterpretedRunResult {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! elg.syncShutdownGracefully()
        }

        guard let multiNodeTest = findMultiNodeTest(name, suite: suite) else {
            throw MultiNodeTestNotFound(suite: suite, test: name)
        }

        let devNull = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer {
            devNull.closeFile()
        }

        var settings = MultiNodeTestSettings()
        multiNodeTest.self.configureMultiNodeTest(&settings)

        let allNodesCommandString = makeAllNodesCommandString(
            nodeNames: multiNodeTest.nodeNames,
            deployNodes: []
        )

        let testResults = try await withThrowingTaskGroup(
            of: NodeInterpretedRunResult.self,
            returning: [NodeInterpretedRunResult].self
        ) { group in

            for nodeName in multiNodeTest.nodeNames {
                group.addTask { [settings] in
                    let grepper = OutputGrepper.make(
                        nodeName: nodeName,
                        group: elg,
                        programLogRecipient: nil
                    ) // TODO: use distributed log recipient for multi device tests

                    let processOutputPipe = FileHandle(fileDescriptor: try! grepper.processOutputPipe.takeDescriptorOwnership())

                    // TODO: killall except the current ones?
                    // killAll(binary)

                    let process = Process()
                    process.binaryPath = binary
                    process.standardInput = devNull
                    process.standardOutput = processOutputPipe
                    process.standardError = processOutputPipe // we pipe all output to the same pipe; we don't really care that much

                    process.arguments = ["_exec", suite, name, nodeName, allNodesCommandString]

                    try process.runProcess()
                    log("[exec] \(process.binaryPath!) \(process.arguments?.joined(separator: " ") ?? "")\n  \(nodeName) -> PID: \(process.processIdentifier)")
                    assert(process.processIdentifier != 0)

                    process.waitUntilExit()
                    processOutputPipe.closeFile()
                    let result: Result<ProgramOutput, Error> = Result {
                        try grepper.result.wait()
                    }

                    let testResult = try interpretNodeTestOutput(
                        result,
                        nodeName: nodeName,
                        expectedFailureRegex: multiNodeTest.crashRegex,
                        grepper: grepper,
                        settings: settings,
                        runResult: process.terminationReason == .exit ?
                            .exit(Int(process.terminationStatus)) :
                            .signal(Int(process.terminationStatus))
                    )

                    return .init(node: nodeName, result: testResult)
                }
            }

            var results: [NodeInterpretedRunResult] = []
            results.reserveCapacity(multiNodeTest.nodeNames.count)

            for try await result in group {
                results.append(result)
            }

            return results
        }

        let completeResult = (testResults.contains { $0.result.failed }) ? Self.FAIL : Self.OK
        let testFullName = "\(suite).\(name)"
        log("Test '\(testFullName)' results: \(completeResult)")

        for test in testResults {
            let mark = test.result.passed ? Self.OK : Self.FAIL
            log("[\(test.node)] [\(mark)] \(test.result)")
        }

        // return the first failure we found
        for testResult in testResults {
            if testResult.result.failed {
                return testResult.result // return this error (first of them all)
            }
        }

        // all nodes passed okey
        return .passedAsExpected
    }

    func kill(pid: Int32) {
        let process = Process()
        #if os(Linux)
        process.binaryPath = "/usr/bin/bash"
        #elseif os(macOS)
        process.binaryPath = "/usr/bin/local/bash"
        #else
        log("WARNING: can't kill process \(pid), not sure how to kill on this platform")
        return
        #endif

        process.arguments = ["-9", "\(pid)"]
        log("Kill-ing process: \(process.binaryPath!) \(process.arguments?.joined(separator: " ") ?? "")")

        try? process.runProcess()
        process.waitUntilExit()
    }
}

struct NodeInterpretedRunResult {
    let node: String
    let result: MultiNodeTestKitRunnerBoot.InterpretedRunResult
}

func prettyWait(seconds: Int64, hint: String) async {
    if seconds < 1 {
        return
    }

    let messageBase = "[multi-node] Wait (\(hint))"

    var lastMsg = "\(seconds)s remaining..."
    print("\(messageBase) \(lastMsg)", terminator: "")
    for i in 0 ..< seconds {
        try? await Task.sleep(until: .now + .seconds(1), clock: .continuous)
        lastMsg = "\(seconds - i)s remaining..."
        print("\r\(messageBase) \(lastMsg)", terminator: " ")
    }
    print("\r\(messageBase) (waited \(seconds)s) GO!                            ".yellow)
}
