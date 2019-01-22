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

#ifndef SACTANA_C_MAILBOX_PHASE_H
#define SACTANA_C_MAILBOX_PHASE_H

/** Used to mark in which phase of a mailbox run we are currently in. */
// TODO leaks somewhat -- this is a Mailbox thing -- consider making CDungeon part of CMailbox (rename CQueue to CMailbox)
typedef enum {
    ProcessingSystemMessages = 0,
    ProcessingUserMessages   = 1,
} CMailboxRunPhase;

#endif //SACTANA_C_MAILBOX_PHASE_H
