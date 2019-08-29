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

#include <math.h>
#include <stdio.h>
#include <pthread.h>
#include <execinfo.h>
#include <inttypes.h>

#include "include/c_mailbox.h"
#include "include/itoa.h"

// Implementation notes:
// State should be operated on bitwise; where the specific bits signify states like the following:
//      0 - has system messages
//      1 - currently processing system messages
//   2-33 - user message count
//     34 - message count overflow (important because we increment the counter first and then check if the mailbox was already full)
//  35-60 - reserved
//     61 - mailbox is suspended and will not process any user messages
//     62 - terminating (or closed)
//     63 - closed, terminated (for sure)
// Activation count is special in the sense that we use it as follows, it's value being:
// 0 - inactive, not scheduled and no messages to process
// 1 - active without(!) normal messages, only system messages are to be processed
// n - there are (n >> 1) messages to process + system messages if LSB is set
//
// Note that this implementation allows, using one load, to know:
// - if the actor is running right now (so the mailbox size will be decremented shortly),
// - current mailbox size (nr. of enqueued messages, which can be used for scheduling and/or metrics)
// - if we need to schedule it or not since it was scheduled already etc.

#define ACTIVATIONS                 0b0000000000000000000000000000011111111111111111111111111111111111

#define HAS_SYSTEM_MESSAGES         0b0000000000000000000000000000000000000000000000000000000000000001
#define PROCESSING_SYSTEM_MESSAGES  0b0000000000000000000000000000000000000000000000000000000000000010

// Implementation notes about Termination:
// Termination MUST first set TERMINATING and only after add the "final" CLOSED state.
// In other words, the only legal bit states a mailbox should observe are:
//  -> 0b000... alive,
//  -> 0b001... suspended (actor is waiting for completion of AsyncResult and will only process system messages until then),
//  -> 0b010... terminating,
//  -> 0b110... closed (also known as: "terminated", "dead")
//
// Meaning that `0b100...` is NOT legal.
#define SUSPENDED                   0b0010000000000000000000000000000000000000000000000000000000000000
#define TERMINATING                 0b0100000000000000000000000000000000000000000000000000000000000000
#define CLOSED                      0b1000000000000000000000000000000000000000000000000000000000000000

// user message count is stored in bits 2-61, so when incrementing or
// decrementing the message count, we need to add starting at bit 2
#define SINGLE_USER_MESSAGE_MASK    0b0000000000000000000000000000000000000000000000000000000000000100

// Mask to use with XOR on the status to unset the 'has system messages' bit
// and set the 'is processing system messages' bit in a single atomic operation
#define BECOME_SYS_MSG_PROCESSING_XOR_MASK 0b11

// used to unset the SUSPENDED bit by ANDing with status
//
// assume we are suspended and have some system messages and 7 user messages enqueued:
//      CURRENT STATUS              0b0010000000000000000000000000000000000000000000000000000000011101
//      (operation)               &
#define UNSUSPEND_MASK              0b1101111111111111111111111111111111111111111111111111111111111111
//                                --------------------------------------------------------------------
//                                = 0b0000000000000000000000000000000000000000000000000000000000011101

int64_t increment_status_activations(CSActMailbox* mailbox);

int64_t decrement_status_activations(CSActMailbox* mailbox, int64_t n);

int64_t try_activate(CSActMailbox* mailbox);

int64_t activations(int64_t status);

// even though the message count is just 32 bit, we need to capture the overflow bit as well, so we return it as a 64 bit value
uint64_t message_count(int64_t status);

int64_t set_status_terminating(CSActMailbox* mailbox);

int64_t set_status_terminated_dead(CSActMailbox* mailbox);

int64_t set_status_suspended(CSActMailbox* mailbox);
int64_t reset_status_suspended(CSActMailbox* mailbox);

int64_t set_processing_system_messages(CSActMailbox* mailbox);


void print_debug_status(CSActMailbox* mailbox, char* msg);

int64_t get_status(CSActMailbox* mailbox);

bool has_activations(int64_t status);

bool has_system_messages(int64_t status);

