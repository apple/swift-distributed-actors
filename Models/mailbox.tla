------------------------------ MODULE mailbox ------------------------------

(*
===----------------------------------------------------------------------===//

This source file is part of the Swift Distributed Actors open source project

Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
Licensed under Apache License v2.0

See LICENSE.txt for license information
See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors

SPDX-License-Identifier: Apache-2.0

===----------------------------------------------------------------------===//
*)

EXTENDS TLC, Integers

(*
--fair algorithm MailboxAlg
variables has_messages = FALSE, is_processing = FALSE, scheduled = FALSE, total_messages = 10, messages_enqueued = 0

    process send \in {"P1", "P2"}
    variables had_messages = FALSE, messages = 5
    begin
        START:
            while messages /= 0 do
                ENQUEUE:
                    \* we use this counter as the "queue", se incrementing by one is equivalent to enqueue
                    messages_enqueued := messages_enqueued + 1;
                SET_STATE:
                    \* AFTER enqueuing the message, we need to set the HAS_SYSTEM_MESSAGE bit and store the previous value for the check in the next step
                    had_messages := has_messages;
                    has_messages := TRUE;
                SCHEDULE:
                    \* if there have been no messages in the queue before
                    if had_messages = FALSE then
                        \* and the message queue is not processing messages already
                        \* (this check is important, as we unset the has_messages bit when we start processing to see if new messages have
                        \* been enqueued while we were processing the messages)
                        if is_processing = FALSE then
                            \* schedule the mailbox to run
                            scheduled := TRUE;
                        end if;
                    end if;
                SET_LOOP_COUNT:
                    messages := messages - 1;
            end while;
    end process;
    
    process dequeue = "dequeue"
    variables messages_dequeued = 0
    begin
        LOOP:
        \* we're expecting to get a number of messages equal to total_messages in this check
        while messages_dequeued /= total_messages do
        AWAIT:
            \* wait until messages have been enqueued and this mailbox is scheduled
            await scheduled = TRUE;
        SET_PROCESSING_STATUS:
            \* set the is_processing bit and unset the has_messages bit to notify sending processes, that we are already scheduled,
            \* but also know if new messages have arrived while we were processing 
            is_processing := TRUE;
            has_messages := FALSE;
        PROCESS_MESSAGES:
            \* now dequeue and process all messages    
            messages_dequeued := messages_dequeued + messages_enqueued;
            messages_enqueued := 0;
        DONE_PROCESSING:
            \* is new messages have arrived while we were processing, reschedule
            if has_messages = TRUE then
                scheduled := TRUE
            else
            \* otherwise unschedule
                scheduled := FALSE
            end if;
            \* unset processing bit
            is_processing := FALSE
        end while;
    end process;
    
    end algorithm
*)
\* BEGIN TRANSLATION
VARIABLES has_messages, is_processing, scheduled, total_messages, 
          messages_enqueued, pc, had_messages, messages, messages_dequeued

vars == << has_messages, is_processing, scheduled, total_messages, 
           messages_enqueued, pc, had_messages, messages, messages_dequeued
        >>

ProcSet == ({"P1", "P2"}) \cup {"dequeue"}

Init == (* Global variables *)
        /\ has_messages = FALSE
        /\ is_processing = FALSE
        /\ scheduled = FALSE
        /\ total_messages = 10
        /\ messages_enqueued = 0
        (* Process send *)
        /\ had_messages = [self \in {"P1", "P2"} |-> FALSE]
        /\ messages = [self \in {"P1", "P2"} |-> 5]
        (* Process dequeue *)
        /\ messages_dequeued = 0
        /\ pc = [self \in ProcSet |-> CASE self \in {"P1", "P2"} -> "START"
                                        [] self = "dequeue" -> "LOOP"]

START(self) == /\ pc[self] = "START"
               /\ IF messages[self] /= 0
                     THEN /\ pc' = [pc EXCEPT ![self] = "ENQUEUE"]
                     ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ UNCHANGED << has_messages, is_processing, scheduled, 
                               total_messages, messages_enqueued, had_messages, 
                               messages, messages_dequeued >>

ENQUEUE(self) == /\ pc[self] = "ENQUEUE"
                 /\ messages_enqueued' = messages_enqueued + 1
                 /\ pc' = [pc EXCEPT ![self] = "SET_STATE"]
                 /\ UNCHANGED << has_messages, is_processing, scheduled, 
                                 total_messages, had_messages, messages, 
                                 messages_dequeued >>

