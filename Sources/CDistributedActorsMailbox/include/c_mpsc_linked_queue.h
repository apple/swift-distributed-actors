//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef CMPSCLinkedQueue_h
#define CMPSCLinkedQueue_h

#include <stdatomic.h>
#include <stdlib.h>

typedef struct Node {
    void* item;
    _Atomic (struct Node*) next;
} CSActMPSCLinkedQueueNode;

typedef struct {
    char _pad0[64 - sizeof(_Atomic CSActMPSCLinkedQueueNode*)];
    _Atomic (CSActMPSCLinkedQueueNode*) producer;
    char _pad1[64 - sizeof(_Atomic CSActMPSCLinkedQueueNode*)];
    _Atomic (CSActMPSCLinkedQueueNode*) consumer;
    char _pad2[64 - sizeof(_Atomic CSActMPSCLinkedQueueNode*)];
} CSActMPSCLinkedQueue;

CSActMPSCLinkedQueue* c_sact_mpsc_linked_queue_create(void);

void c_sact_mpsc_linked_queue_destroy(CSActMPSCLinkedQueue* q);

void c_sact_mpsc_linked_queue_enqueue(CSActMPSCLinkedQueue* q, void* item);

void* c_sact_mpsc_linked_queue_dequeue(CSActMPSCLinkedQueue* q);

#endif /* CMPSCLinkedQueue_h */
