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

#ifndef ACTORS_XPC_ACTORABLE_H
#define ACTORS_XPC_ACTORABLE_H

#include <xpc/xpc.h>
#include <xpc/connection.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>

xpc_connection_t sact_xpc_get_connection();

typedef void *SactXPCHandlerClosureContext;
typedef void (*SactXPCOnConnectionCallback)(SactXPCHandlerClosureContext, xpc_connection_t);
typedef void (*SactXPCOnMessageCallback)(SactXPCHandlerClosureContext, xpc_connection_t, xpc_object_t);

void sact_xpc_main(SactXPCHandlerClosureContext, SactXPCOnConnectionCallback, SactXPCOnMessageCallback);

#endif //ACTORS_XPC_ACTORABLE_H