bool is_terminating(int64_t status);
bool is_not_terminating(int64_t status);
bool is_suspended(int64_t status);
bool is_processing_or_has_system_messages(int64_t status);

bool is_closed(int64_t status);

bool internal_send_message(CSActMailbox* mailbox, void* envelope, bool is_system_message);

uint32_t max(uint32_t a, uint32_t b);

CSActMailbox* cmailbox_create(uint32_t capacity, uint32_t max_run_length) {
    CSActMailbox* mailbox = calloc(sizeof(CSActMailbox), 1);
    mailbox->capacity = capacity;
    mailbox->max_run_length = max_run_length;
    mailbox->messages = c_sact_mpsc_linked_queue_create();
    mailbox->system_messages = c_sact_mpsc_linked_queue_create();

    return mailbox;
}

void cmailbox_destroy(CSActMailbox* mailbox) {
    c_sact_mpsc_linked_queue_destroy(mailbox->system_messages);
    c_sact_mpsc_linked_queue_destroy(mailbox->messages);
    free(mailbox);
}

SActMailboxEnqueueResult cmailbox_send_message(CSActMailbox* mailbox, void* envelope) {
    int64_t old_status = increment_status_activations(mailbox);
    int64_t old_activations = activations(old_status);
    CSActMPSCLinkedQueue* queue = mailbox->messages;
    // printf("[SACT_TRACE_MAILBOX][c] enter send_message; messages in queue: %lu\n", (message_count(old_status)));

    if ((message_count(old_status) >= mailbox->capacity)) {
        // If we passed the maximum capacity of the user queue, we can't enqueue more
        // items and have to decrement the activations count again. This is not racy,
        // because we only process messages if the queue actually contains them (does
        // not return NULL), so even if messages get processed concurrently, it's safe
        // to decrement here.
        decrement_status_activations(mailbox, SINGLE_USER_MESSAGE_MASK);
        print_debug_status(mailbox, "cmailbox_send_message mailbox full...");
        return SActMailboxEnqueueResult_mailboxFull;
    } else if (is_terminating(old_status)) {
        decrement_status_activations(mailbox, SINGLE_USER_MESSAGE_MASK);
        print_debug_status(mailbox, "cmailbox_send_message mailbox closed...");
        return SActMailboxEnqueueResult_mailboxClosed;
    } else {
        // If the mailbox is not full, we insert it into the queue and return,
        // whether this was the first activation, to signal the need to enqueue
        // this mailbox.
        c_sact_mpsc_linked_queue_enqueue(queue, envelope);
        print_debug_status(mailbox, "cmailbox_send_message enqueued");

        if (old_activations == 0 && !is_suspended(old_status)) {
            return SActMailboxEnqueueResult_needsScheduling;
        } else {
            return SActMailboxEnqueueResult_alreadyScheduled;
        }
    }
}

