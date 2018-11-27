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

struct DeadLetter {
    let message: Any
    // TODO: from, to, other metadata
}

// FIXME this is just a quick workaround, will need to be a bit smarter than that
internal final class DeadLettersActorRef: ActorRef<DeadLetter> {
    let _path: ActorPath
    let log: Logger

    init(_ log: Logger, path: ActorPath? = nil) {
        self.log = log
        self._path = path ?? (try! ActorPath(root: "user") / ActorPathSegment("deadLetters"))  // FIXME attach to user guardian
        super.init()
    }

    override var path: ActorPath {
        return _path
    }

    override func tell(_ message: DeadLetter) {
        // TODO more metadata
        log.warn("[deadLetters] Message [\(message)]:\(type(of: message)) was not delivered. Dead letter encountered.")
    }

}
