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

import CDistributedActorsMailbox

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// !!            THIS IS A Proof-of-Concept, the mechanism (signal hijacking+parking) is NOT A FINAL SOLUTION        !!
/// !!                                                                                                                !!
/// !! While this mechanism works, it also leaks an entire thread if an actor encounters a failure.                   !!
/// !! With this PoC we aim to show the semantics what would be modeled if we had an "unwind" feature.                !!
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// FaultHandling implementation for thread based Actors.
/// Hooks to be invoked only by the [ActorSystem] and [Mailbox].
///
/// The general flow of using the fault mechanism is as follows:
///  - 1: globally install the signal handler using [installCrashHandling]
///  - 2: for every actor mailbox run, create a failure context [createCellFailureContext],
///  - 2.5: and register it [registerCellForCrashHandling]
///  - optionally fault occurs: use the captured context to signal the fault to the actor and its watchers
///  - 3: at the successful end of a mailbox run OR occurrence of a fault, unset the context before yielding the thread
///       back to the [MessageDispatcher] using [unregisterCellFromCrashHandling].
@usableFromInline
internal struct FaultHandling {
    private init() {
        // no instances
    }

    internal static func getErrorJmpBuf() -> UnsafeMutablePointer<jmp_buf> {
        return sact_get_error_jmp_buf()
    }

    internal static func getCrashDetails() -> CrashDetails? {
        guard let cDetailsPtr = sact_get_crash_details() else {
            return nil
        }

        let cDetails = cDetailsPtr.pointee

        var backtrace: [String] = []
        backtrace.reserveCapacity(Int(cDetails.backtrace_length))

        for i in 0 ..< Int(cDetails.backtrace_length) {
            let str = String(cString: cDetails.backtrace[i]!)
            backtrace.append(str)
        }

        return CrashDetails(
            backtrace: backtrace,
            runPhase: cDetails.run_phase
        )
    }

    /// Installs the global (shared across all threads in the process) signal handler,
    /// responsible for intercepting fatal errors, such as arithmetic or other illegal operations or `fatalErrors`.
    ///
    /// The fault handler is effective only *during* an actor run, and should not trap errors made outside of actors.
    static func installCrashHandling() throws {
        let handlerInstalledCode = CDistributedActorsMailbox.sact_install_swift_crash_handler()

        switch handlerInstalledCode {
        case 0:
            () // installed properly
        default:
            throw FaultHandlingError.unableToInstallFaultHandlingHook(errorCode: Int(handlerInstalledCode))
        }
    }

    /// Register the failure context for the currently executing `ActorCell`.
    ///
    /// Important: Remember to invoke `disableFailureHandling` once the run is complete.
    internal static func enableFaultHandling() {
        CDistributedActorsMailbox.sact_enable_fault_handling() // TODO: not really needed as threadlocal
    }

    /// Clear the current cell failure context after a successful (or failed) run.
    ///
    /// Important: Always call this once a run completes, in order to avoid mistakenly invoking a cleanup action on the wrong "previous" cell.
    // Implementation notes: The reason we allow passing in the context even though we don't use it is to make sure the
    // lifetime of the context is longer than the mailbox run. Otherwise a failure may attempt using an already deallocated context.
    internal static func disableFaultHandling() {
        CDistributedActorsMailbox.sact_disable_fault_handling()
    }

    /// Convert error signal codes to their [FaultHandlingError] representation.
    /// Only exactly models those errors we do actually handle and allow recovery from, are categorized as "Other"
    private static func siginfo2error(signo: Int32, sicode _sicode: Int32) -> Error {
        // slight type wiggling on linux needed:
        #if os(Linux)
        let sicode = Int(_sicode)
        #else
        let sicode: Int32 = _sicode
        #endif

        switch signo {
        case SIGSEGV: return FaultHandlingError.E_SIGSEGV
        case SIGINT: return FaultHandlingError.E_SIGINT
        case SIGFPE:
            switch sicode {
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
            switch sicode {
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

/// Carries information regarding where a fault has occurred.
internal struct CrashDetails {
    let backtrace: [String]
    let runPhase: SActMailboxRunPhase
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
