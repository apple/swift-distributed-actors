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

#include <math.h>
#include <stdio.h>

// TODO getting better code completion this way... works ok in xcode and friends this way too?
//#include "CMailbox.h"
#include "include/CMailbox.h"

// Implementation notes:
// State should be operated on bitwise; where the specific bits signify states like the following:
// 0 - 29 - activation count
//     30 - terminating (or terminated)
//     31 - terminated (for sure)
// Activation count is special in the sense that we use it as follows, it's value being:
// 0 - inactive, not scheduled and no messages to process
// 1 - active without(!) normal messages, only system messages are to be processed
// n - there are (n >> 1) messages to process + system messages if LSB is set
//
// Note that this implementation allows, using one load, to know:
// - if the actor is running right now (so the mailbox size will be decremented shortly),
// - current mailbox size (nr. of enqueued messages, which can be used for scheduling and/or metrics)
// - if we need to schedule it or not since it was scheduled already etc.

#define ACTIVATIONS 0b00111111111111111111111111111111

// Implementation notes about Termination:
// Termination MUST first set TERMINATING and only after add the "final" TERMINATED state.
// In other words, the only legal bit states a mailbox should observe are:
//  - 0b11.. alive,
//  -> 0b01.. terminating,
//  -> 0b11.. terminated, dead.
// Meaning that `10` is NOT legal.
#define TERMINATING 0b01000000000000000000000000000000
#define TERMINATED  0b10000000000000000000000000000000

int64_t increment_status_activations(CMailbox* mailbox);
int64_t decrement_status_activations(CMailbox* mailbox, int64_t n);
int64_t try_activate(CMailbox* mailbox);
int64_t activations(int64_t status);
int64_t message_count(int64_t status);
int64_t set_status_terminating(CMailbox* mailbox);
int64_t set_status_terminated_dead(CMailbox* mailbox);

void print_debug_status(CMailbox *mailbox);
bool is_active(int64_t status);
bool has_system_messages(int64_t status);

bool is_terminating_or_dead(int64_t status);
bool is_terminated_dead(int64_t status);

bool internal_send_message(CMailbox* mailbox, void* envelope, bool is_system_message);

CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length) {
  CMailbox* mailbox = calloc(sizeof(CMailbox), 1);
  mailbox->capacity = capacity;
  mailbox->max_run_length = max_run_length;
  mailbox->messages = cmpsc_linked_queue_create();
  mailbox->system_messages = cmpsc_linked_queue_create();

  return mailbox;
}

void cmailbox_destroy(CMailbox* mailbox) {
  free(mailbox);
}

bool cmailbox_send_message(CMailbox* mailbox, void* envelope) {
  int64_t old_status = increment_status_activations(mailbox);
  int64_t old_activations = activations(old_status);
  CMPSCLinkedQueue* queue = mailbox->messages;
  // printf("[cmailbox] send_message; messages in queue: %lld\n", (old_activations));

  // `>` is correct and not an one-off, since message count is `activations - 1`
  if ((old_activations > mailbox->capacity) || is_terminating_or_dead(old_status)) {
    // If we passed the maximum capacity of the user queue, we can't enqueue more
    // items and have to decrement the activations count again. This is not racy,
    // because we only process messages if the queue actually contains them (does
    // not return NULL), so even if messages get processed concurrently, it's safe
    // to decrement here.
    decrement_status_activations(mailbox, 0b10);
    // TODO emit the message as ".dropped(msg)"
    return false;
  } else {
    // If the mailbox is not full, or we enqueue a system message, we insert it
    // into the queue and return whether this was the first activation, to signal
    // the need to enqueue this mailbox.
    cmpsc_linked_queue_enqueue(queue, envelope);
    return old_activations == 0;
  }
}

bool cmailbox_send_system_message(CMailbox* mailbox, void* envelope) {
  // printf("[cmailbox] send_system_message: \n");
  int64_t old_status = try_activate(mailbox); // only activation matters
  int64_t old_activations = activations(old_status);
  CMPSCLinkedQueue* queue = mailbox->system_messages; // TODO move out the if, we know into which queue we will write when we call send()

  if (is_terminating_or_dead(old_status)) {
    // since we are terminating, we are already dropping all messages, including this one!
    // TODO emit the message as ".dropped(msg)"
    return false;
  } else {
    // If the mailbox is not full, or we enqueue a system message, we insert it
    // into the queue and return whether this was the first activation, to signal
    // the need to enqueue this mailbox.
    cmpsc_linked_queue_enqueue(queue, envelope);
    return old_activations == 0;
  }
}

