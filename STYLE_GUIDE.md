# Swift Distributed Actors Style Guide 

- Keep in mind that enums are not possible to evolve in source compatible ways
  - "it's like they expose all their implementation" as Johannes says
- use an `enum` as namespace, put structs in there to get similar "typing experience" but not exhaustive checks

Vocabulary:

We need to flesh the vocabulary out a bit, since we differ from Akka quite a bit in internals:
This is not fleshed out, we should chat about it.

- interpret - apply a message to a behavior, not necessarily a full reduction ????
- reduction - the step of processing a message, including interpretation
- a behaviors' canonical form - a behavior that has no nested behaviors that "need to run before messages can be handled", e.g. setup is NOT canonical, and has to be reduced before a run is complete
- canonicalize - some behaviors are not in "canonical form", thus we need to canonicalize a behavior after a reduction

- message - user message, at-least once delivery by default, in local setting assumed to not really drop "in transport" (though it could hit a bounded mailbox)
- system message - internal message, redelivered
- signal - caused by a system message, those are user accessible, and can be reacted to by users

- mailbox run - processing system messages and messages of a mailbox, by taking the messages and applying reductions over the behavior of an actor
- run length - the maximum amount of messages to be processed during one run, this allows for fairness in the system

- stop -- stop by returning `.stopped`
- terminate -- internally "actor is really done", this is a system message

- dropped - message dropped due to mailbox overflow or other "i don't care" action
- dead letter - message arrived at dead actor
- dead letter mailbox - the mailbox where all dead letters are drained to

- death watch, watch, unwatch - the API allowing for monitoring actors for termination, when a watched actor terminates, the watcher will receive a .terminated signal about it 
- death pact - signed automatically when watching another actor, and is put into effect when the resulting .terminated signal about the other party is not handled; it causes the watcher to also terminate then

## Code style hints

- Whenever working with behaviors and an `ActorContext` is also passed, prefer passing the context as the first parameter
  - then (if present) followed by a `Behavior`
  - then (if present) followed by a message
  - examples: `interpret(context, behavior, message)`, `handle { context, message ...` 

## Logging messages

- put messages into `[]` so it is easier to spot where message type starts and where it ends
- never log entire user messages, they could contain passwords or other secrets
  - log their type instead, e.g. "`[AuthenticationMessage]` unhandled", or ""
- when logging full messages, e.g. system messages, just printing the message (e.g. an enum) would look like this:
  "`initialize(...)` dropped to dead letters", which sometimes MAY be clear enough but not always, since there may be
  multiple "initialize" messages defined for various message protocols. Prefer the following logging style: `"Dropped [\(msg)]:\(type(of: msg))..."`,
  which results in useful messages like *"Dropped initialize(...):WalletMessages"*.
  - Technically users can also guess the type from the type of the actor ref but only if the message is sent to the exact actor, and not dead letters etc.
    Keeping the style the same in our logging is likely best for consistency and training people to spot the message and type easily.
  - the trailing `:type` is designed to feel like type signatures, it also should help in case there are the same string representations for various types, 
    and one would be left scratching their head why "1 was not delivered" when "1" definitely should have been (e.g. whoops, it was `1:Int`, and not `"1":String`!) 

## Recommended reads

The Swift Distributed Actors team recommends the following reads to "get it",
and understand where Swift Distributed Actors takes its core concepts from.

- *Actor Model of Computation: Scalable Robust Information Systems* – Carl Hewitt
 https://arxiv.org/abs/1008.1459
- TODO add links
