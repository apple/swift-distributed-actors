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

#include <setjmp.h>
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

/** Result of mailbox run, instructs swift part of code to perform follow up actions */
typedef enum {
    Close = -1,
    Done = 0,
    Reschedule = 1,
    Failure = 2
} CMailboxRunResult;

typedef enum {
    System = 0,
    User = 1
} ProcessedMessageType;

/*
 * Callback type for Swift interop.
 *
 * Accepts a context and message pointer.
 *
 * Returns `true` while the resulting behavior is not terminating,
 * once a message interpretation returns `false` it should be assumed
 * that the actor is terminating, and messages should be drained into
 * deadLetters.
 */
typedef bool (* InterpretMessageCallback)(void*, void*);

/* Drop message, when draining mailbox into dead letters. */
typedef void (* DropMessageCallback)(void*, void*); // TODO rename, deadletters

CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length);

void cmailbox_destroy(CMailbox* mailbox);

/* Returns if the actor should be scheduled for execution (or if it is already being scheduled) */
bool cmailbox_send_message(CMailbox* mailbox, void* envelope);

/*
 * Returns if the actor should be scheduled for execution (or if it is already being scheduled)
 *
 * Return code meaning:
 *   - res < 0 message rejected since status terminating or terminated, special handle the system message
 *   - res == 0  good, enqueued and need to schedule
 *   - res >  0  good, enqueued and no need to schedule, someone else will do so or has already
 *     FIXME: This dance is only needed since we have this c/swift dance... otherwise we would be able to know from the 1 atomic read if we're good or not and immediately act on it
 * The requirement for this stems from the fact that we must never drop system messages, e.g. watch, and always have to handle it.
 */
int cmailbox_send_system_message(CMailbox* mailbox, void* envelope);

/*
 * Performs a "mailbox run", during which system and user messages are reduced and applied to the current actor behavior.
 */
CMailboxRunResult cmailbox_run(
    CMailbox* mailbox,
    void* context, void* system_context, void* dead_letter_context, void* dead_letter_system_context,
    InterpretMessageCallback interpret_message, DropMessageCallback drop_message,
    jmp_buf* error_jmp_buf, void** failed_message, ProcessedMessageType* processing_stage);

int64_t cmailbox_message_count(CMailbox* mailbox);

/*
 * Returns `true` if the mailbox is terminating or terminated, messages should not be enqueued to it.
 * Messages can be drained to dead letters immediately, and watch messages should immediately be replied to with `.terminated`
 */
// TODO: this is a workaround... normally we do not need this additional read since send_message does this right away
// TODO: in a pure swift mailbox we'd do the 1 status read, and from that already know if we are closed or not (=> drop the messages)
bool cmailbox_is_closed(CMailbox* mailbox);

/* Sets the final CLOSED state. Should only be invoked just before finishing termination, and only while TERMINATING */
void cmailbox_set_closed(CMailbox* mailbox);

/* Sets the TERMINATING state. Should only be invoked when the actor has failed. */
void cmailbox_set_terminating(CMailbox* mailbox); // TODO naming...

int64_t sact_pthread_self();

#endif /* CMailbox_h */