bool cmailbox_run(CMailbox* mailbox, void* context, void* system_context, InterpretMessageCallback interpret_message) {
  int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);
  // printf("[cmailbox] Entering run\n");
  print_debug_status(mailbox);

  if (!is_active(status)) { // FIXME should this not actually be a bug, because we had a spurious activation triggered?
    return false;
  }

  int64_t processed = 0;
  // TODO: more smart scheduling decisions (smart batching), though likely better on dispatcher layer
  int64_t max_run_length = message_count(status);
  if (max_run_length > mailbox->max_run_length) {
    max_run_length = mailbox->max_run_length;
  }

  // only an stillAlive actor shall continue running;
  // e.g. once .terminate is received, the actor should drain all messages to the dead letters queue
  bool stillAlive = true;

  if (has_system_messages(status)) {
    // printf("[cmailbox] Has system message(s)\n");
    processed = 0b1; // marker value, not a counter; meaning that we did process system messages
    // we run all system messages, as they may
    void* system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
    while (system_message != NULL && stillAlive) {
      // printf("[cmailbox] Processing system message...\n");
      stillAlive = interpret_message(system_context, system_message);
      system_message = cmpsc_linked_queue_dequeue(mailbox->system_messages);
    }

    // was our run was interrupted by a system message causing termination?
    if (!stillAlive) {
      print_debug_status(mailbox);
      set_status_terminating(mailbox);
      print_debug_status(mailbox);
      // yes, we are terminating and need to drain messages to dead letters
      // FIXME: implement draining to dead letters
    }
  }

  void* message = cmpsc_linked_queue_dequeue(mailbox->messages);
  while (message != NULL && stillAlive) {
    // we need to add 2 to processed because the user message count is stored
    // shifted by 1 in the status and we use the same field to clear the
    // system message bit
    processed += 0b10;
    // printf("[cmailbox] Processing user message...\n");
    stillAlive = stillAlive && interpret_message(context, message); // TODO maybe no need for &&

    if (processed >= max_run_length) {
      // if the maximum run length is reached, set message to
      // NULL to break out of the loop
      message = NULL;
    } else {
      // dequeue another message, if there are no more messages left, message
      // will contain NULL and terminate the loop
      message = cmpsc_linked_queue_dequeue(mailbox->messages);
    }
  }

  // printf("[cmailbox] Processed %lld messages...\n", processed);

  int64_t old_status = decrement_status_activations(mailbox, processed);

  int64_t old_activations = activations(old_status);
  // printf("[cmailbox] Old: %lld, processed: %lld\n", old_activations, processed);
  print_debug_status(mailbox);

  if (old_activations == processed &&
      !cmpsc_linked_queue_is_empty(mailbox->system_messages) &&
      activations(try_activate(mailbox)) == 0) {
    // If we processed all messages (including system messages) that have been
    // present when we started to process messages and there are new system
    // messages in the queue, but the mailbox has not been re-scheduled yet
    // return true to signal the queue should be re-scheduled
    // printf("[cmailbox] Run complete, shouldReschedule:true, pending system messages\n");
    return true;
  } else if (old_activations > processed) {
    // if we could not process all messages in this run, because we had more
    // messages queued up than the maximum run length, return true to signal
    // the queue should be re-scheduled

    // printf("[cmailbox] Run complete, shouldReschedule:true\n");
    return true;
  }

  // printf("[cmailbox] Run complete, shouldReschedule:false\n");
  return false;
}

void print_debug_status(CMailbox *mailbox) {
  #if SACT_TRACE_MAILBOX
  printf("[cmailbox] status now: ");
  int64_t status = atomic_load_explicit(&mailbox->status, memory_order_acquire);

  int64_t s = status;
  while (s) {
    if (s & 1) printf("1");
    else printf("0");
    s >>= 1;
  }

  // printf(", has_sys_msgs:");
  if (has_system_messages(status)) // printf("Y"); else // printf("N");

  printf(", activations:");
  printf("%lld", activations(status));

  printf(", terminating:");
  if (is_terminating_or_dead(status)) // printf("Y"); else // printf("N");
  printf(", dead:");
  if (is_terminated_dead(status)) // printf("Y"); else // printf("N");

  printf("\n");
  #endif
}

int64_t try_activate(CMailbox* mailbox) {
  return atomic_fetch_or_explicit(&mailbox->status, 1, memory_order_acq_rel);
}

// TODO this is more like increment message count
int64_t increment_status_activations(CMailbox* mailbox) {
  return atomic_fetch_add_explicit(&mailbox->status, 0b10, memory_order_acq_rel);
}

int64_t decrement_status_activations(CMailbox* mailbox, int64_t n) {
  return atomic_fetch_sub_explicit(&mailbox->status, n, memory_order_acq_rel);
}

int64_t set_status_terminating(CMailbox* mailbox) {
  // printf("[cmailbox] Setting TERMINATING marker.\n");
  return atomic_fetch_or_explicit(&mailbox->status, TERMINATING, memory_order_acq_rel);
}

// intentionally spelled "_dead" to avoid typos
int64_t set_status_terminated_dead(CMailbox* mailbox) {
  return atomic_fetch_or_explicit(&mailbox->status, TERMINATED, memory_order_acq_rel);
}

bool has_system_messages(int64_t status) {
  return (status & 1) == 1;
}

bool is_active(int64_t status) {
  return (status & ACTIVATIONS) != 0;
}

int64_t activations(int64_t status) {
  return status & ACTIVATIONS;
}

int64_t message_count(int64_t status) {
  int64_t count = activations(status) >> 1;
  return count > 0 ? count : 0;
}

bool is_terminating_or_dead(int64_t status) {
  return (status & TERMINATING) != 0;
}

bool is_terminated_dead(int64_t status) {
  return (status & TERMINATED) != 0;
}
