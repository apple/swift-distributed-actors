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

import CDungeon

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif


internal class FaultHandlingDungeon {

    private static let cyan = "\u{001B}[0;36m"
    private static let red = "\u{001B}[0;31m"
    private static let reset = "\u{001B}[0;0m"

    private init() {
        // no instances
    }

    static func withCrashHandlerInstall<T>(reaper: FaultyActorReaper.Ref, mailbox: Mailbox<T>, run: () throws -> ()) throws {
        try! installCrashHandling(reaper: reaper, mailbox: mailbox)
        do {
            try run()
        } catch {
            removeCrashHandling()
        }

    }

    static func installCrashHandling<M>(reaper: FaultyActorReaper.Ref, mailbox: Mailbox<T>) throws {
        let code = CDungeon.sact_install_swift_crash_handler({
            let actorPath = cell._myselfInACell?.path.description ?? "???"
            pprint("\(red)[\(actorPath)] THERE WAS A CRASH.\(reset)")

            // TODO carry error code?
            reaper.tell(.failed(cause: POSIXErrorCode(rawValue: 15)!, path: cell.myself.path))
        })

        switch code {
        case 0:
            pprint("\(cyan)[\(cell.myself.path)] Installed crash handler  \(reset)")
            () // installed properly
        case Darwin.EBUSY:
            pprint("\(red)[\(cell.myself.path)] Installing crash handling failed, code: EBUSY(\(code))  \(reset)")
        default:
            throw FaultHandlingError.unableToInstallFaultHandlingHook(errorCode: Int(code))
        }
    }

    static func installCrashHandling<M>() throws {
        let code = CDungeon.sact_install_swift_crash_handler({
            let actorPath = cell._myselfInACell?.path.description ?? "???"
            pprint("\(red)[\(actorPath)] THERE WAS A CRASH.\(reset)")

            // TODO carry error code?
            reaper.tell(.failed(cause: POSIXErrorCode(rawValue: 15)!, path: cell.myself.path))
        })

        switch code {
        case 0:
            pprint("\(cyan)[\(cell.myself.path)] Installed crash handler  \(reset)")
            () // installed properly
        case Darwin.EBUSY:
            pprint("\(red)[\(cell.myself.path)] Installing crash handling failed, code: EBUSY(\(code))  \(reset)")
        default:
            throw FaultHandlingError.unableToInstallFaultHandlingHook(errorCode: Int(code))
        }
    }

    func killSelfProcess() {
        print("Ship's going down, killing pid: \(getpid())")
        kill(getpid(), SIGKILL)
    }


    /// Error code will be a Linux System Error code, see:   /usr/include/asm/errno.h
    enum FaultHandlingError: Error {
        case unableToInstallFaultHandlingHook(errorCode: Int)
    }
}

// MARK: FaultyActorReaper (also known as the "Grim Reaper"), responsible for terminating faulty actors

internal enum FaultyActorReaper {
    typealias Ref = ActorRef<ReaperMessage>
    public static let behavior: Behavior<ReaperMessage> = .receive { context, message in
        switch message {
        case let .failed(cause, path):
            context.log.warn("Reaper knows about \(path), died because \(cause)")
        }
        return .same
    }
}

internal enum ReaperMessage {
    case failed(cause: POSIXErrorCode, path: ActorPath)
}
