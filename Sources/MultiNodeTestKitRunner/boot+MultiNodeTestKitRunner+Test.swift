//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import DistributedCluster
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

import struct Foundation.Date
import class Foundation.ProcessInfo
import struct Foundation.URL

#if canImport(Foundation.Process)
import class Foundation.Process
#endif

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Code executing on each specific process/node

extension MultiNodeTestKitRunnerBoot {
    static let OK = "\("test passed".green)"
    static let FAIL = "\("test failed".red)"

    struct MultiNodeTestSummary {
        private var summaryLines: [Line] = []

        struct Line {
            let line: String
            let failed: Bool
        }

        mutating func emit(_ message: String, failed: Bool) {
            if failed {
                return emitFailed(message)
            }

            print("[multi-node] \(message)")
            self.summaryLines.append(Line(line: message, failed: false))
        }

        mutating func emitFailed(_ message: String) {
            print("[multi-node] \(message)".red)
            self.summaryLines.append(Line(line: message, failed: true))
        }

        func dump() {
            print(String(repeating: "=", count: 120))
            print("[multi-node] MULTI NODE TEST SUITE RUN SUMMARY:")
            for line in self.summaryLines {
                print(line.line)
            }
            print(String(repeating: "=", count: 120))
        }

        var failedTests: Int {
            self.summaryLines.filter(\.failed).count
        }
    }

    func runAndEval(suite: String, testName: String, summary: inout MultiNodeTestSummary) async {
        let startDate = Date()
        summary.emit("Test '\(suite).\(testName)' started at \(startDate)", failed: false)

        do {
            let runResult = try await runMultiNodeTest(suite: suite, testName: testName, binary: CommandLine.arguments.first!)

            let endDate = Date()
            var message = "Test '\(suite).\(testName)' finished: "
            var failed = false
            switch runResult {
            case .passedAsExpected:
                message += "OK (PASSED) "
            case .crashedAsExpected:
                message += "OK (EXPECTED CRASH) "

            case .crashRegexDidNotMatch(let regex, output: _):
                message += "FAILED: crash regex did not match output; regex: \(regex) "
                failed = true
            case .unexpectedRunResult(let runResult):
                summary.emitFailed("FAILED: unexpected run result: \(runResult) ")
                failed = true
            case .outputError(let description):
                message += "FAILED: \(description) "
                failed = true
            }
            summary.emit("\(message) (took: \(endDate.timeIntervalSince(startDate)))", failed: failed)
        } catch {
            let endDate = Date()
            summary.emitFailed("Test '\(suite).\(testName)' finished: FAILED (took: \(endDate.timeIntervalSince(startDate))), threw error: \(error)")
        }
    }

    func commandTest(summary: inout MultiNodeTestSummary, filter: TestFilter) async {
        for testSuite in MultiNodeTestSuites {
            let suiteStartDate = Date()
            summary.emit("", failed: false)
            summary.emit("[multi-node] TestSuite '\(testSuite.key)' started at \(suiteStartDate)", failed: false)

            for test in allTestsForSuite(testSuite.key)
            where filter.matches(suiteName: testSuite.key, testName: test.0) {
                await runAndEval(suite: testSuite.key, testName: test.0, summary: &summary)
            }
        }
    }

    func runMultiNodeTest(suite: String, testName: String, binary: String) async throws -> InterpretedRunResult {
        #if !canImport(Foundation.Process)
        struct UnsupportedPlatform: Error {}
        throw UnsupportedPlatform()
        #else
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! elg.syncShutdownGracefully()
        }

        guard let multiNodeTest = findMultiNodeTest(suite: suite, testName: testName) else {
            throw MultiNodeTestNotFound(suite: suite, test: testName)
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
                    )  // TODO: use distributed log recipient for multi device tests

                    let processOutputPipe = FileHandle(fileDescriptor: try! grepper.processOutputPipe.takeDescriptorOwnership())

                    // TODO: killall except the current ones?
                    // killAll(binary)

                    let process = Process()
                    process.binaryPath = binary
                    process.standardInput = devNull
                    process.standardOutput = processOutputPipe
                    process.standardError = processOutputPipe  // we pipe all output to the same pipe; we don't really care that much

                    process.arguments = ["_exec", suite, testName, nodeName, allNodesCommandString]

                    try process.runProcess()
                    log("[exec] \(process.binaryPath!) \(process.arguments?.joined(separator: " ") ?? "")\n  \(nodeName) -> PID: \(process.processIdentifier)")
                    assert(process.processIdentifier != 0, "Failed to spawn process")

                    let testTimeoutTask = startTestTimeoutReaperTask(nodeName: nodeName, process: process, settings: settings)
                    process.waitUntilExit()
                    testTimeoutTask.cancel()

                    processOutputPipe.closeFile()
                    let result: Result<ProgramOutput, Error> = Result {
                        try grepper.result.wait()
                    }

                    let testResult = try await interpretNodeTestOutput(
                        result,
                        nodeName: nodeName,
                        multiNodeTest: multiNodeTest,
                        expectedFailureRegex: multiNodeTest.crashRegex,
                        grepper: grepper,
                        settings: settings,
                        runResult: process.terminationReason == .exit ? .exit(Int(process.terminationStatus)) : .signal(Int(process.terminationStatus))
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
        let testFullName = "\(suite).\(testName)"
        log("Test '\(testFullName)' results: \(completeResult)")

        for test in testResults {
            let mark = test.result.passed ? Self.OK : Self.FAIL
            log("[\(test.node)] [\(mark)] \(test.result)")
        }

        // return the first failure we found
        for testResult in testResults {
            if testResult.result.failed {
                return testResult.result  // return this error (first of them all)
            }
        }

        // all nodes passed okey
        return .passedAsExpected
        #endif
    }

    #if canImport(Foundation.Process)
    private func startTestTimeoutReaperTask(nodeName: String, process: Process, settings: MultiNodeTestSettings) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(until: .now + settings.execRunHardTimeout, clock: .continuous)
            guard !Task.isCancelled else {
                return
            }

            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
            print("!!!!!!       MULTI-NODE TEST TEST NODE \(nodeName) SEEMS STUCK - TERMINATE     !!!!!!")
            print("!!!!!!       PID: \(ProcessInfo.processInfo.processIdentifier)                 !!!!!!")
            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")

            process.terminate()
        }
    }
    #endif
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
    for i in 0..<seconds {
        try? await Task.sleep(until: .now + .seconds(1), clock: .continuous)
        lastMsg = "\(seconds - i)s remaining..."
        print("\r\(messageBase) \(lastMsg)", terminator: " ")
    }
    print("\r\(messageBase) (waited \(seconds)s) GO!                            ".yellow)
}
