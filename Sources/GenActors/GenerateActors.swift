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

import DistributedActors
import Files
import Foundation
import SwiftSyntax

final class GenerateActors {
    var args: [String]

    let fileScanSuffix: String = "+Actor.swift"

    init(args: [String]) {
        self.args = args
        precondition(args.count > 0, "Syntax: genActors PATH [options]")
    }

    func run() throws -> Bool {
        let actorFilesToScan = try Folder(path: "Samples/").files.recursive.filter { f in
            f.name.hasSuffix("+Actor.swift")
        }

        try actorFilesToScan.forEach {
            try self.run(fileToParse: $0)
        }

        return actorFilesToScan.count > 0
    }

    func run(fileToParse: File) throws -> Bool {
        pprint("[gen actors] Parsing: \(fileToParse.path)")

        let url = URL(fileURLWithPath: fileToParse.path)
        let sourceFile = try SyntaxParser.parse(url)

        var gatherFuncs = GatherActorFuncs()
        sourceFile.walk(&gatherFuncs)

        let renderedShell = try Rendering.ActorShellTemplate(baseName: "Greeter", funcs: gatherFuncs.actorFuncs).render()

        let genActorFilename = "\(fileToParse.nameExcludingExtension).swift".replacingOccurrences(of: "+Actor", with: "+GenActor")
        let targetFile = try fileToParse.parent!.createFile(named: genActorFilename)
        try targetFile.write(Rendering.generatedFileHeader)
        try targetFile.append(renderedShell)

        return true
    }
}

// TODO: we do not allow many actors in the same file I guess
struct GatherActorFuncs: SyntaxVisitor {
    /// Those functions need to be made into message protocol and generate stuff for them
    var actorFuncs: [ActorFunc] = []

    func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            return .skipChildren
        }

        pprint("Actorable detected: \(node.identifier)")
        return .visitChildren
    }

    func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.isActorable() else {
            return .skipChildren
        }

        pprint("Actorable detected: \(node.identifier)") // TODO: we could allow many
        return .visitChildren
    }

    mutating func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // TODO: carry access control
        guard node.modifiers?.contains(where: { mod in
            pprint("mod.name.tokenKind = \(mod.name.tokenKind)")
            return mod.name.tokenKind != .privateKeyword
        }) ?? false else { // FIXME: if not present -> apply swifty rule
            return .skipChildren
        }

        // TODO: we could require it to be async as well or something
        self.actorFuncs.append(.init(
            access: "public",
            name: "greet",
            params: [
                "name": "String",
            ]
        )
        )

        // pprint("MAKE INTO ACTOR FUNC: \(node)")
        return .skipChildren
    }
}

extension DeclSyntax {
    func isActorable() -> Bool {
        var isActorable = IsActorableVisitor()
        self.walk(&isActorable)
        return isActorable.actorable
    }
}

struct IsActorableVisitor: SyntaxVisitor {
    var actorable: Bool = false

    mutating func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        if "\(node)".contains("Actorable") { // TODO: make less hacky
            self.actorable = true
            return .skipChildren
        }
        return .visitChildren
    }

    var shouldContinue: SyntaxVisitorContinueKind {
        return self.actorable ? .visitChildren : .skipChildren
    }
}
