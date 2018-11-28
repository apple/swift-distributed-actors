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

#ifndef CMPSCLinkedQueue_h
#define CMPSCLinkedQueue_h

#include <stdatomic.h>
#include <stdlib.h>

typedef struct Node {
    void* item;
    _Atomic (struct Node*) next;
} Node;

typedef struct {
    _Alignas(64) _Atomic (Node*) producer;
    char _pad0[64 - sizeof(_Atomic Node*)];
    Node* consumer;
    char _pad1[64 - sizeof(Node*)];
} CMPSCLinkedQueue;

CMPSCLinkedQueue* cmpsc_linked_queue_create(void);

void cmpsc_linked_queue_destroy(CMPSCLinkedQueue* q);

void cmpsc_linked_queue_enqueue(CMPSCLinkedQueue* q, void* item);

void* cmpsc_linked_queue_dequeue(CMPSCLinkedQueue* q);

int cmpsc_linked_queue_is_empty(CMPSCLinkedQueue* q);
int cmpsc_linked_queue_non_empty(CMPSCLinkedQueue* q);

#endif /* CMPSCLinkedQueue_h */
