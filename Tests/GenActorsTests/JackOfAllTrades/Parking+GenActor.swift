// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

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

import DistributedActors
import class NIO.EventLoopFuture
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Generated Parking messages 

extension GeneratedActor.Messages {
    public enum Parking { 
        case park  
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Boxing Parking for any inheriting actorable `A` 

extension Actor where A: Parking {
    
    func park() {
self.ref.tell(A._boxParking(.park))
} 
    
}
