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

// context wrapper for c-interop
internal struct CellFailureContext {
    private let _fail: (Int32, Int32) -> ()

    init(fail: @escaping (Int32, Int32) -> ()) {
        self._fail = fail
    }

    @inlinable
    func fail(signo: Int32, sicode: Int32) -> () {
         _fail(signo, sicode)
    }
}

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// !!            THIS IS A Proof-of-Concept, the mechanisms (signal hijacking+parking) is NOT A FINAL SOLUTION       !!
/// !!                                                                                                                !!
/// !! While this mechanism works, it also leaks an entire thread if an actor encounters a failure.                   !!
/// !! With this PoC we aim to show the semantics what would be modeled if we had an "unwind" feature.                !!
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// FaultHandling implementation for thread based Actors.
/// Hooks to be invoked only by the [ActorSystem] and [Mailbox].
internal struct FaultHandling {

    private init() {
        // no instances
    }

    /// Installs the global (shared across all threads in the process) signal handler,
    /// responsible for intercepting fatal errors, such as arithmetic or other illegal operations or `fatalErrors`.
    ///
    ///
    /// The fault handler is effective only *during* an actor run, and should not trap errors made outside of actors.
    static func installCrashHandling(reaper: FaultyActorReaper.Ref) throws {
        // TODO use the reaper, in every run close over it?

        // c-function inter-op closure, can't close over state; state is carried in the contextPtr
        let failCallback: FailCellCallback = { contextPtr, sig, sicode in
            assert(contextPtr != nil, "contextPointer must never be nil when running fail callback! This is a Swift Distributed Actors bug.")

            // safe unwrap: protected by assertion above, and we always pass in a valid pointer
            let context = contextPtr!.assumingMemoryBound(to: CellFailureContext.self)
            context.pointee.fail(signo: sig, sicode: sicode)
        }

        let handlerInstalledCode = CDungeon.sact_install_swift_crash_handler(failCallback)

        switch handlerInstalledCode {
        case 0:
            () // installed properly
        case EBUSY:
            () // not a problem, we installed the handler previously already
        default:
            throw FaultHandlingError.unableToInstallFaultHandlingHook(errorCode: Int(handlerInstalledCode))
        }
    }

    // TODO add a test that a crash outside of an actor still crashes like expected?
    //      I guess we can't really test for that...
    
    internal static func createCellFailureContext<M>(cell: ActorCell<M>) -> CellFailureContext {
        return .init(fail: { signo, sicode in
            defer { FaultHandling.unregisterCellFromCrashHandling(context: nil) }
            let failingCell: ActorCell<M> = cell
            let error = FaultHandling.siginfo2error(signo: signo, sicode: sicode)
            failingCell.crashFail(error: error)
        })
    }

    internal static func registerCellForCrashHandling(context: inout CellFailureContext) {
        CDungeon.sact_set_failure_handling_threadlocal_context(&context) // TODO not really needed as threadlocal
    }

    // Implementation notes: The reason we allow passing in the context even though we don't use it is to make sure the
    // lifetime of the context is longer than the mailbox run. Otherwise a failure may attempt using an already deallocated context.
    internal static func unregisterCellFromCrashHandling(context: CellFailureContext?) {
        _ = context // "use it"
        CDungeon.sact_clear_failure_handling_threadlocal_context()
    }

    private func killSelfProcess() {
        print("Ship's going down, killing pid: \(getpid())")
        kill(getpid(), SIGKILL)
    }

