
## Actor Lifecycle Watch (AKA "DeathWatch") and Terminated signals

While supervision is very powerful, it is also (by design) limited to parent-child relationships.
This is in order to simplify supervision schemes and confine them to _supervision trees_, where parent actors define the supervision scheme of their children when they create them.
In that sense, supervision strategies are part of the actor itself, rather than the parent.
However, the parent is the place where this supervision is selected, and terminating a parent will automatically terminate its children.

While supervision is enforced in _tree_ hierarchies, the _watch_ ("death watch") feature lifts this restriction, and any actor may `context.watch()` any other actor it has a reference to.
Death watch however does not enable the watchee to take any part in the watched actors lifecycle, other than being notified when the watched actor has terminated (either by stopping gracefully or crashing).

Once an actor is watched, its termination will result in the watching actor receiving a <!-- api -->` Signals.Terminated` signal, which may be handled using `Behavior.receiveSignal` or `Behavior.receiveSpecificSignal` behaviors.

TIP: Any actor can `watchTermination(of:)` any other actor, if it has obtained its api:ActorRef<Message>[struct].

#### Death Pact

Upon _watching_ another actor, the watcher enters a so-called "death pact" with the watchee.
In other words, if the watchee terminates, the watcher will receive a <!-- api -->` Signals.Terminated`.

This pattern is tremendously useful to bind lifecycles of multiple actors to one another.
For example, if a `player` actor signifies the presence of the player in a game match, and other actors represent its various actions, tasks, or units it is controlling, it makes sense for all the auxiliary actors to only exist while the player remains active.
This can be achieved by having each of those actors <!-- api -->` ActorContext``.watch` the `player` they belong to.
Without any further modifications, if the player actor terminates (for whatever reason), all of its actions, tasks and units would terminate automatically:

```
Tests/DistributedActorsDocumentationTests/DeathWatchDocExamples.swift[tag=simple_death_watch]
```
1. Whenever creating a game unit, we pair it with its owning player; the unit immediately _watches_ the `player` upon starting.
2. Once setup is complete, we become the unit's main behavior, along with handling the player _termination signal_.
3. By _not_ handling any termination signals, whenever the `player` terminates the `gameUnit` will automatically fail with a death pact error, ensuring we won't leak the unit.

The above scenario can be performed more gracefully as well.
All actors watching the `player` could explicitly handle the player termination signal and decide on how they want to deal with this individually.

Perhaps a game match in an multilayer game would want to wait for the player to reconnect for a few seconds before they signal termination and concede the game to the opponent.
Or perhaps any ongoing workers related to given player should run to completion of their current work but not accept any new requests, and eventually terminate as well?

In the example below, if the `player` terminates, the `GameMatch` gives it a few seconds reconnect to the game, otherwise we terminate the match, effectively giving up the match by withdrawal of one of the players.

```
Tests/DistributedActorsDocumentationTests/DeathWatchDocExamples.swift[tag=handling_termination_deathwatch]
```

TIP: Use death pacts to bind lifecycles of various actors to one another. +
A death pact error is thrown whenever an <!-- api -->` Signals.Terminated` is received but left `.unhandled`.

#### Death Watch Guarantees

For the sake of describing those guarantees, let us assume we have two actors: Romeo and Juliet.
Romeo performs a `context.watch(juliet)` during its `setup`.

Swift Distributed Actors guarantees that:

* If Juliet terminates, Romeo will receive a `.terminated` signal which it can handle by using an `Behavior.receiveSignal`.
* The `.terminated` message will never be duplicated or lost.
As it goes with system messages, one can assume "exactly once" processing for them, including in distributed settings (which is a stronger guarantee than given for plain user messages).

Furthermore, if we imagine the above two actors to be in the actual Shakespearean play, then there would also be an audience watching both of these actors.
This means that many actors (the audience) can be watching our "stage" actors.
For this situation the following is guaranteed:

* All of the actors watching a terminating actor *WILL* receive the `.terminated` message.
* Even in distributed settings, if a watcher has "not noticed immediately" what was going on on stage, e.g. due to lack of network connectivity, once it is informed by other actors (handled internally via cluster gossip) it will receive the outstanding `.terminated` as if it had observed the death with its own eyes.