SActMailboxEnqueueResult cmailbox_send_system_message(CSActMailbox* mailbox, void* sys_msg) {
    // The ordering of enqueue/activate calls is tremendously important here and MUST NOT be inversed.
    //
    // Unlike user messages, where the message count is stored, here we first enqueue and then activate.
    // This MAY result in an enqueue into a terminating or even closed mailbox.
    // This is only during the period of time between terminating->closed->cell-released however.
    //
    // We can enqueue "too much", and elements remain in the queue until we get deallocated.
    //
    // Note: The problem with `activate then enqueue` is that it allows for the following race condition to happen:
    //   A0: is processing messages; before ending a run we see if any more system messages are to be processed
    //   (A1 attempts sending message to A0)
    //   A1: send_system_message, try_activate succeeds
    //   A0: notices, that there's more system messages to run, so attempts to do so
    //   !!: A1 did not yet enqueue the system message
    //   A0: falls of a cliff, does not process the system message
    //   A1: enqueues the system message and
    //
    // TODO: If we used some bits for system message queue count, we could avoid this issue... Consider this at some point perhaps
    //
    // TODO: Alternatively locking on system message things could be a solution... Though heavy one.

    // TODO: This is not a full solution, however lessens the amount of instances in which we may enqueue to a terminating actor
    // This additional atomic read on every system send helps to avoid enqueueing indefinitely to terminating/closed mailbox
    // however is not strong enough guarantee to disallow that no such enqueue ever happens (status could be changed just
    // after we check it and decide to enqueue, though then the try_activate will yield the right status so we will dead letter
    // the message in any case -- although having enqueued the message already. Where it MAY remain until cell is deallocated,
    // if the enqueue happened after terminated is set, but tombstone is enqueued.
    if (is_terminating(get_status(mailbox))) {
        print_debug_status(mailbox, "Attempted system enqueue at TERMINATING mailbox, bailing out without enqueue");
        return SActMailboxEnqueueResult_mailboxTerminating;
    }

    // yes, on purpose enqueue before activating
    CSActMPSCLinkedQueue* queue = mailbox->system_messages;
    c_sact_mpsc_linked_queue_enqueue(queue, sys_msg);

    int64_t old_status = try_activate(mailbox); // only activation matters
    int64_t old_activations = activations(old_status);

    if (is_terminating(old_status)) {
        // we are either Terminating or CLOSED, either way, we shall not accept any messages and these must be dropped.
        print_debug_status(mailbox, "cmailbox_send_system_message mailbox closed");
        return SActMailboxEnqueueResult_mailboxTerminating;
    } else {

        if (old_activations == 0) {
            // "should activate"
            print_debug_status(mailbox, "cmailbox_send_system_message enqueued; should activate, needs scheduling");
            return SActMailboxEnqueueResult_needsScheduling;
        } else if (is_suspended(old_status) && !is_processing_or_has_system_messages(old_status)) {
            // "should wake up from suspension"
            print_debug_status(mailbox, "cmailbox_send_system_message enqueued; is suspended, needs scheduling");
            return SActMailboxEnqueueResult_needsScheduling;
        } else {
            print_debug_status(mailbox, "cmailbox_send_system_message enqueued; already scheduled");
            return SActMailboxEnqueueResult_alreadyScheduled;
        }
    }
}

SActMailboxEnqueueResult cmailbox_send_system_tombstone(CSActMailbox* mailbox, void* tombstone) {
    int64_t old_status = try_activate(mailbox); // might as well, though we should KNOW that we are in the middle of a run and still this is activated

    if (is_terminating(old_status)) {
        CSActMPSCLinkedQueue* queue = mailbox->system_messages;
        c_sact_mpsc_linked_queue_enqueue(queue, tombstone);

        return SActMailboxEnqueueResult_mailboxTerminating;
    } else {
        print_debug_status(mailbox, "!!!!!!!! ATTEMPTED TO ENQUEUE TOMBSTONE TO ALIVE ACTOR THIS IS SUPER BAD !!!!!!!!");
        return SActMailboxEnqueueResult_mailboxFull;
    }
}