    private static func siginfo2error(signo: Int32, sicode _sicode: Int32) -> Error {
        // slight type wiggling on linux needed:
        #if os(Linux)
        let sicode = Int(_sicode)
        #else
        let sicode: Int32 = _sicode
        #endif

        switch (signo) {
        case SIGSEGV: return FaultHandlingError.E_SIGSEGV
        case SIGINT: return FaultHandlingError.E_SIGINT
        case SIGFPE:
            switch (sicode) {
            case FPE_INTDIV: return FaultHandlingError.E_SIGFPE_FPE_INTDIV
            case FPE_INTOVF: return FaultHandlingError.E_SIGFPE_FPE_INTOVF
            case FPE_FLTDIV: return FaultHandlingError.E_SIGFPE_FPE_FLTDIV
            case FPE_FLTOVF: return FaultHandlingError.E_SIGFPE_FPE_FLTOVF
            case FPE_FLTUND: return FaultHandlingError.E_SIGFPE_FPE_FLTUND
            case FPE_FLTRES: return FaultHandlingError.E_SIGFPE_FPE_FLTRES
            case FPE_FLTINV: return FaultHandlingError.E_SIGFPE_FPE_FLTINV
            case FPE_FLTSUB: return FaultHandlingError.E_SIGFPE_FPE_FLTSUB
            default: return FaultHandlingError.posixFailure(signo: Int(signo), sicode: Int(sicode), description: "SIGFPE: Arithmetic Exception")
            }
        case SIGILL:
            switch (sicode) {
            case ILL_ILLOPC: return FaultHandlingError.E_SIGILL_ILL_ILLOPC
            case ILL_ILLOPN: return FaultHandlingError.E_SIGILL_ILL_ILLOPN
            case ILL_ILLADR: return FaultHandlingError.E_SIGILL_ILL_ILLADR
            case ILL_ILLTRP: return FaultHandlingError.E_SIGILL_ILL_ILLTRP
            case ILL_PRVOPC: return FaultHandlingError.E_SIGILL_ILL_PRVOPC
            case ILL_PRVREG: return FaultHandlingError.E_SIGILL_ILL_PRVREG
            case ILL_COPROC: return FaultHandlingError.E_SIGILL_ILL_COPROC
            case ILL_BADSTK: return FaultHandlingError.E_SIGILL_ILL_BADSTK
            default: return FaultHandlingError.posixFailure(signo: Int(signo), sicode: Int(sicode), description: "SIGILL: Illegal Instruction")
            }
        case SIGTERM: return FaultHandlingError.E_SIGTERM
        case SIGABRT: return FaultHandlingError.E_SIGABRT
        default: return FaultHandlingError.posixFailure(signo: Int(signo), sicode: Int(sicode), description: "Other")
        }
    }
}

/// Error related to, or failure "caught" by the failure handling mechanism.
enum FaultHandlingError: Error {
    case unableToInstallFaultHandlingHook(errorCode: Int)

    /// A failure is an not recoverable error condition, such as a division by zero other illegal operation.
    /// Failure handling supervises such errors and stops the faulty actor, notifying about the fault condition.
    case posixFailure(signo: Int, sicode: Int?, description: String)

    static let E_SIGSEGV = FaultHandlingError.posixFailure(signo: Int(SIGSEGV), sicode: nil, description: "SIGSEGV: Segmentation Fault")
    static let E_SIGINT = FaultHandlingError.posixFailure(signo: Int(SIGINT), sicode: nil, description: "SIGINT: Interactive attention signal, (usually ctrl+c)")

    static let E_SIGILL_ILL_ILLOPC = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_ILLOPC), description: "SIGILL: (illegal opcode)")
    static let E_SIGILL_ILL_ILLOPN = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_ILLOPN), description: "SIGILL: (illegal operand)")
    static let E_SIGILL_ILL_ILLADR = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_ILLADR), description: "SIGILL: (illegal addressing mode)")
    static let E_SIGILL_ILL_ILLTRP = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_ILLTRP), description: "SIGILL: (illegal trap)")
    static let E_SIGILL_ILL_PRVOPC = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_PRVOPC), description: "SIGILL: (privileged opcode)")
    static let E_SIGILL_ILL_PRVREG = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_PRVREG), description: "SIGILL: (privileged register)")
    static let E_SIGILL_ILL_COPROC = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_COPROC), description: "SIGILL: (coprocessor error)")
    static let E_SIGILL_ILL_BADSTK = FaultHandlingError.posixFailure(signo: Int(SIGILL), sicode: Int(ILL_BADSTK), description: "SIGILL: (internal stack error)")

    static let E_SIGFPE_FPE_INTDIV = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_INTOVF), description: "SIGFPE: (integer divide by zero)")
    static let E_SIGFPE_FPE_INTOVF = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_INTOVF), description: "SIGFPE: (integer overflow)")
    static let E_SIGFPE_FPE_FLTDIV = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTDIV), description: "SIGFPE: (floating-point divide by zero)")
    static let E_SIGFPE_FPE_FLTOVF = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTDIV), description: "SIGFPE: (floating-point overflow)")
    static let E_SIGFPE_FPE_FLTUND = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTOVF), description: "SIGFPE: (floating-point underflow)")
    static let E_SIGFPE_FPE_FLTRES = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTRES), description: "SIGFPE: (floating-point inexact result)")
    static let E_SIGFPE_FPE_FLTINV = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTINV), description: "SIGFPE: (floating-point invalid operation)")
    static let E_SIGFPE_FPE_FLTSUB = FaultHandlingError.posixFailure(signo: Int(SIGFPE), sicode: Int(FPE_FLTSUB), description: "SIGFPE: (subscript out of range)")

    static let E_SIGTERM = FaultHandlingError.posixFailure(signo: Int(SIGTERM), sicode: nil, description: "SIGTERM: a termination request was sent to the program")
    static let E_SIGABRT = FaultHandlingError.posixFailure(signo: Int(SIGABRT), sicode: nil, description: "SIGABRT: usually caused by an abort() or assert()")
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

