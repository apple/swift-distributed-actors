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

- stop -- stop by returning `.stop`
- terminate -- internally "actor is really done", this is a system message

- dropped - message dropped due to mailbox overflow or other "i don't care" action
- dead letter - message arrived at dead actor
- dead letter mailbox - the mailbox where all dead letters are drained to

- death watch, watch, unwatch - the API allowing for monitoring actors for termination, when a watched actor terminates, the watcher will receive a .terminated signal about it 
- death pact - signed automatically when watching another actor, and is put into effect when the resulting .terminated signal about the other party is not handled; it causes the watcher to also terminate then

- failure - the most general word for all kinds of throws / faults
- error - a type of _failure_, it means specifically the Swift `Error` and associated `throws` keywords
- fault - a type of _failure_, generally not "catchable" faults such as division by zero, accessing an array out of bounds 
          or a fault signalled by `fatalError()` invocations 
- fatal faults - serious _faults_ such as segmentation faults or similar, which Swift Distributed Actors does _not_ allow recovering from 
                 as they are deemed dangerous enough that they in all likelyhood have invalidated the consistency of the entire system, 
                 and not only the current actor. 

- crash - the _result_ of a failure, an actor can crash by which we mean it has stopped after a failure, or an entire 
          actor system can crash, by which we mean that some failure was so serious or that it "bubbled up" that the 
          entire system terminated in response to it.
  - also key to the "Let it Crash!" motto, employed by Swift Distributed Actors and other actor systems.

- supervision - the general concept that a parent actor _supervises_ a child actor and some decisions may be made about 
                restarting or stopping such child on a failure.
                
- supervision decision - the return value of a supervisor, invoked when a failure has occurred.  

- mailbox run - the execution of a mailbox, in other words, the process of the mailbox dequeueing messages and applying them to the appropriate actor.
- mailbox run length - the maximum amount of messages to be processed within a single run. The concept is quite similar to "fuel" in other such systems,
                       where a run continues until all fuel is exhausted. If messages remain after an exhausted run, another run will be scheduled.

## Code style hints

- Whenever working with behaviors and an `ActorContext` is also passed, prefer passing the context as the first parameter
  - then (if present) followed by a `Behavior`
  - then (if present) followed by a message
  - examples: `interpret(context, behavior, message)`, `handle { context, message ...`

- Logging
  - Loggers stored in fields should be stored as `log` unless there's a reason not to
  - Make sure that a logger carries useful information such as the actor path that it relates to
  - Use a common prefix or tag to easily group log statements of a specific feature ("supervision", "deathwatch") 

## Compiler directives

- For `#if THING` blocks and similar use the end the `#endif` with `#endif // THING`

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

## Conforming to protocols

- for `Equatable` and `Hashable` - esp. when they are auto derived - it is fine to put it on the type directly
  - you sometimes may have to implement things directly in a class, when subclassing is involved, since it is not possible to override methods implemented in extensions; this is fine as well,
    and the code would hint that this is the reason for it since it would require writing `override` in the subclass when overriding the method
  - for `Equatable` and `Hashable` putting the conformance right away on the type rather than adding via extensions can also be seen as documentation,
    since when looking at the type we immediately then know that it can be used as "data"
- for other conformances, try to make them in separate `extensions`

## Recommended reads

The Swift Distributed Actors team recommends the following reads to "get it",
and understand where Swift Distributed Actors takes its core concepts from.

- *Actor Model of Computation: Scalable Robust Information Systems* – Carl Hewitt
 https://arxiv.org/abs/1008.1459
- TODO add links


