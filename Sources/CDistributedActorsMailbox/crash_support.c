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

#include <stdlib.h>
#include <stdio.h>
#include <execinfo.h>

#include "include/crash_support.h"

void sact_dump_backtrace() {
    char** strs;
    int frames = sact_get_backtrace(&strs);
    for (int i = 0; i < frames; ++i) {
        fprintf(stderr, "%s\n", strs[i]);
    }
    free(strs);
}

int sact_get_backtrace(char*** strs) {
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    *strs = backtrace_symbols(callstack, frames);
    return frames;
}

/* UD2 is defined as "Raises an invalid opcode exception in all operating modes." */
void sact_simulate_trap() {
    __asm__("UD2");
}