#TODO: complete this section#

### Selective Supervision of Specific Failures

> It is also possible to selectively apply supervision depending on the type of the failure.

For example, when working with APIs that might throw errors when they are "overwhelmed."
If our goal is simply to drop the message which caused this fault and not terminate the actor, but continue processing other messages as they are independent requests, we might want to supervise only for this `SomeLibraryOverloadedError` and leave all other errors to crash the actor, leaving any compensating actions to its parent.

It is possible to supervise for a specific `Error` by always restarting, however, all other Errors and faults will cause an immediate crash of the actor:

```
Tests/DistributedActorsDocumentationTests/SupervisionDocExamples.swift[tag=supervise_specific_error_else_stop]
```
1. The actor is implemented to "re-throw" all errors that are sent to it.
2. The `.restart` supervision strategy is selected for the specific error type `CatchThisError`.
3. A "catch all" `.stop` supervisor is always implicitly applied to the end of the supervisor chain.

Using this mechanism we are able to supervise only for failures we know may occur and perhaps cannot do much about, so restarting the actor to reinitialize it is the right thing to do.

It is also possible to supervise "all errors" or "all faults" with a specific supervision strategy, as shown in the above snippet in point 3.
It is also possible to explicitly select supervision strategies for "all" types of a failure category.
This is done using the api:Supervise/All[enum]`.[errors|faults|failures]` cases and the `addSupervision(strategy:forAll:)` overload of the supervision chain builder.

It is worth remembering that while supervision can deal with `Errors`, it is often times preferable to handle those using plain `do/catch` notation, as it has two benefits over supervision:

* It allows for more control as `do/catch` may indeed catch an error and decide that it was harmless and we should continue operations.
* It likely is the right thing to do semantically, as handling errors in this way is normal in Swift applications, and supervision should remain for those instances where unexpected problems arise, or the supervision chain or backoff mechanisms could be useful.

NOTE: Supervision is not intended to replace `do/catch` blocks, and should be used for "unexpected" failures -- try to use the "let it crash" philosophy when designing your actors and their interactions.
Make sure that a crash would carry enough useful information to be able to attempt fixing it later on, e.g. by carrying trace or similar metadata which could help identify if the error exists only for a specific entity or situation.

### Proof of Concept: Fault Supervision by Process Isolation

Process isolation can be seen as an extension of actor supervision on the process level.

By segregating groups of actors into their own processes, this allows building semantically meaningful _failure domains_, i.e. one might put all actors responsible for a specific batch job or specific work type into their own process as if any of those actors _fault_, they should all be terminated.

#### Using `ProcessIsolated`

In order to discover semantic relationships of "failing together," one might keep the musketeers motto of "all for one, and one for all" in mind when considering the following: when a given actor faults, which actors should also terminate as they are very likely to be in a "bad state" as well?

In a fully pure and isolated actor world, the answer is usually that only the actor itself, and potentially its parent and/or any of its watchers.
However, in the face of unsafe code and faults (fatal errors), we might have to thread more carefully, and terminate an entire group of actors.
This grouping of actors is an approximation of a good failure domain, and you should put all those actors into the same process.

creating actors in a specific process is done like this:

