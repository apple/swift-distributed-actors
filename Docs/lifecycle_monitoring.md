
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