// TODO: was boolean for need to schedule, but we need to signal to swift that termination things should now happen
// and we may only do this AFTER the cmailbox has set the status to terminating, otherwise we get races on insertion to queues...
SActMailboxRunResult cmailbox_run(
      CSActMailbox* mailbox,
      void* cell,
      // message processing:
      SActInterpretMessageClosureContext context, SActInterpretSystemMessageClosureContext system_context,
      SActDropMessageClosureContext dead_letter_context, SActDropMessageClosureContext dead_letter_system_context,
      SActInterpretMessageCallback interpret_message, SActDropMessageCallback drop_message) {
    void* message = NULL;
    print_debug_status(mailbox, "Entering run");

    int64_t status = set_processing_system_messages(mailbox);

    int64_t processed_activations = has_system_messages(status) ? PROCESSING_SYSTEM_MESSAGES : 0;
    // TODO: more smart scheduling decisions (smart batching), though likely better on dispatcher layer
    uint32_t run_length = max(message_count(status), mailbox->max_run_length);

    // printf("[SACT_TRACE_MAILBOX][c] run_length = %lu\n", run_length);

    // only an keep_running actor shall continue running;
    // e.g. once .terminate is received, the actor should drain all messages to the dead letters queue
    // TODO rename ActorRunResult -- the mailbox run is "the run", this is more like the actors per reduction directive... need to not overload the name "run"
    SActActorRunResult run_result = SActActorRunResult_continueRunning; // TODO: hijack the run_length, and reformulate it as "fuel", and set it to zero when we need to stop
    if (is_suspended(status)) {
        run_result = SActActorRunResult_shouldSuspend;
    }

    // run system messages -----------------------------------------------------------------------------------------
    SActMailboxRunPhase run_phase = SActMailboxRunPhase_ProcessingSystemMessages;
    if (has_system_messages(status)) {
        message = c_sact_mpsc_linked_queue_dequeue(mailbox->system_messages);

        while (message != NULL &&
               (run_result != SActActorRunResult_shouldStop && run_result != SActActorRunResult_closed)) {
            // printf("[SACT_TRACE_MAILBOX][c] Processing system message...\n");
            run_result = interpret_message(system_context, cell, message, run_phase);
            message = c_sact_mpsc_linked_queue_dequeue(mailbox->system_messages);
        }

        // was our run was interrupted by a system message initiating a stop?
        if (run_result == SActActorRunResult_shouldStop || run_result == SActActorRunResult_closed) {

            if (is_not_terminating(status)) {
                // avoid unnecessarily setting the terminating bit again
                set_status_terminating(mailbox);
            }

            // Since we are terminating, and bailed out from a system run, there may be
            // pending system messages in the queue still; we want to finish this run till they are drained.
            //
            // Never run user messages before draining system messages, system messages must be processed with priority,
            // since they include setting up watch/unwatch as well as the tombstone which should be the last thing we process.
            if (message == NULL) {
                message = c_sact_mpsc_linked_queue_dequeue(mailbox->system_messages);
            }
            while (message != NULL) {
                print_debug_status(mailbox, "CLOSED, yet pending system messages still made it in... draining...");
                // drain all messages to dead letters
                // this is very important since dead letters will handle any posthumous watches for us
                drop_message(dead_letter_system_context, message);

                message = c_sact_mpsc_linked_queue_dequeue(mailbox->system_messages);
            }
        }
    }
    // end of system messages run ----------------------------------------------------------------------------------

    // suspension logic --------------------------------------------------------------------------------------------

    if (is_suspended(status) && run_result != SActActorRunResult_shouldSuspend) {
        // the actor was previously suspended, but has been unsuspended, so we
        // need to reset the SUSPENDED bit in the status to continue processing
        // user messages
        reset_status_suspended(mailbox);
    } else if (!is_suspended(status) && run_result == SActActorRunResult_shouldSuspend) {
        set_status_suspended(mailbox);
        print_debug_status(mailbox, "MARKED SUSPENDED");
    }

    // run user messages -------------------------------------------------------------------------------------------

    if (run_result == SActActorRunResult_continueRunning) {
        run_phase = SActMailboxRunPhase_ProcessingUserMessages;
        message = c_sact_mpsc_linked_queue_dequeue(mailbox->messages);

        while (message != NULL && (run_result == SActActorRunResult_continueRunning)) {
            // we need to add 2 to processed_activations because the user message count is stored
            // shifted by 1 in the status and we use the same field to clear the
            // system message bit
            processed_activations += SINGLE_USER_MESSAGE_MASK;
            // printf("[SACT_TRACE_MAILBOX][c] Processing user message...\n");
            // TODO: fix this dance
            run_result = interpret_message(context, cell, message, run_phase); // TODO: we can optimize the keep_running into the processed counter?

            // TODO: optimize all this branching into riding on the processed_activations perhaps? we'll see later on -- ktoso
            if ((run_result == SActActorRunResult_shouldStop) && !is_terminating(status)) {
                // printf("[SACT_TRACE_MAILBOX][c] STOPPING BASED ON MESSAGE INTERPRETATION\n");
                set_status_terminating(mailbox);
                print_debug_status(mailbox, "MARKED TERMINATING");
                message = NULL; // break out of the loop
            } else if (run_result == SActActorRunResult_shouldSuspend) {
                set_status_suspended(mailbox);
                print_debug_status(mailbox, "MARKED SUSPENDED");
                message = NULL;
            } else if (processed_activations >= run_length) {
                message = NULL; // break out of the loop
            } else {
                // dequeue another message, if there are no more messages left, message
                // will contain NULL and terminate the loop
                message = c_sact_mpsc_linked_queue_dequeue(mailbox->messages);
            }
        }
    } else if (run_result == SActActorRunResult_shouldSuspend) {
        print_debug_status(mailbox, "MAILBOX SUSPENDED, SKIPPING USER MESSAGE PROCESSING");
    } else /* we are terminating and need to drain messages */ {
        // TODO: drain them to dead letters

        // TODO: drainToDeadLetters(mailbox->messages) {
        message = c_sact_mpsc_linked_queue_dequeue(mailbox->messages);
        while (message != NULL) {
            drop_message(dead_letter_context, message);
            processed_activations += SINGLE_USER_MESSAGE_MASK;
            message = c_sact_mpsc_linked_queue_dequeue(mailbox->messages); // keep draining
        }
    }

    // we finished without a failure, so we unset the message ptr
    message = NULL;

    // printf("[SACT_TRACE_MAILBOX][c] ProcessedActivations %lu messages...\n", processed_activations);

    int64_t old_status = decrement_status_activations(mailbox, processed_activations);

    // end of run user messages ------------------------------------------------------------------------------------

    int64_t old_activations = activations(old_status);
    // printf("[SACT_TRACE_MAILBOX][c] Old: %lu, processed_activations: %lu\n", old_activations, processed_activations);
    print_debug_status(mailbox, "Run complete...");

    // issue directives to mailbox ---------------------------------------------------------------------------------
    if (run_result == SActActorRunResult_shouldStop) {
        // MUST be the first check, as we may want to stop immediately (e.g. reacting to system .start a with .stop),
        // as other conditions may hold, yet we really are ready to terminate immediately.
        print_debug_status(mailbox, "terminating, notifying swift mailbox...");
        return SActMailboxRunResult_Close;
    } else if ((old_activations > processed_activations && !is_suspended(old_status)) ||
               has_system_messages(old_status)) {
        // if we received new system messages during user message processing, or we could not process
        // all user messages in this run, because we had more messages queued up than the maximum run
        // length, return `Reschedule` to signal the queue should be re-scheduled

#ifdef SACT_TRACE_MAILBOX
        char msg[300];
        snprintf(msg, 300, "Run complete, shouldReschedule:true; %lld > %lld", old_activations, processed_activations);
        print_debug_status(mailbox, msg);
#endif
        return SActMailboxRunResult_Reschedule;
    } else if (run_result == SActActorRunResult_closed) {
        print_debug_status(mailbox, "terminating, completely closed now...");
        return SActMailboxRunResult_Closed;
    } else {
        print_debug_status(mailbox, "Run complete, shouldReschedule:false");
        return SActMailboxRunResult_Done;
    }
}