SET_STATE(self) == /\ pc[self] = "SET_STATE"
                   /\ had_messages' = [had_messages EXCEPT ![self] = has_messages]
                   /\ has_messages' = TRUE
                   /\ pc' = [pc EXCEPT ![self] = "SCHEDULE"]
                   /\ UNCHANGED << is_processing, scheduled, total_messages, 
                                   messages_enqueued, messages, 
                                   messages_dequeued >>

SCHEDULE(self) == /\ pc[self] = "SCHEDULE"
                  /\ IF had_messages[self] = FALSE
                        THEN /\ IF is_processing = FALSE
                                   THEN /\ scheduled' = TRUE
                                   ELSE /\ TRUE
                                        /\ UNCHANGED scheduled
                        ELSE /\ TRUE
                             /\ UNCHANGED scheduled
                  /\ pc' = [pc EXCEPT ![self] = "SET_LOOP_COUNT"]
                  /\ UNCHANGED << has_messages, is_processing, total_messages, 
                                  messages_enqueued, had_messages, messages, 
                                  messages_dequeued >>

SET_LOOP_COUNT(self) == /\ pc[self] = "SET_LOOP_COUNT"
                        /\ messages' = [messages EXCEPT ![self] = messages[self] - 1]
                        /\ pc' = [pc EXCEPT ![self] = "START"]
                        /\ UNCHANGED << has_messages, is_processing, scheduled, 
                                        total_messages, messages_enqueued, 
                                        had_messages, messages_dequeued >>

send(self) == START(self) \/ ENQUEUE(self) \/ SET_STATE(self)
                 \/ SCHEDULE(self) \/ SET_LOOP_COUNT(self)

LOOP == /\ pc["dequeue"] = "LOOP"
        /\ IF messages_dequeued /= total_messages
              THEN /\ pc' = [pc EXCEPT !["dequeue"] = "AWAIT"]
              ELSE /\ pc' = [pc EXCEPT !["dequeue"] = "Done"]
        /\ UNCHANGED << has_messages, is_processing, scheduled, total_messages, 
                        messages_enqueued, had_messages, messages, 
                        messages_dequeued >>

AWAIT == /\ pc["dequeue"] = "AWAIT"
         /\ scheduled = TRUE
         /\ pc' = [pc EXCEPT !["dequeue"] = "SET_PROCESSING_STATUS"]
         /\ UNCHANGED << has_messages, is_processing, scheduled, 
                         total_messages, messages_enqueued, had_messages, 
                         messages, messages_dequeued >>

SET_PROCESSING_STATUS == /\ pc["dequeue"] = "SET_PROCESSING_STATUS"
                         /\ is_processing' = TRUE
                         /\ has_messages' = FALSE
                         /\ pc' = [pc EXCEPT !["dequeue"] = "PROCESS_MESSAGES"]
                         /\ UNCHANGED << scheduled, total_messages, 
                                         messages_enqueued, had_messages, 
                                         messages, messages_dequeued >>

PROCESS_MESSAGES == /\ pc["dequeue"] = "PROCESS_MESSAGES"
                    /\ messages_dequeued' = messages_dequeued + messages_enqueued
                    /\ messages_enqueued' = 0
                    /\ pc' = [pc EXCEPT !["dequeue"] = "DONE_PROCESSING"]
                    /\ UNCHANGED << has_messages, is_processing, scheduled, 
                                    total_messages, had_messages, messages >>

DONE_PROCESSING == /\ pc["dequeue"] = "DONE_PROCESSING"
                   /\ IF has_messages = TRUE
                         THEN /\ scheduled' = TRUE
                         ELSE /\ scheduled' = FALSE
                   /\ is_processing' = FALSE
                   /\ pc' = [pc EXCEPT !["dequeue"] = "LOOP"]
                   /\ UNCHANGED << has_messages, total_messages, 
                                   messages_enqueued, had_messages, messages, 
                                   messages_dequeued >>

dequeue == LOOP \/ AWAIT \/ SET_PROCESSING_STATUS \/ PROCESS_MESSAGES
              \/ DONE_PROCESSING

Next == dequeue
           \/ (\E self \in {"P1", "P2"}: send(self))
           \/ (* Disjunct to prevent deadlock on termination *)
              ((\A self \in ProcSet: pc[self] = "Done") /\ UNCHANGED vars)

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(Next)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

=============================================================================
\* Modification History
\* Last modified Thu May 30 21:30:24 PDT 2019 by drexin
\* Created Wed May 29 11:18:21 PDT 2019 by drexin
