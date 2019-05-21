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

#include "include/c_run_queue.h"
#include "blockingconcurrentqueue.hpp"

typedef moodycamel::BlockingConcurrentQueue<intptr_t> RunQueue;

void* crun_queue_create() {
    return new RunQueue();
}

void crun_queue_destroy(void* _q) {
    RunQueue* q = static_cast<RunQueue*>(_q);
    delete q;
}

void crun_queue_enqueue(void* _q, intptr_t item) {
    RunQueue* q = static_cast<RunQueue*>(_q);
    q->enqueue(item);
}

intptr_t crun_queue_dequeue_timed(void* _q, int64_t timeout_usec) {
    RunQueue* q = static_cast<RunQueue*>(_q);
    intptr_t item = 0;
    q->wait_dequeue_timed(item, timeout_usec);
    return item;
}

intptr_t crun_queue_dequeue(void* _q) {
    RunQueue* q = static_cast<RunQueue*>(_q);
    intptr_t item = 0;
    q->try_dequeue(item);
    return item;
}