// We only return 32 bit here, because the mailbox from a user perspective can't
// grow larger than that. For the internal function message_count, we need the
// 64 bit because of the overflow in case we try to enqueue a message to an
// already full mailbox. For correctness we need to return `mailbox->capacity`
// instead of `message_count(status)`, if the stored count is larger than the
// capacity. Otherwise users could see a count larger than the configured capacity,
// or 0 in case of an uncapped mailbox.
uint32_t cmailbox_message_count(CSActMailbox* mailbox) {
    int64_t count = message_count(get_status(mailbox));
    return count > mailbox->capacity ? mailbox->capacity : count;
}

void print_debug_status(CSActMailbox* mailbox, char* msg) {
#ifdef SACT_TRACE_MAILBOX
    uint64_t status = get_status(mailbox);

    // prepare to print the status as its binary 64bit string representation
    // since there's no `ltoa` (as in `itoa`)
    char buffer[64];
    uint64_t one = 1;
    for (int i = 63; i > 0; i--) {
        // not super efficient u64 -> bin but good enough for debugging here
        if (status & (one << i)) {
            buffer[63 - i] = '1';
        } else {
            buffer[63 - i] = '0';
        }
    }
    buffer[63] = '\0';

#ifdef __APPLE__
    int thread_id = pthread_mach_thread_np(pthread_self());
#else
    // on linux
    pthread_t thread_id = pthread_self();
#endif

    printf("[SACT_TRACE_MAILBOX][c]"
           "[thread:%d] "
           "%s; "
           "Status now: [0b%s]"
           ", "
           "has_sys_msgs:%s, "
           "msgs:%lld, "
           "terminating:%s, "
           "closed:%s"
           "\n",
           thread_id,
           msg,
           buffer,
           has_system_messages(status) ? "Y" : "N",
           message_count(status),
           is_terminating(status) ? "Y" : "N",
           is_closed(status) ? "Y" : "N"
    );
#endif
}

