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
import Foundation

enum ArgumentError: Error {
    case missingValue(String)
    case invalidType(value: String, type: String, argument: String?)
    case unsupportedArgument(String)
}

extension ArgumentError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingValue(let key):
            return "missing value for '\(key)'"
        case .invalidType(let value, let type, let argument):
            return (argument == nil)
                ? "'\(value)' is not a valid '\(type)'"
                : "'\(value)' is not a valid '\(type)' for '\(argument!)'"
        case .unsupportedArgument(let argument):
            return "unsupported argument '\(argument)'"
        }
    }
}

/// Type-checked parsing of the argument value.
///
/// - Returns: Typed value of the argument converted using the `parse` function.
///
/// - Throws: `ArgumentError.invalidType` when the conversion fails.
func checked<T>(
    _ parse: (String) throws -> T?,
    _ value: String,
    argument: String? = nil
) throws -> T {
    if let t = try parse(value) { return t }
    var type = "\(T.self)"
    if type.starts(with: "Optional<") {
        let s = type.index(after: type.firstIndex(of: "<")!)
        let e = type.index(before: type.endIndex) // ">"
        type = String(type[s ..< e]) // strip Optional< >
    }
    throw ArgumentError.invalidType(
        value: value, type: type, argument: argument
    )
}

/// Parser that converts the program's command line arguments to typed values
/// according to the parser's configuration, storing them in the provided
/// instance of a value-holding type.
class ArgumentParser<U> {
    private var result: U
    private var validOptions: [String] {
        self.arguments.compactMap(\.name)
    }

    private var arguments: [Argument] = []
    private let programName: String = {
        // Strip full path from the program name.
        let r = CommandLine.arguments[0].reversed()
        let ss = r[r.startIndex ..< (r.firstIndex(of: "/") ?? r.endIndex)]
        return String(ss.reversed())
    }()

    private var positionalArgs = [String]()
    private var optionalArgsMap = [String: String]()

    /// Argument holds the name of the command line parameter, its help
    /// desciption and a rule that's applied to process it.
    ///
    /// The the rule is typically a value processing closure used to convert it
    /// into given type and storing it in the parsing result.
    ///
    /// See also: addArgument, parseArgument
    struct Argument {
        let name: String?
        let help: String?
        let apply: () throws -> Void
    }

    /// ArgumentParser is initialized with an instance of a type that holds
    /// the results of the parsing of the individual command line arguments.
    init(into result: U) {
        self.result = result
        self.arguments += [
            Argument(
                name: "--help", help: "show this help message and exit",
                apply: self.printUsage
            ),
        ]
    }

    private func printUsage() {
        guard let _ = optionalArgsMap["--help"] else { return }
        let space = " "
        let maxLength = self.arguments.compactMap { $0.name?.count }.max()!
        let padded = { (s: String) in
            " \(s)\(String(repeating: space, count: maxLength - s.count))  "
        }
        let f: (String, String) -> String = {
            "\(padded($0))\($1)"
                .split(separator: "\n")
                .joined(separator: "\n" + padded(""))
        }
        let positional = f("TEST", "name or number of the benchmark to measure")
        let optional = self.arguments.filter { $0.name != nil }
            .map { f($0.name!, $0.help ?? "") }
            .joined(separator: "\n")
        print(
            """
            usage: \(self.programName) [--argument=VALUE] [TEST [TEST ...]]
            positional arguments:
            \(positional)
            optional arguments:
            \(optional)
            """)
        exit(0)
    }

    /// Parses the command line arguments, returning the result filled with
    /// specified argument values or report errors and exit the program if
    /// the parsing fails.
    public func parse() -> U {
        do {
            try self.parseArgs() // parse the argument syntax
            try self.arguments.forEach { try $0.apply() } // type-check and store values
            return self.result
        } catch let error as ArgumentError {
            fputs("error: \(error)\n", stderr)
            exit(1)
        } catch {
            fflush(stdout)
            fatalError("\(error)")
        }
    }

    /// Using CommandLine.arguments, parses the structure of optional and
    /// positional arguments of this program.
    ///
    /// We assume that optional switch args are of the form:
    ///
    ///     --opt-name[=opt-value]
    ///     -opt-name[=opt-value]
    ///
    /// with `opt-name` and `opt-value` not containing any '=' signs. Any
    /// other option passed in is assumed to be a positional argument.
    ///
    /// - Throws: `ArgumentError.unsupportedArgument` on failure to parse
    ///     the supported argument syntax.
    private func parseArgs() throws {
        // For each argument we are passed...
        for arg in CommandLine.arguments[1 ..< CommandLine.arguments.count] {
            // If the argument doesn't match the optional argument pattern. Add
            // it to the positional argument list and continue...
            if !arg.starts(with: "-") {
                self.positionalArgs.append(arg)
                continue
            }
            // Attempt to split it into two components separated by an equals sign.
            let components = arg.split(separator: "=")
            let optionName = String(components[0])
            guard self.validOptions.contains(optionName) else {
                throw ArgumentError.unsupportedArgument(arg)
            }
            var optionVal: String
            switch components.count {
            case 1: optionVal = ""
            case 2: optionVal = String(components[1])
            default:
                // If we do not have two components at this point, we can not have
                // an option switch. This is an invalid argument. Bail!
                throw ArgumentError.unsupportedArgument(arg)
            }
            self.optionalArgsMap[optionName] = optionVal
        }
    }

    /// Add a rule for parsing the specified argument.
    ///
    /// Stores the type-erased invocation of the `parseArgument` in `Argument`.
    ///
    /// Parameters:
    ///   - name: Name of the command line argument. E.g.: `--opt-arg`.
    ///       `nil` denotes positional arguments.
    ///   - property: Property on the `result`, to store the value into.
    ///   - defaultValue: Value used when the command line argument doesn't
    ///       provide one.
    ///   - help: Argument's description used when printing usage with `--help`.
    ///   - parser: Function that converts the argument value to given type `T`.
    public func addArgument<T>(
        _ name: String?,
        _ property: WritableKeyPath<U, T>,
        defaultValue: T? = nil,
        help: String? = nil,
        parser: @escaping (String) throws -> T? = { _ in nil }
    ) {
        self.arguments.append(
            Argument(name: name, help: help)
                { try self.parseArgument(name, property, defaultValue, parser) }
        )
    }

    /// Process the specified command line argument.
    ///
    /// For optional arguments that have a value we attempt to convert it into
    /// given type using the supplied parser, performing the type-checking with
    /// the `checked` function.
    /// If the value is empty the `defaultValue` is used instead.
    /// The typed value is finally stored in the `result` into the specified
    /// `property`.
    ///
    /// For the optional positional arguments, the [String] is simply assigned
    /// to the specified property without any conversion.
    ///
    /// See `addArgument` for detailed parameter descriptions.
    private func parseArgument<T>(
        _ name: String?,
        _ property: WritableKeyPath<U, T>,
        _ defaultValue: T?,
        _ parse: (String) throws -> T?
    ) throws {
        if let name = name, let value = optionalArgsMap[name] {
            guard !value.isEmpty || defaultValue != nil
            else { throw ArgumentError.missingValue(name) }

            self.result[keyPath: property] = value.isEmpty
                ? defaultValue!
                : try checked(parse, value, argument: name)
        } else if name == nil {
            self.result[keyPath: property] = self.positionalArgs as! T
        }
    }
}
