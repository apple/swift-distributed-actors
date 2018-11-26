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
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef CMailbox_h
#define CMailbox_h

#include <stdatomic.h>
#include <stdbool.h>

#include "CMPSCLinkedQueue.h"

typedef struct {
    int64_t capacity;
    int64_t max_run_length;
    _Atomic int64_t status;
    CMPSCLinkedQueue* system_messages;
    CMPSCLinkedQueue* messages;
} CMailbox;

/*
 * Callback type for Swift interop.
 *
 * Returns `true` while the resulting behavior is not terminating,
 * once a message interpretation returns `false` it should be assumed
 * that the actor is terminating, and messages should be drained into
 * deadLetters.
 */
typedef bool (* InterpretMessageCallback)(void*, void*);

CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length);

void cmailbox_destroy(CMailbox* mailbox);

/* Returns if the actor should be scheduled for execution (or if it is already being scheduled) */
bool cmailbox_send_message(CMailbox* mailbox, void* envelope);

/* Returns if the actor should be scheduled for execution (or if it is already being scheduled) */
bool cmailbox_send_system_message(CMailbox* mailbox, void* envelope);

bool cmailbox_run(CMailbox* mailbox, void* context, void* system_context, InterpretMessageCallback interpret_message);

/*
 * Returns `true` if the mailbox is terminating or terminated, messages should not be enqueued to it.
 * Messages can be drained to dead letters immediately, and watch messages should immediately be replied to with `.terminated`
 */
// TODO: this is a workaround... normally we do not need this additional read since send_message does this right away
// TODO: in a pure swift mailbox we'd do the 1 status read, and from that already know if we are closed or not (=> drop the messages)
bool cmailbox_is_closed(CMailbox* mailbox);

#endif /* CMailbox_h */