int64_t get_status(CSActMailbox* mailbox) {
    return atomic_load_explicit(&mailbox->status, memory_order_acquire);
}

int64_t try_activate(CSActMailbox* mailbox) {
    return atomic_fetch_or_explicit(&mailbox->status, 1, memory_order_acq_rel);
}

// TODO: this is more like increment message count
int64_t increment_status_activations(CSActMailbox* mailbox) {
    return atomic_fetch_add_explicit(&mailbox->status, SINGLE_USER_MESSAGE_MASK, memory_order_acq_rel);
}

int64_t decrement_status_activations(CSActMailbox* mailbox, int64_t n) {
    return atomic_fetch_sub_explicit(&mailbox->status, n, memory_order_acq_rel);
}

int64_t set_status_terminating(CSActMailbox* mailbox) {
    return atomic_fetch_or_explicit(&mailbox->status, TERMINATING, memory_order_acq_rel);
}

int64_t set_status_suspended(CSActMailbox* mailbox) {
    return atomic_fetch_or_explicit(&mailbox->status, SUSPENDED, memory_order_acq_rel);
}

int64_t reset_status_suspended(CSActMailbox* mailbox) {
    return atomic_fetch_and_explicit(&mailbox->status, UNSUSPEND_MASK, memory_order_acq_rel);
}

int64_t set_status_closed(CSActMailbox* mailbox) {
    return atomic_fetch_or_explicit(&mailbox->status, CLOSED, memory_order_acq_rel);
}

// Checks if the 'has system messages' bit is set and if it is, unsets it and
// sets the 'is processing system messages' bit in one atomic operation. This is
// necessary to not race between unsetting the bit at the end of a run while
// another thread is enqueueing a new system message.
int64_t set_processing_system_messages(CSActMailbox* mailbox) {
    int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);
    if (has_system_messages(status)) {
        status = atomic_fetch_xor_explicit(&mailbox->status, BECOME_SYS_MSG_PROCESSING_XOR_MASK, memory_order_acq_rel);
    }

    return status;
}

bool has_system_messages(int64_t status) {
    return (status & HAS_SYSTEM_MESSAGES) == HAS_SYSTEM_MESSAGES;
}

bool has_activations(int64_t status) {
    return (status & ACTIVATIONS) != 0;
}

int64_t activations(int64_t status) {
    return status & ACTIVATIONS;
}

uint64_t message_count(int64_t status) {
    uint64_t count = activations(status) >> 2;
    return count;
}

void cmailbox_set_closed(CSActMailbox* mailbox) {
    set_status_closed(mailbox);
}

// can be invoked by the cell itself if it fails
void cmailbox_set_terminating(CSActMailbox* mailbox) {
    set_status_terminating(mailbox);
}

bool is_terminating(int64_t status) {
    return (status & TERMINATING) != 0;
}
bool is_not_terminating(int64_t status) {
    return (status & TERMINATING) == 0;
}

bool is_closed(int64_t status) {
    return (status & CLOSED) != 0;
}
bool cmailbox_is_closed(CSActMailbox* mailbox) {
    return is_closed(get_status(mailbox));
}

bool is_suspended(int64_t status) {
    return (status & SUSPENDED) != 0;
}

bool is_processing_or_has_system_messages(int64_t status) {
    return (status & (PROCESSING_SYSTEM_MESSAGES | HAS_SYSTEM_MESSAGES));
}

uint32_t max(uint32_t a, uint32_t b) {
    return a > b ? b : a;
}
