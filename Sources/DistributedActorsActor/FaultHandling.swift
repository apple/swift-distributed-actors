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
import class Foundation.NSMutableDictionary

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif


public enum FaultyWorkerMessages {
    case work(n: Int, divideBy: Int)
    case throwError(error: Error)
}


// since we need to offer the cell to C code, but it can not be passed closures that capture generic parameters
private struct WrappedFailCellClosure {
    private let _fail: (UnsafeMutableRawPointer?, Int32, Int32) -> ()

    init(fail: @escaping (UnsafeMutableRawPointer?, Int32, Int32) -> ()) {
        self._fail = fail
    }

    @inlinable
    func fail(_ cell_ptr: UnsafeMutableRawPointer?, sig: Int32, sicode: Int32) -> () {
         _fail(cell_ptr, sig, sicode) // mutates ActorCell to become failed
    }
}



internal class FaultHandlingDungeon {

    private static let cyan = "\u{001B}[0;36m"
    private static let red = "\u{001B}[0;31m"
    private static let reset = "\u{001B}[0;0m"

    private init() {
        // no instances
    }

//    static func withCrashHandlerInstall<M>(reaper: FaultyActorReaper.Ref, cell: inout ActorCell<M>, run: () throws -> ()) throws {
//        do {
//            try installCrashHandling(reaper: reaper, cell: &cell) // installing handler can fail, meaning we have no fault handling
//            try run()
//        } catch {
//            // if a normal swift throw happens, normal swift error catching and supervision can run
//            // we end our run though, so we have to unregister this actor from the C crash handling...
//            unregisterCrashHandling()
//            throw error
//        }
//
//    }

    static func installCrashHandling(reaper: FaultyActorReaper.Ref) throws {
        // TODO use the reaper, in every run close over it?

        let failCallback: FailCellCallback = { contextPtr, cellPtr, sig, sicode in
            assert(contextPtr != nil, "contextPointer must never be nil when running fail callback! This is a Swift Distributed Actors bug.")
            assert(cellPtr != nil, "cellPointer must never be nil when running fail callback! This is a Swift Distributed Actors bug.")

            pprint("!!!!!!!!!!!!!! contextPointer ====== \(String(describing: contextPtr))")
            pprint("!!!!!!!!!!!!!! cellPointer ====== \(String(describing: cellPtr))")

            // unwrap: protected by assertion that it may not be null above in this function
            let context = contextPtr!.assumingMemoryBound(to: WrappedFailCellClosure.self)
            pprint("~~~~~~  1111111")
//            guard let cell = cellPointer else {
//                sact_dump_backtrace()
//                fatalError("cellPointer was nil. Should never happen.")
//            }

            let pointedFailContext = context.pointee
            pprint("~~~~~~  22222 == \(pointedFailContext)")
            // unwrap: protected by assertion that it may not be null above in this function
            pointedFailContext.fail(cellPtr, sig: sig, sicode: sicode)
            pprint("~~~~~~  4444")
        }

        let handlerInstalledCode = CDungeon.sact_install_swift_crash_handler(
            // &failCellContext, // set once, globally, invoked with right cell
            failCallback
        )

        switch handlerInstalledCode {
        case 0:
            pprint("\(cyan) Installed crash handler  \(reset)")
            () // installed properly
        case EBUSY:
            pprint("\(cyan) Entering run....\(reset)")
//            pprint("[\(cellPath)] Installing crash handling failed, code: EBUSY(\(code))  ")
            // TODO: this is not really bad? We've set it we're good...
        default:
            throw FaultHandlingError.unableToInstallFaultHandlingHook(errorCode: Int(handlerInstalledCode))
        }
    }

    static func registerCellForCrashHandling<M>(stable: ActorCell<M>, cell: inout ActorCell<M>) {

        var failCellContext: WrappedFailCellClosure = .init(fail: { failingCellPtr, sig, sicode in
            assert(failingCellPtr != nil, "failingCellPointer was nil")
            print("========  111111 ==")
            print("========  111111 == \(stable)")
            let failingCellBound = failingCellPtr!.assumingMemoryBound(to: ActorCell<M>.self)
            print("========  222222")
            let failingCell = failingCellBound.pointee
            print("========  pointed = \(failingCell)")

            let error = siginfo2error(sig: sig, sicode: sicode)
            pprint("\(red) FAILED: \(error) " +
                "Parking thread to prevent undefined behavior and more damage. " +
                "Terminating actor, process remains alive with leaked thread.\(reset)")

            pprint("\(red)[\(failingCell)] FAILED.\(reset)")

            failingCell.crashFail(error: error)
        })

        withUnsafeMutablePointer(to: &cell) { cellPointer in
            pprint("register cell \(cellPointer)<\(M.self)>, and context:\(failCellContext)")
            CDungeon.sact_set_failure_handling_threadlocal_context(
                &failCellContext,
                cellPointer
            )
        }
    }

    static func unregisterCellFromCrashHandling() {
        pprint("unregister cell...")
        return CDungeon.sact_set_failure_handling_threadlocal_context(nil, nil)
    }

    func killSelfProcess() {
        print("Ship's going down, killing pid: \(getpid())")
        kill(getpid(), SIGKILL)
    }


    /// Error code will be a Linux System Error code, see:   /usr/include/asm/errno.h
    enum FaultHandlingError: Error {
        case unableToInstallFaultHandlingHook(errorCode: Int)
        case actorCrashedSignalIntercepted(er: Int)
        
        case posixError(sig: Int, sicode: Int, description: String)
    }

    private static func siginfo2error(sig: Int32, sicode _sicode: Int32) -> Error {

        // slight type wiggling on linux needed:
        #if os(Linux)
        let sicode = Int(_sicode)
        #else
        let sicode: Int32 = _sicode
        #endif

        switch (sig) {
        case SIGSEGV: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGSEGV: Segmentation Fault")
        case SIGINT: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGINT: Interactive attention signal, (usually ctrl+c)")
        case SIGFPE:
            switch (sicode) {
            case FPE_INTDIV: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (integer divide by zero)")
            case FPE_INTOVF: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (integer overflow)")
            case FPE_FLTDIV: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (floating-point divide by zero)")
            case FPE_FLTOVF: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (floating-point overflow)")
            case FPE_FLTUND: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (floating-point underflow)")
            case FPE_FLTRES: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (floating-point inexact result)")
            case FPE_FLTINV: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (floating-point invalid operation)")
            case FPE_FLTSUB: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: (subscript out of range)")
            default: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGFPE: Arithmetic Exception")
            }
        case SIGILL:
            switch (sicode) {
            case ILL_ILLOPC: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (illegal opcode)")
            case ILL_ILLOPN: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (illegal operand)")
            case ILL_ILLADR: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (illegal addressing mode)")
            case ILL_ILLTRP: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (illegal trap)")
            case ILL_PRVOPC: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (privileged opcode)")
            case ILL_PRVREG: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (privileged register)")
            case ILL_COPROC: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (coprocessor error)")
            case ILL_BADSTK: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: (internal stack error)")
            default: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGILL: Illegal Instruction")
            }
        case SIGTERM: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGTERM: a termination request was sent to the program")
        case SIGABRT: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "SIGABRT: usually caused by an abort() or assert()")
        default: return FaultHandlingError.posixError(sig: Int(sig), sicode: Int(sicode), description: "Other")
        }
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
    case failed(cause: Error, path: ActorPath)
}