```
Tests/DistributedActorsDocumentationTests/ProcessIsolatedDocExamples.swift[tag=spawn_in_domain]
----
1. Every process isolated application needs to start off with creating an isolated actor system for its own. +
    The returned `isolated` contains the actor system and additional control functions.
2. In general, any code not enclosed in an `isolated.run` will execute on _any_ spawned process, including the master.
    Use this to prepare things common for `.master` and `.servant` processes.
3. Any code enclosed in an `isolated.run(on: ProcessIsolated.Role)` will execute only on given process role. Default roles are `.master` and `.servant`, however you can add additional roles.
4. Inside the `.master` process we create one `.servant` process.
    This will execute "the same" application, however with different configuration, such that it will automatically connect to the `.master`.
5. We decide to _supervise_ the `.servant` _process_ using a _respawn_ strategy with exponential backoff as well as at most 5 faults within its lifetime.
    Upon process fault, the `.master` will re-create another process with the same configuration as the terminated process.
6. We create an actor in the `.master` node.
    As there is always only one `.master` node, this actor will also _definitely_ only exist once on the `.master` process.
7. Finally, we run a block _only_ on `.servant` processes, in which we create another actor.
    If we spawned more `.servant` processes, each would get its own "alfredPennyworth" actor on its own process/node.
8. Last but not least, we park the main thread of the applications in a loop that is used for handling process creating. #TODO this may be simplified in the future#

#TODO: Update for inclusive language, as defined in https://help.apple.com/applestyleguide/#

The above example shows how to use <!-- api -->` ProcessIsolated` to build a simple 2 process application.
If either a failure were to _escalate_ through `alfred` to the `/user` guardian, or the `.servant` process were to encounter a _fault_ anywhere, the parent (`.master`) process would notice this immediately, and use its `.respawn` `.servant` process supervision strategy to respawn the child process, causing a new `alfred` actor to be spawned.

As for how `bruce` and `alfred` can communicate to one another, you should refer to documentation about the <<receptionist>>.

It is also worth exploring the various helper functions on the <!-- api -->` ProcessIsolated` class, as it offers some convenience utilities for working with processes in various roles.

Note also that file descriptors or any other state is _not_ passed to servant processes, so e.g. all files that the `.master` process had opened before creating the child are closed when the `.servant` is spawned.
Any communication between the two should be implemented the same way as if the processes were completely separate nodes in a cluster, i.e. by using the receptionist or other mechanisms such as gossip.

TIP: Since actors spawned in different processes have to serialize messages when they communicate with each other, you have to ensure that messages they exchange are serializable using <<serialization, serialization infrastructure>>.

#### One for all, and all for one

Using the previous code snippet, showing how to use `ProcessIsolated`, let us now discuss the various failure situations this setup is able to deal with.
We will discuss 3 situations, roughly depicted by the following points of failure:

[.center]
image::process_isolated_servants.png[]

=#### Failure scenario a) actor failure

Actor failure, shall (currently) be discussed in two categories: a _fault_ and an _error_.

TIP: In the future we hope to unify those two failure handling schemes under the scheme which currently applies to error supervision, right now, however, this is not possible.
In this scenario, let us focus on the escalating errors pattern, and the fault scenario will be analysed in depth in <<process_isolated_scenario_b>>.

When the actor throws an error which causes it to crash, its <<supervision_strategies, supervision strategy>> is applied.
If this happens to result in an `.escalate` decision, the error is _bubbled up_ through the actor hierarchy, and if it reaches the `/user` guardian actor it will terminate the process, and thus trigger the ``.master``'s `.servant` process supervision mechanism.

=#### Failure scenario b) Fault in `.servant` process

Whenever a _fault_ (such as `fatalError`, a division by zero, or a more serious issue, such as a segmentation fault or similar) happens in a `.servant` process, it will be immediately terminated (printing a backtrace if configured to do so, which it is by default).

All actors hosted in this `.servant` process are terminated, and if any other actor _watched_ any of them on another process/node, they will immediately be notified with an <!-- api -->` Signals.Terminated` signal.
You can read more about terminated messages and watch semantics in <<death_watch>>.

=#### Failure scenario c) Fault or `.escalation` in `.master` process

Each time a `.servant` process terminates, the `.master` will apply the supervision strategy that was tied to the now terminated process.
Such strategy MAY yield an `.escalate` decision, which means that the given ``.servant``'s termination, should escalate and also cause the `.master` to terminate.

If the `.master` terminates, it also _causes all of its ``.servant``s to terminate_.
This is done unconditionally in order to prevent lingering "orphan" processes.
This termination is guaranteed, even if the `.master` process is terminated forcefully by killing it with a `SIGKILL` signal.


NOTE: While this method is effective in isolating faults, including serious ones like segfaults or similar in the `.servant` (child) processes, it comes at a price.
Maintaining many processes is expensive and communication between them is less efficient than communicating between actors located in the same actor system, as serialization needs to be involved.
