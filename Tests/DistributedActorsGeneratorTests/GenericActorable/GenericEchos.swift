////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift Distributed Actors open source project
////
//// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
//// Licensed under Apache License v2.0
////
//// See LICENSE.txt for license information
//// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
////
//// SPDX-License-Identifier: Apache-2.0
////
////===----------------------------------------------------------------------===//
//
//import DistributedActors
//import _Distributed
//
//distributed actor GenericEcho<M: Codable> {
//    distributed func echo(_ message: M) -> M {
//        message
//    }
//}
//// FIXME:
////
////SIL verification failed: entry point has wrong number of arguments: entry->args_size() == (fnConv.getNumIndirectSILResults() + fnConv.getNumParameters())
////In function:
////// super GenericEcho.echo(_:)
////sil [thunk] [ossa] @$s31DistributedActorsGeneratorTests11GenericEchoC4echoyxxFTd : $@convention(method) @async <M where M : Decodable, M : Encodable> (@in_guaranteed M, @guaranteed GenericEcho<M>) -> (@out M, @error Error) {
////// %0 "message"                                   // users: %20, %23
////// %1 "self"                                      // users: %20, %19, %23, %2
////  bb0(%0 : $*M, %1 : $GenericEcho<M>):
////  %2 = init_existential_ref %1 : $GenericEcho<M> : $GenericEcho<M>, $AnyObject // user: %4
////  // function_ref swift_distributed_actor_is_remote
////  %3 = function_ref @swift_distributed_actor_is_remote : $@convention(thin) (@guaranteed AnyObject) -> Bool // user: %4
////  %4 = apply %3(%2) : $@convention(thin) (@guaranteed AnyObject) -> Bool // user: %5
////  %5 = struct_extract %4 : $Bool, #Bool._value    // user: %6
////  cond_br %5, bb8, bb7                            // id: %6
////
////// %7                                             // user: %8
////  bb1(%7 : $()):                                    // Preds: bb4 bb3 bb7
////  return %7 : $()                                 // id: %8
////
////// %9                                             // user: %10
////  bb2(%9 : @owned $Error):                          // Preds: bb6 bb5
////  throw %9 : $Error                               // id: %10
////
////// %11                                            // user: %12
////  bb3(%11 : $()):                                   // Preds: bb8
////  br bb1(%11 : $())                               // id: %12
////
////// %13                                            // user: %14
////  bb4(%13 : $()):
////  br bb1(%13 : $())                               // id: %14
////
////// %15                                            // user: %16
////  bb5(%15 : @owned $Error):                         // Preds: bb8
////  br bb2(%15 : $Error)                            // id: %16
////
////// %17                                            // user: %18
////  bb6(%17 : @owned $Error):
////  br bb2(%17 : $Error)                            // id: %18
////
////  bb7:                                              // Preds: bb0
////  %19 = class_method %1 : $GenericEcho<M>, #GenericEcho.echo : <M where M : Decodable, M : Encodable> (isolated GenericEcho<M>) -> (M) -> M, $@convention(method) <τ_0_0 where τ_0_0 : Decodable, τ_0_0 : Encodable> (@in_guaranteed τ_0_0, @guaranteed GenericEcho<τ_0_0>) -> @out τ_0_0 // user: %20
////  %20 = apply %19<M>(%0, %1) : $@convention(method) <τ_0_0 where τ_0_0 : Decodable, τ_0_0 : Encodable> (@in_guaranteed τ_0_0, @guaranteed GenericEcho<τ_0_0>) -> @out τ_0_0 // user: %21
////  br bb1(%20 : $())                               // id: %21
////
////  bb8:                                              // Preds: bb0
////  // dynamic_function_ref GenericEcho._remote_echo(_:)
////  %22 = dynamic_function_ref @$s31DistributedActorsGeneratorTests11GenericEchoC12_remote_echoyxxYaKF : $@convention(method) @async <τ_0_0 where τ_0_0 : Decodable, τ_0_0 : Encodable> (@in_guaranteed τ_0_0, @guaranteed GenericEcho<τ_0_0>) -> (@out τ_0_0, @error Error) // user: %23
////  try_apply %22<M>(%0, %1) : $@convention(method) @async <τ_0_0 where τ_0_0 : Decodable, τ_0_0 : Encodable> (@in_guaranteed τ_0_0, @guaranteed GenericEcho<τ_0_0>) -> (@out τ_0_0, @error Error), normal bb3, error bb5 // id: %23
////} // end sil function '$s31DistributedActorsGeneratorTests11GenericEchoC4echoyxxFTd'
////
////Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the project and the crash backtrace.
////Stack dump:
////0.	Program arguments: /Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-09-18-a.xctoolchain/usr/bin/swift-frontend -frontend -c /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/AwaitingActorable/AwaitingActorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/ClassStructEtcActorable/ClassStructEtc+Actorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/DistributedActorsGeneratorTests.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/GenericActorable/GenericEchoWhere.swift -primary-file /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/GenericActorable/GenericEchos.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/JackOfAllTrades/JackOfAllTrades.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/LifecycleActor/LifecycleActor+Actorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/SkipCodableActorable/SkipCodableActorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/TestActorable/TestActorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/TestDistributedActor.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/TestNestedActorable/TestNestedActorable.swift /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/Tests.swift /Users/ktoso/code/swift-distributed-actors/.build/plugins/outputs/swift-distributed-actors/DistributedActorsGeneratorTests/DistributedActorsGeneratorPlugin/GeneratedDistributedActors_0.swift /Users/ktoso/code/swift-distributed-actors/.build/plugins/outputs/swift-distributed-actors/DistributedActorsGeneratorTests/DistributedActorsGeneratorPlugin/GeneratedDistributedActors_1.swift /Users/ktoso/code/swift-distributed-actors/.build/plugins/outputs/swift-distributed-actors/DistributedActorsGeneratorTests/DistributedActorsGeneratorPlugin/GeneratedDistributedActors_2.swift /Users/ktoso/code/swift-distributed-actors/.build/plugins/outputs/swift-distributed-actors/DistributedActorsGeneratorTests/DistributedActorsGeneratorPlugin/GeneratedDistributedActors_3.swift /Users/ktoso/code/swift-distributed-actors/.build/plugins/outputs/swift-distributed-actors/DistributedActorsGeneratorTests/DistributedActorsGeneratorPlugin/GeneratedDistributedActors_4.swift -emit-dependencies-path /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/DistributedActorsGeneratorTests.build/GenericActorable/GenericEchos.d -emit-reference-dependencies-path /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/DistributedActorsGeneratorTests.build/GenericActorable/GenericEchos.swiftdeps -target x86_64-apple-macosx11.0 -enable-objc-interop -sdk /Applications/Xcode-Internal.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.0.sdk -I /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug -I /Applications/Xcode-Internal.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib -F /Applications/Xcode-Internal.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks -color-diagnostics -enable-testing -g -module-cache-path /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/ModuleCache -swift-version 5 -Onone -D SWIFT_PACKAGE -D DEBUG -new-driver-path /Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-09-18-a.xctoolchain/usr/bin/swift-driver -enable-experimental-distributed -validate-tbd-against-ir=none -disable-availability-checking -resource-dir /Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-09-18-a.xctoolchain/usr/lib/swift -enable-anonymous-context-mangled-names -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/_CSwiftSyntax.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-syntax/Sources/_CSwiftSyntax/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CBacktrace.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-backtrace/Sources/CBacktrace/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CServiceDiscoveryHelpers.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-service-discovery/Sources/CServiceDiscoveryHelpers/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CNIOBoringSSLShims.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSLShims/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CNIOBoringSSL.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CNIOAtomics.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio/Sources/CNIOAtomics/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio/Sources/CNIOWindows/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CNIODarwin.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio/Sources/CNIODarwin/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CNIOLinux.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/.build/checkouts/swift-nio/Sources/CNIOLinux/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CDistributedActorsMailbox.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/Sources/CDistributedActorsMailbox/include -Xcc -fmodule-map-file=/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/CDistributedActorsAtomics.build/module.modulemap -Xcc -I -Xcc /Users/ktoso/code/swift-distributed-actors/Sources/CDistributedActorsAtomics/include -module-name DistributedActorsGeneratorTests -target-sdk-version 12.0.0 -parse-as-library -o /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/DistributedActorsGeneratorTests.build/GenericActorable/GenericEchos.swift.o -index-store-path /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/index/store -index-system-modules
////1.	Apple Swift version 5.6-dev (LLVM a29f52d415422f3, Swift db90ea20e70c92a)
////2.	Compiling with the current language version
////3.	While evaluating request ASTLoweringRequest(Lowering AST to SIL for file "/Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/GenericActorable/GenericEchos.swift")
////4.	While silgen emitDistributedThunk SIL function "@$s31DistributedActorsGeneratorTests11GenericEchoC4echoyxxFTd".
////for 'echo(_:)' (at /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/GenericActorable/GenericEchos.swift:19:17)
////5.	While verifying SIL function "@$s31DistributedActorsGeneratorTests11GenericEchoC4echoyxxFTd".
////for 'echo(_:)' (at /Users/ktoso/code/swift-distributed-actors/Tests/DistributedActorsGeneratorTests/GenericActorable/GenericEchos.swift:19:17)
////Stack dump without symbol names (ensure you have llvm-symbolizer in your PATH or set the environment var `LLVM_SYMBOLIZER_PATH` to point to it):
////0  swift-frontend           0x000000010c670527 llvm::sys::PrintStackTrace(llvm::raw_ostream&, int) + 39
////1  swift-frontend           0x000000010c66f745 llvm::sys::RunSignalHandlers() + 85
////2  swift-frontend           0x000000010c670d76 SignalHandler(int) + 278
////3  libsystem_platform.dylib 0x00007ff81d9c206d _sigtramp + 29
////4  libsystem_platform.dylib 0x00000000000000d1 _sigtramp + 18446603370084163713
////5  libsystem_c.dylib        0x00007ff81d8fed10 abort + 123
////6  swift-frontend           0x0000000107f470de (anonymous namespace)::SILVerifier::_require(bool, llvm::Twine const&, std::__1::function<void ()> const&) + 1358
////7  swift-frontend           0x0000000107f47f42 (anonymous namespace)::SILVerifier::visitSILFunction(swift::SILFunction*) + 1826
////8  swift-frontend           0x0000000107f43263 swift::SILFunction::verify(bool) const + 83
////9  swift-frontend           0x00000001082f56c0 swift::Lowering::SILGenModule::postEmitFunction(swift::SILDeclRef, swift::SILFunction*) + 224
////10 swift-frontend           0x00000001082f3262 swift::Lowering::SILGenModule::emitFunctionDefinition(swift::SILDeclRef, swift::SILFunction*) + 1858
////11 swift-frontend           0x00000001083d0df6 swift::Lowering::SILGenModule::emitDistributedThunk(swift::SILDeclRef) + 102
////12 swift-frontend           0x00000001082f6411 swift::Lowering::SILGenModule::emitAbstractFuncDecl(swift::AbstractFunctionDecl*) + 465
////13 swift-frontend           0x00000001082f2ab9 swift::Lowering::SILGenModule::emitFunction(swift::FuncDecl*) + 41
////14 swift-frontend           0x00000001083d6ea0 (anonymous namespace)::SILGenType::emitType() + 624
////15 swift-frontend           0x00000001083d6c29 swift::Lowering::SILGenModule::visitNominalTypeDecl(swift::NominalTypeDecl*) + 25
////16 swift-frontend           0x00000001082f8c84 swift::ASTLoweringRequest::evaluate(swift::Evaluator&, swift::ASTLoweringDescriptor) const + 2020
////17 swift-frontend           0x00000001083c76c6 swift::SimpleRequest<swift::ASTLoweringRequest, std::__1::unique_ptr<swift::SILModule, std::__1::default_delete<swift::SILModule> > (swift::ASTLoweringDescriptor), (swift::RequestFlags)9>::evaluateRequest(swift::ASTLoweringRequest const&, swift::Evaluator&) + 134
////18 swift-frontend           0x00000001082fd3dd llvm::Expected<swift::ASTLoweringRequest::OutputType> swift::Evaluator::getResultUncached<swift::ASTLoweringRequest>(swift::ASTLoweringRequest const&) + 413
////19 swift-frontend           0x00000001082f9bc4 swift::performASTLowering(swift::FileUnit&, swift::Lowering::TypeConverter&, swift::SILOptions const&) + 116
////20 swift-frontend           0x0000000107ca851a performCompileStepsPostSema(swift::CompilerInstance&, int&, swift::FrontendObserver*) + 618
////21 swift-frontend           0x0000000107c9d4f2 swift::performFrontend(llvm::ArrayRef<char const*>, char const*, void*, swift::FrontendObserver*) + 4850
////22 swift-frontend           0x0000000107c65932 swift::mainEntry(int, char const**) + 546
////23 dyld                     0x0000000116fd44d5 start + 421
////24 dyld                     000000000000000000 start + 18446744069028887760
////25 swift-frontend           0x0000000107c42000 __dso_handle + 0
//
//distributed actor GenericEcho2<One: Codable, Two: Codable> {
//    distributed func echoOne(_ one: One) -> One {
//        one
//    }
//
//    distributed func echoTwo(_ two: Two) -> Two {
//        two
//    }
//}
