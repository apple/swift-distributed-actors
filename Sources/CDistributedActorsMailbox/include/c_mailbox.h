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

#include "swift_interop.h"
#include "c_mpsc_linked_queue.h"

// Implementation note regarding Swift-and-C inter-op for the enums:
// By defining the cases using such prefix they get imported as `.close` into Swift,
// without the prefix they end up as `.Close`. The prefix also avoids name collisions in C.

/** Used to mark in which phase of a mailbox run we are currently in. */
SWIFT_CLOSED_ENUM(MailboxRunPhase) {
    MailboxRunPhase_ProcessingSystemMessages,
    MailboxRunPhase_ProcessingUserMessages,
} MailboxRunPhase;

typedef struct {
            int64_t   capacity;
            int64_t   max_run_length;
    _Atomic int64_t   status;
    CMPSCLinkedQueue* system_messages;
    CMPSCLinkedQueue* messages;
} CMailbox;

/** Result of mailbox run, instructs swift part of code to perform follow up actions */
SWIFT_CLOSED_ENUM(MailboxRunResult) {
    MailboxRunResult_Close          = -1,
    MailboxRunResult_Done           = 0b00,
    MailboxRunResult_Reschedule     = 0b01,
    // failure and supervision:
    MailboxRunResult_Failure        = 0b10,
    MailboxRunResult_FailureRestart = 0b11,
} MailboxRunResult;

typedef void InterpretMessageClosureContext;
typedef void InterpretSystemMessageClosureContext;
typedef void DropMessageClosureContext;
typedef void SupervisionClosureContext;

/*
 * Callback for Swift interop.
 *
 * Accepts a context and message pointer.
 *
 * Returns `true` while the resulting behavior is not terminating,
 * once a message interpretation returns `false` it should be assumed
 * that the actor is terminating, and messages should be drained into
 * deadLetters.
 */
typedef bool (*InterpretMessageCallback)(DropMessageClosureContext*, void*);

/*
 * Callback for Swift interop.
 *
 * Drop message, when draining mailbox into dead letters.
 */
typedef void (*DropMessageCallback)(DropMessageClosureContext*, void*); // TODO rename, deadletters

/*
 * Callback for Swift interop.
 *
 * Accepts pointer to message which caused the failure.
 *
 * Invokes supervision, which may mutate the cell's behavior and return if we are to proceed with `Failure` or `FailureRestart`.
 */
typedef MailboxRunResult (*InvokeSupervisionCallback)(SupervisionClosureContext*, MailboxRunPhase, void*);

CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length);

/*
 * Destroy and deallocate passed in mailbox.
 */
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
MailboxRunResult cmailbox_run(
    CMailbox* mailbox,
    // message processing:
    InterpretMessageClosureContext* context, InterpretSystemMessageClosureContext* system_context,
    DropMessageClosureContext* dead_letter_context, DropMessageClosureContext* dead_letter_system_context,
    InterpretMessageCallback interpret_message, DropMessageCallback drop_message,
    // fault handling:
    jmp_buf* error_jmp_buf,
    SupervisionClosureContext* supervision_context, InvokeSupervisionCallback supervision_invoke,
    void** failed_message,
    MailboxRunPhase* run_phase
    );

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
