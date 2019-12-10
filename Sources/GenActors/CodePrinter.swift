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

/// Utility that helps in printing code at the "right" indentation levels.
struct CodePrinter {
    private var indentation = 0
    // for when templates are embedded in other templates at the right level
    private var _dontIndentNext: Bool = false
    // print to stdout all print() calls
    private var _debug: Bool = false

    var content: String = ""

    init(startingIndentation indentation: Int = 0) {
        self.indentation = indentation
    }

    /// Useful for printing nested parts.
    func makeIndented(by indentation: Int) -> CodePrinter {
        CodePrinter(startingIndentation: self.indentation + indentation)
    }

    func debugging() -> CodePrinter {
        var next = self
        next._debug = true
        return next
    }

    @discardableResult
    mutating func dontIndentNext() -> Self {
        self._dontIndentNext = true
        return self
    }

    mutating func indent() {
        self.indentation += 1
    }

    mutating func outdent() {
        guard self.indentation > 0 else {
            return
        }
        self.indentation -= 1
    }

    mutating func print(_ block: String, skipNewline: Bool = false) {
        let lines = block.split(separator: "\n")
        lines.forEach { line in
            var printMe = ""
            if self._dontIndentNext {
                self._dontIndentNext = false
            } else {
                printMe.append(self.padding)
            }
            printMe.append("\(line)")
            if skipNewline {
                self._dontIndentNext = true
            } else {
                printMe.append("\n")
            }

            self.content.append(printMe)
            if self._debug {
                Swift.print(printMe, terminator: "")
            }
        }
    }

    var padding: String {
        String(repeating: String(repeating: " ", count: 4), count: self.indentation)
    }

    static func content(_ print: (inout CodePrinter) throws -> Void) rethrows -> String {
        var printer = CodePrinter()
        try print(&printer)
        return printer.content
    }
}
