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

typedef void (*InterpretMessageCallback)(void*, void*);

CMailbox* cmailbox_create(int64_t capacity, int64_t max_run_length);
void cmailbox_destroy(CMailbox* mailbox);

bool cmailbox_send_message(CMailbox* mailbox, void* envelope);
bool cmailbox_send_system_message(CMailbox* mailbox, void* envelope);

bool cmailbox_run(CMailbox* mailbox, void* context, void* system_context, InterpretMessageCallback interpret_message);

#endif /* CMailbox_h */
