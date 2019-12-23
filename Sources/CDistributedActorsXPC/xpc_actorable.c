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

#ifdef __APPLE__

#include <xpc/xpc.h>
#include <xpc/connection.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include "include/xpc_actorable.h"

xpc_connection_t sact_xpc_get_connection() {

    // NS XPC uses:
    // NSString *uqName = [NSString stringWithFormat:@"com.apple.NSXPCConnection.user.%@", serviceName];
    // _userQueue = dispatch_queue_create_with_target([uqName UTF8String], DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    dispatch_queue_main_t q = dispatch_get_main_queue();

    xpc_connection_t c = xpc_connection_create("com.apple.sakkana.XPCLibService", q);
    xpc_connection_set_event_handler(c, ^(xpc_object_t event) {
        pid_t pid = getpid();
//        int64_t threadId = 0;
//        pthread_threadid_np(NULL, &threadId);

        FILE* fp;
        fp = fopen("/tmp/xpc.txt", "a+");
        fprintf(fp, "[CLIENT, pid:%d] Received: %s: echo=%s    [event: %s]\n",
                pid,
//                threadId,
                (xpc_type_get_name(xpc_get_type(event))),
                xpc_dictionary_get_string(event, "echo"),
                xpc_dictionary_get_string(event, _xpc_error_key_description)
        );
        fclose(fp);
    });
    xpc_connection_set_target_queue(c, q);
    xpc_connection_resume(c);

    return c;
}

static void sact_xpc_connection_handler(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {

        pid_t pid = getpid();
        int64_t threadId = 0;
        pthread_threadid_np(NULL, &threadId);

        FILE* fp;
        fp = fopen("/tmp/xpc.txt", "a+");
        fprintf(fp, "[SERVICE, pid:%d,tid:%lld] received: %s : %s   (error: %s)\n",
                pid, threadId,
                (xpc_type_get_name(xpc_get_type(event))),
                xpc_dictionary_get_string(event, "M"),
                xpc_dictionary_get_string(event, _xpc_error_key_description)
        );
        fclose(fp);

        // reply
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(message, "echo", xpc_dictionary_get_string(event, "M"));
        xpc_connection_send_message(peer, message);
        xpc_release(message);

    });

    xpc_connection_resume(peer);
}

void sact_xpc_main(SactXPCHandlerClosureContext context, SactXPCOnConnectionCallback onConnection, SactXPCOnMessageCallback onMessage) {
    xpc_main(sact_xpc_connection_handler);
}


#endif //__APPLE__
