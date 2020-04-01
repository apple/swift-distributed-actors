////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
//
// import Dispatch
// import Foundation
//
// import DistributedActors
// import CDistributedActorsMailbox
//
//
// let system = ActorSystem("LetItCrashSystem")
//
// func consumeAny<T>(_ value: T) {
//    if 2 * 12 / 2 == 12 { // to avoid compiler issued warning about infinite recursion
//        consumeAny(value)
//     } else {
//        return ()
//    }
// }
//
// func returnTrue() -> Bool {
//    return true
// }
//
// class Foo {
// }
//
//
// func crashIntegerOverflow() {
//    let x: Int8 = 127
//    consumeAny(x + (returnTrue() ? 1 : 0))
// }
//
// func crashNil() {
//    let x: Foo? = returnTrue() ? nil : Foo()
//    consumeAny(x!)
// }
//
// func crashFatalError() {
//    fatalError("deliberately crashing in fatalError")
// }
//
// func crashDivBy0() {
//    consumeAny(1 / (returnTrue() ? 0 : 1))
// }
//
// func crashViaCDanglingPointer() {
//    let x: Int = UnsafeMutableRawPointer(bitPattern: 0x8)!.load(fromByteOffset: 0, as: Int.self)
//    consumeAny(x + 1)
// }
//
// func crashArrayOutOfBounds() {
//    consumeAny(["nothing"][1])
// }
//
// func crashObjCException() {
//    #if os(macOS)
//    NSException(name: NSExceptionName("crash"),
//        reason: "you asked for it",
//        userInfo: nil).raise()
//    #endif
//    fatalError("objc exceptions only supported on macOS")
// }
//
// func crashStackOverflow() {
//    func recurse(accumulator: Int) -> Int {
//        if 2 * 12 / 2 == 12 { // to avoid compiler issued warning about infinite recursion
//            return 1 + recurse(accumulator: accumulator + 1)
//        } else {
//            return 1
//        }
//    }
//
//    consumeAny(recurse(accumulator: 0))
// }
//
// func crashOOM() {
//    #if os(macOS)
//    var datas: [Data] = []
//    var i: UInt8 = 1
//    while true == returnTrue() {
//        datas.append(Data(repeating: i, count: 1024 * 1024 * 1024))
//        i += 1
//    }
//    consumeAny(datas)
//    #endif
//    fatalError("OOM currently only supported on macOS")
// }
//
// func crashRangeFromUpperBoundWhichLessThanLowerBound() {
//    let _ = ["one", "two"].suffix(from: 3)
// }
//
// struct FooExclusivityViolation {
//    var x = 0
//
//    mutating func addAndCall(_ body: () -> Void) {
//        self.x += 1
//        body()
//    }
// }
// class BarExclusivityViolation {
//    var foo = FooExclusivityViolation(x: 0)
//
//    func doIt() {
//        self.foo.addAndCall {
//            self.foo.addAndCall {}
//        }
//    }
// }
// func crashExclusiveAccessViolation() {
// }
//
//// Results from binary compiled as: `swift build -c release`
// let crashTests = [
//
//    "integer-overflow": crashIntegerOverflow
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    // 2019-05-22T16:08:28+0900 warning: [sact://LetItCrashSystem@localhost:7337][Mailbox.swift:220][thread:5891][/user/crasher#7547311714601715076] Supervision: Actor has FAULTED while interpreting MailboxRunPhase.processingUserMessages, handling with DistributedActors.StoppingSupervisor<Swift.String>; Failure details: fault(Actor faulted while processing message '[let it crash: integer-overflow actor]:String':
//    // 0   SampleLetItCrash             0x000000010f615ef4 sact_get_backtrace + 52
//    // 1   SampleLetItCrash             0x000000010f6163f8 sact_sighandler + 88
//    // 2   libsystem_platform.dylib            0x00007fff5b5b5b5d _sigtramp + 29
//    // 3   ???                                 0x0000000000000000 0x0 + 0
//    // 4   SampleLetItCrash             0x000000010f6d8e2c $sIeg_ytIegr_TR + 12
//    // 5   SampleLetItCrash             0x000000010f996da1 $sIeg_ytIegr_TRTA + 17
//    // 6   SampleLetItCrash             0x000000010f6d8e4c $sytIegr_Ieg_TR + 12
//    // 7   SampleLetItCrash             0x000000010f999ae1 $sytIegr_Ieg_TRTA.61 + 17
//    // 8   SampleLetItCrash             0x000000010f6d8e2c $sIeg_ytIegr_TR + 12
//    // 9   SampleLetItCrash             0x000000010f999a81 $sIeg_ytIegr_TRTA.57 + 17
//    // 10  SampleLetItCrash             0x000000010f6d8e4c $sytIegr_Ieg_TR + 12
//    // 11  SampleLetItCrash             0x000000010f9996d1 $sytIegr_Ieg_TRTA + 17
//    // 12  SampleLetItCrash             0x000000010f999717 $s23DistributedActorsSampleLetItCrash4mainyyF0A5Actor8BehaviorVySSGSScfU_ + 55
//    // 13  SampleLetItCrash             0x000000010f999791 $s23DistributedActorsSampleLetItCrash4mainyyF0A5Actor8BehaviorVySSGSScfU_TA + 17
//    // 14  SampleLetItCrash             0x000000010f9997d3 $sSS12DistributedActors8BehaviorVySSGs5Error_pIeggozo_SSADsAE_pIegnozo_TR + 51
//    // 15  SampleLetItCrash             0x000000010f9998ab $sSS12DistributedActors8BehaviorVySSGs5Error_pIeggozo_SSADsAE_pIegnozo_TRTA + 27
//    // 16  SampleLetItCrash             0x000000010f8444a5 $s12DistributedActors8BehaviorV16interpretMessage7context7message4file4lineACyxGAA0B7ContextCyxG_xs12StaticStringVSutKF + 789
//    // 17  SampleLetItCrash             0x000000010f939bc0 $s12DistributedActors10SupervisorC20interpretSupervised06target7context16processingAction17nFoldFailureDepthAA8BehaviorVyxGAK_AA0B7ContextCyxGAA010ProcessingI0OyxGSitKF + 624
//    // 18  SampleLetItCrash             0x000000010f93874e $s12DistributedActors10SupervisorC20interpretSupervised06target7context16processingActionAA8BehaviorVyxGAJ_AA0B7ContextCyxGAA010ProcessingI0OyxGtKF + 110
//    // 19  SampleLetItCrash             0x000000010f938386 $s12DistributedActors10SupervisorC19interpretSupervised6target7context7messageAA8BehaviorVyxGAJ_AA0B7ContextCyxGxtKF + 566
//    // 20  SampleLetItCrash             0x000000010f805b7b $s12DistributedActors0B4CellC16interpretMessage7messageSo0B9RunResultVx_tKF + 171
//    // 21  SampleLetItCrash             0x000000010f8d75a3 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSv_SvSo0cG5PhaseVtKcfU2_ + 1395
//    // 22  SampleLetItCrash             0x000000010f8d7b26 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSv_SvSo0cG5PhaseVtKcfU2_TA + 22
//    // 23  SampleLetItCrash             0x000000010f8d5911 $s12DistributedActors30InterpretMessageClosureContext33_E5DFC6902F4D936DBD0A885E9941337FLLV4exec7cellPtr07messageP08runPhaseSo0B9RunResultVSv_SvSo07MailboxtS0VtKF + 145
//    // 24  SampleLetItCrash             0x000000010f8d54f9 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSvSg_A2OSo0cG5PhaseVtcfU_ + 745
//    // 25  SampleLetItCrash             0x000000010f8d5bf9 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSvSg_A2OSo0cG5PhaseVtcfU_To + 9
//    // 26  SampleLetItCrash             0x000000010f615407 cmailbox_run + 1207
//    // 27  SampleLetItCrash             0x000000010f8dc625 $s12DistributedActors7MailboxC3runyyF + 965
//    // 28  SampleLetItCrash             0x000000010f8e60a9 $s12DistributedActors7MailboxC3runyyFTA + 9
//    // 29  SampleLetItCrash             0x000000010f6d8e2c $sIeg_ytIegr_TR + 12
//    // 30  SampleLetItCrash             0x000000010f8d07e1 $sIeg_ytIegr_TRTA + 17
//    // 31  SampleLetItCrash             0x000000010f6d8e4c $sytIegr_Ieg_TR + 12
//    // 32  SampleLetItCrash             0x000000010f8d0911 $sytIegr_Ieg_TRTA + 17
//    // 33  SampleLetItCrash             0x000000010f8d0292 $s12DistributedActors15FixedThreadPoolCyACSiKcfcyycfU_ + 706
//    // 34  SampleLetItCrash             0x000000010f8d0381 $s12DistributedActors15FixedThreadPoolCyACSiKcfcyycfU_TA + 17
//    // 35  SampleLetItCrash             0x000000010f94ab27 $s12DistributedActors6ThreadCyACyycKcfcyycfU_ + 87
//    // 36  SampleLetItCrash             0x000000010f94abb9 $s12DistributedActors6ThreadCyACyycKcfcyycfU_TA + 25
//    // 37  SampleLetItCrash             0x000000010f94b885 $s12DistributedActors6ThreadC14runnerCallbackySvSgSvXCvgZAESvcfU_ + 277
//    // 38  SampleLetItCrash             0x000000010f94b8d9 $s12DistributedActors6ThreadC14runnerCallbackySvSgSvXCvgZAESvcfU_To + 9
//    // 39  libsystem_pthread.dylib             0x00007fff5b5be2eb _pthread_body + 126
//    // 40  libsystem_pthread.dylib             0x00007fff5b5c1249 _pthread_start + 66
//    // 41  libsystem_pthread.dylib             0x00007fff5b5bd40d thread_start + 13
//    // 2019-05-22T16:08:28+0900 error: [sact://LetItCrashSystem@localhost:7337][ActorShell.swift:374][thread:5891][/user/crasher#7547311714601715076] Actor crashing, reason: [Actor faulted while processing message '[let it crash: integer-overflow actor]:String', with backtrace]:MessageProcessingFailure. Terminating actor, process and thread remain alive.
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "force-unwrap-nil": crashNil
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "fatal-error": crashFatalError
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "div-by-0": crashDivBy0
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "via-C-dangling-pointer": crashViaCDanglingPointer
//    // Results in:
//    //
//    // Unrecoverable signal SIGSEGV(11) received! Dumping backtrace and terminating process.
//    // 0   SampleLetItCrash             0x0000000108364136 sact_dump_backtrace + 54
//    // 1   SampleLetItCrash             0x00000001083642aa sact_unrecoverable_sighandler + 74
//    // 2   libsystem_platform.dylib            0x00007fff6cde4b5d _sigtramp + 29
//    // 3   ???                                 0x0000000000000000 0x0 + 0
//    // 4   SampleLetItCrash             0x0000000108576838 main + 936
//    // 5   libdyld.dylib                       0x00007fff6cbff3d5 start + 1
//    // Segmentation fault: 11
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "array-out-of-bounds": crashArrayOutOfBounds
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "objc-exception": crashObjCException
//    // Results in (Mac):
//    //
//    // 2019-05-21 20:19:18.325 SampleLetItCrash[60642:1899971] *** Terminating app due to uncaught exception 'crash', reason: 'you asked for it'
//    // *** First throw call stack:
//    // (
//    //	 0   CoreFoundation                      0x00007fff40377cf9 __exceptionPreprocess + 256
//    //	 1   libobjc.A.dylib                     0x00007fff6b3d1a17 objc_exception_throw + 48
//    //	 2   CoreFoundation                      0x00007fff40391859 -[NSException raise] + 9
//    //	 3   SampleLetItCrash             0x0000000105663722 $s23DistributedActorsSampleLetItCrash18crashObjCExceptionyyF + 194
//    //	 4   SampleLetItCrash             0x00000001053a4c6c $sIeg_ytIegr_TR + 12
//    //	 5   SampleLetItCrash             0x0000000105664271 $sIeg_ytIegr_TRTA.24 + 17
//    //	 6   SampleLetItCrash             0x00000001053a4c8c $sytIegr_Ieg_TR + 12
//    //	 7   SampleLetItCrash             0x0000000105666931 $sytIegr_Ieg_TRTA.61 + 17
//    //	 8   SampleLetItCrash             0x00000001053a4c6c $sIeg_ytIegr_TR + 12
//    //	 9   SampleLetItCrash             0x00000001056668d1 $sIeg_ytIegr_TRTA.57 + 17
//    //	 10  SampleLetItCrash             0x0000000105665ebb $s23DistributedActorsSampleLetItCrash4mainyyF + 3483
//    //	 11  SampleLetItCrash             0x0000000105662fea main + 2026
//    //	 12  libdyld.dylib                       0x00007fff6cbff3d5 start + 1
//    // )
//    // libc++abi.dylib: terminating with uncaught exception of type NSException
//    // Abort trap: 6
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//
//    , "stack-overflow": crashStackOverflow
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "out-of-memory": crashOOM
//    // Results in:
//    //
//    // Killed: 9
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "range-upperBound-lt-lowerBound": crashRangeFromUpperBoundWhichLessThanLowerBound
//    // Results in:
//    //
//    // Illegal instruction: 4
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    //
//    // ==== ------------------------------------------------------------------------------------------------------------
//
//    , "exclusive-access-violation": crashExclusiveAccessViolation
//    // Results in:
//    //
//    // Simultaneous accesses to 0x7ffee0defa38, but modification requires exclusive access.
//    // Previous access (a modification) started at SampleLetItCrash`specialized thunk for @escaping @callee_guaranteed () -> () + 80 (0x10f144cb0).
//    // Current access (a modification) started at:
//    // 0    libswiftCore.dylib                 0x000000010f901690 swift_beginAccess + 568
//    // 1    SampleLetItCrash            0x000000010f144c60 specialized thunk for @escaping @callee_guaranteed () -> () + 107
//    // 2    SampleLetItCrash            0x000000010f145510 main() + 267
//    // 3    SampleLetItCrash            0x000000010f144490 main + 936
//    // 4    libdyld.dylib                      0x00007fff6cbff3d4 start + 1
//    // Fatal access conflict detected
//    // ==== ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//    // In Actor:
//    //
//    // 2019-05-22T09:49:15+0900 warning: [sact://LetItCrashSystem@localhost:7337][Mailbox.swift:220][thread:6147][/user/crasher#7714376079258545716] Supervision: Actor has FAULTED while interpreting MailboxRunPhase.processingUserMessages, handling with DistributedActors.StoppingSupervisor<Swift.String>; Failure details: fault(Actor faulted while processing message '[let it crash: exclusive-access-violation actor]:String':
//    // 0   SampleLetItCrash             0x00000001011c5f65 sact_get_backtrace + 53
//    // 1   SampleLetItCrash             0x00000001011c62ec sact_sighandler + 60
//    // 2   libsystem_platform.dylib            0x00007fff6cde4b5d _sigtramp + 29
//    // 3   ???                                 0x00007000020c25e0 0x0 + 123145336661472
//    // 4   libsystem_c.dylib                   0x00007fff6cca46a6 abort + 127
//    // 5   libswiftCore.dylib                  0x0000000101b99445 _ZN5swift10fatalErrorEjPKcz + 149
//    // 6   libswiftCore.dylib                  0x0000000101b99975 swift_beginAccess + 741
//    // 7   SampleLetItCrash             0x00000001013d8a4b $sIeg_ytIegr_TR61$s23DistributedActorsSampleLetItCrash29crashExclusiveAccessViolationyyFTf3npf_n + 107
//    // 8   SampleLetItCrash             0x00000001013da151 $sytIegr_Ieg_TRTA + 17
//    // 9   SampleLetItCrash             0x00000001013da179 $s23DistributedActorsSampleLetItCrash4mainyyF0A5Actor8BehaviorVySSGSScfU_TA + 25
//    // 10  SampleLetItCrash             0x00000001013da1bf $sSS12DistributedActors8BehaviorVySSGs5Error_pIeggozo_SSADsAE_pIegnozo_TRTA + 31
//    // 11  SampleLetItCrash             0x000000010130a873 $s12DistributedActors8BehaviorV16interpretMessage7context7message4file4lineACyxGAA0B7ContextCyxG_xs12StaticStringVSutKF + 819
//    // 12  SampleLetItCrash             0x00000001013af0e7 $s12DistributedActors10SupervisorC20interpretSupervised06target7context16processingAction17nFoldFailureDepthAA8BehaviorVyxGAK_AA0B7ContextCyxGAA010ProcessingI0OyxGSitKFTf4nnndn_n + 359
//    // 13  SampleLetItCrash             0x00000001013ab38d $s12DistributedActors10SupervisorC19interpretSupervised6target7context7messageAA8BehaviorVyxGAJ_AA0B7ContextCyxGxtKF + 157
//    // 14  SampleLetItCrash             0x00000001012db7a5 $s12DistributedActors0B4CellC16interpretMessage7messageSo0B9RunResultVx_tKF + 133
//    // 15  SampleLetItCrash             0x000000010136bbfc $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSv_SvSo0cG5PhaseVtKcfU2_ + 236
//    // 16  SampleLetItCrash             0x000000010137208c $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSv_SvSo0cG5PhaseVtKcfU2_TA + 12
//    // 17  SampleLetItCrash             0x000000010136b77a $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0bG6ResultVSvSg_A2OSo0cG5PhaseVtcfU_ + 106
//    // 18  SampleLetItCrash             0x00000001011c5927 cmailbox_run + 631
//    // 19  SampleLetItCrash             0x000000010136d3aa $s12DistributedActors7MailboxC3runyyF + 378
//    // 20  SampleLetItCrash             0x00000001013688b1 $sIeg_ytIegr_TRTA + 17
//    // 21  SampleLetItCrash             0x0000000101368b49 $s12DistributedActors15FixedThreadPoolCyACSiKcfcyycfU_ + 649
//    // 22  SampleLetItCrash             0x00000001013b3599 $s12DistributedActors6ThreadCyACyycKcfcyycfU_ + 41
//    // 23  SampleLetItCrash             0x00000001013b3b40 $s12DistributedActors6ThreadC14runnerCallbackySvSgSvXCvgZAESvcfU_To + 32
//    // 24  libsystem_pthread.dylib             0x00007fff6cded2eb _pthread_body + 126
//    // 25  libsystem_pthread.dylib             0x00007fff6cdf0249 _pthread_start + 66
//    // 26  libsystem_pthread.dylib             0x00007fff6cdec40d thread_start + 13
//    // Unrecoverable signal SIGSEGV(11) received! Dumping backtrace and terminating process.
//    // 0   SampleLetItCrash             0x00000001011c5eb6 sact_dump_backtrace + 54
//    // 1   SampleLetItCrash             0x00000001011c602a sact_unrecoverable_sighandler + 74
//    // 2   libsystem_platform.dylib            0x00007fff6cde4b5d _sigtramp + 29
//    // 3   ???                                 0x000000010231b200 0x0 + 4331778560
//    // 4   SampleLetItCrash             0x000000010136cb00 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0cG6ResultVAA11SupervisionV7FailureO_So0cG5PhaseVtKcfU8_ + 1056
//    // 5   SampleLetItCrash             0x0000000101372271 $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0cG6ResultVAA11SupervisionV7FailureO_So0cG5PhaseVtKcfU8_TA + 17
//    // 6   SampleLetItCrash             0x000000010136ba3f $s12DistributedActors7MailboxC4cell8capacity12maxRunLengthACyxGAA0B4CellCyxG_s6UInt32VALtcfcSo0cG6ResultVSvSg_So0cG5PhaseVAOtcfU1_ + 351
//    // 7   SampleLetItCrash             0x00000001011c5748 cmailbox_run + 152
//    // 8   SampleLetItCrash             0x000000010136d3aa $s12DistributedActors7MailboxC3runyyF + 378
//    // 9   SampleLetItCrash             0x00000001013688b1 $sIeg_ytIegr_TRTA + 17
//    // 10  SampleLetItCrash             0x0000000101368b49 $s12DistributedActors15FixedThreadPoolCyACSiKcfcyycfU_ + 649
//    // 11  SampleLetItCrash             0x00000001013b3599 $s12DistributedActors6ThreadCyACyycKcfcyycfU_ + 41
//    // 12  SampleLetItCrash             0x00000001013b3b40 $s12DistributedActors6ThreadC14runnerCallbackySvSgSvXCvgZAESvcfU_To + 32
//    // 13  libsystem_pthread.dylib             0x00007fff6cded2eb _pthread_body + 126
//    // 14  libsystem_pthread.dylib             0x00007fff6cdf0249 _pthread_start + 66
//    // 15  libsystem_pthread.dylib             0x00007fff6cdec40d thread_start + 13
//    // Segmentation fault: 11
//    // ==== ------------------------------------------------------------------------------------------------------------
// ]
//
// func help() {
//    let program = CommandLine.arguments[0]
//    print("LetItCrash: Choose one of the following options:")
//    for key in crashTests.keys {
//        print("  \(program) \(key)")
//        print("  \(program) \(key) actor")
//    }
//    print("")
//    print("or all of them:")
//    print("  for f in \(crashTests.keys.joined(separator: " ")); do echo \"$f\"; \(program) \"$f\"; done")
//    print("or all of them (inside an actor):")
//    print("  for f in \(crashTests.keys.joined(separator: " ")); do echo \"$f >>>\"; \(program) \"$f\" actor; done")
// }
//
// func main() {
//    let crasher = (crashTests[CommandLine.arguments.suffix(from: 1).first ?? "help"] ?? help)
//
//    if CommandLine.arguments.count > 1 && CommandLine.arguments.suffix(from: 2).first == "actor" {
//        let ref: ActorRef<String> = try! system.spawn("crasher", .receiveMessage { _ in
//            crasher() // wrap crasher in actor and "let it crash!"
//            return .same
//        })
//        ref.tell("let it crash: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
//
//        sleep(3)
//    } else {
//        crasher() // invoke crasher directly
//    }
// }
//
// main()
