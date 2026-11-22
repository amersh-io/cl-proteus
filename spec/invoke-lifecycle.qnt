// invoke-lifecycle.qnt -- a page's invoke of a command a client image runs,
// across the client's death and its successor (src/shell/server.lisp:
// CALL-REMOTE, SETTLE, HANDLE-MESSAGE, DROP-CONNECTION; src/shell/bridge.lisp:
// ANSWER-INVOKE).
//
// What is modelled
//   * Clients connect one after another, up to CONNS of them -- generations of
//     one image. A connecting client registers the command; the latest
//     registration owns it. Any open client may disconnect (or die) at any time.
//   * A page in one of WEBVIEWS live webviews invokes the command while an open
//     client owns it: the shell gives the invoke a fresh id (never reused),
//     records it as pending for that connection, and sends it there.
//   * A client answers an invoke it was sent, once. A client may also send an
//     answer for an id it was never sent (a stale or buggy client: ids are
//     small integers anyone can guess); the shell must not take it.
//   * Settling an invoke answers the page's Promise. The shell hands the answer
//     to cl-iris, which hands it to WebKit; if the webview has been destroyed,
//     WebKit drops it (WEBKIT_DROPS, measured by the test "an answer for a
//     webview destroyed meanwhile does no harm"). A webview may be destroyed at
//     any time.
//
// Designs (const DESIGN)
//   "guarded"     -- the code: SETTLE, under one lock, takes an answer only for an
//                    id still pending and only from the connection it was sent
//                    to, and removes it; DROP-CONNECTION settles each of the
//                    connection's pending ids with an error.
//   "anySender"   -- SETTLE without the connection check.
//   "noRemove"    -- SETTLE that does not check the id is still pending.
//   "noReject"    -- DROP-CONNECTION that leaves pending ids alone.
//
// Simplified away: the arguments, values and messages; the command's name (one
// command); local commands; events and views; the threads (each step is one
// atomic step under *SERVER-LOCK*, as in the code).
module invokeLifecycle {
  const DESIGN: str
  const WEBKIT_DROPS: bool

  pure val CONNS = 3
  pure val INVOKES = 3
  pure val WEBVIEWS = 2
  pure val CS = 0.to(CONNS - 1)
  pure val IS = 0.to(INVOKES - 1)
  pure val WS = 0.to(WEBVIEWS - 1)
  pure val NOBODY = -1
  pure val DISCONNECT = -2

  type ConnSt = Unborn | Open | Closed
  type InvSt = NotYet | Pending | Settled

  type Invoke = { st: InvSt, target: int, webview: int, answers: int, by: int,
                  reachedDead: bool }

  var conns: int -> ConnSt
  var owner: int                  // the connection that owns the command, or NOBODY
  var invokes: int -> Invoke
  var sent: int -> Set[int]       // per connection: ids it was sent and has not answered
  var live: int -> bool           // webviews

  action init = all {
    conns' = CS.mapBy(_ => Unborn),
    owner' = NOBODY,
    invokes' = IS.mapBy(_ => { st: NotYet, target: NOBODY, webview: 0, answers: 0,
                               by: NOBODY, reachedDead: false }),
    sent' = CS.mapBy(_ => Set()),
    live' = WS.mapBy(_ => true),
  }

  // Settle invoke i on behalf of `from` (a connection, or DISCONNECT).
  pure def settled(inv: Invoke, from: int, webviewLive: bool): Invoke =
    { ...inv, st: Settled, answers: inv.answers + 1, by: from,
      reachedDead: inv.reachedDead or (not(webviewLive) and not(WEBKIT_DROPS)) }

  def accepts(i: int, from: int): bool = {
    val inv = invokes.get(i)
    val stillPending = if (DESIGN == "noRemove") inv.st != NotYet else inv.st == Pending
    val rightSender = if (DESIGN == "anySender") true else from == DISCONNECT or from == inv.target
    stillPending and rightSender
  }

  def settle(i: int, from: int): int -> Invoke =
    if (accepts(i, from)) invokes.put(i, settled(invokes.get(i), from, live.get(invokes.get(i).webview)))
    else invokes

  action connect(c: int): bool = all {
    conns.get(c) == Unborn,
    // Generations come in order.
    CS.forall(d => d < c implies conns.get(d) != Unborn),
    conns' = conns.put(c, Open),
    owner' = c,
    invokes' = invokes, sent' = sent, live' = live,
  }

  action invoke(i: int, w: int): bool = all {
    invokes.get(i).st == NotYet,
    IS.forall(j => j < i implies invokes.get(j).st != NotYet),
    live.get(w),
    owner != NOBODY,
    conns.get(owner) == Open,
    invokes' = invokes.put(i, { ...invokes.get(i), st: Pending, target: owner, webview: w }),
    sent' = sent.put(owner, sent.get(owner).union(Set(i))),
    conns' = conns, owner' = owner, live' = live,
  }

  // A client answers an invoke it was sent.
  action answer(c: int, i: int): bool = all {
    conns.get(c) == Open,
    sent.get(c).contains(i),
    sent' = sent.put(c, sent.get(c).exclude(Set(i))),
    invokes' = settle(i, c),
    conns' = conns, owner' = owner, live' = live,
  }

  // A client sends an answer for an id it was not sent.
  action forge(c: int, i: int): bool = all {
    conns.get(c) == Open,
    invokes.get(i).st != NotYet,
    not(sent.get(c).contains(i)),
    invokes' = settle(i, c),
    conns' = conns, owner' = owner, live' = live, sent' = sent,
  }

  action disconnect(c: int): bool = all {
    conns.get(c) == Open,
    conns' = conns.put(c, Closed),
    owner' = if (owner == c) NOBODY else owner,
    sent' = sent.put(c, Set()),
    invokes' = if (DESIGN == "noReject") invokes
               else IS.mapBy(i => if (invokes.get(i).st == Pending and invokes.get(i).target == c
                                      and accepts(i, DISCONNECT))
                                    settled(invokes.get(i), DISCONNECT, live.get(invokes.get(i).webview))
                                  else invokes.get(i)),
    live' = live,
  }

  action destroy(w: int): bool = all {
    live.get(w),
    live' = live.put(w, false),
    conns' = conns, owner' = owner, invokes' = invokes, sent' = sent,
  }

  action step = any {
    nondet c = CS.oneOf()
    nondet i = IS.oneOf()
    nondet w = WS.oneOf()
    any {
      connect(c),
      invoke(i, w),
      answer(c, i),
      forge(c, i),
      disconnect(c),
      destroy(w),
    }
  }

  // Every page invoke is answered at most once.
  val atMostOnce: bool = IS.forall(i => invokes.get(i).answers <= 1)

  // An invoke is answered only by the connection it was sent to, or rejected
  // when that connection ends -- never by a client that registered after it
  // was sent, nor by any other.
  val rightAnswerer: bool =
    IS.forall(i => invokes.get(i).st == Settled implies
                     (invokes.get(i).by == invokes.get(i).target or invokes.get(i).by == DISCONNECT))

  // No invoke waits on a connection that has ended: it has been answered.
  val noStranded: bool =
    IS.forall(i => invokes.get(i).st == Pending implies conns.get(invokes.get(i).target) == Open)

  // No answer reaches a destroyed webview.
  val noAnswerToDestroyed: bool = IS.forall(i => not(invokes.get(i).reachedDead))

  val safe: bool = atMostOnce and rightAnswerer and noStranded and noAnswerToDestroyed

  // A pending invoke is settled exactly once when its client dies, and the
  // next client's answer to a new invoke is taken.
  run dieThenNextTest =
    init
      .then(connect(0))
      .then(invoke(0, 0))
      .then(disconnect(0))
      .expect(invokes.get(0).st == Settled and invokes.get(0).by == DISCONNECT
              and invokes.get(0).answers == 1)
      .then(connect(1))
      .then(invoke(1, 0))
      .then(answer(1, 1))
      .expect(invokes.get(1).by == 1 and atMostOnce)

  // A later client cannot answer an invoke sent to its predecessor.
  run laterClientTest =
    init
      .then(connect(0))
      .then(invoke(0, 0))
      .then(connect(1))
      .then(forge(1, 0))
      .expect(rightAnswerer)

  // The client answers, then dies: the invoke is not answered again.
  run answerThenDieTest =
    init
      .then(connect(0))
      .then(invoke(0, 1))
      .then(answer(0, 0))
      .then(disconnect(0))
      .expect(atMostOnce)

  // The webview is destroyed while its invoke is out.
  run destroyedWebviewTest =
    init
      .then(connect(0))
      .then(invoke(0, 0))
      .then(destroy(0))
      .then(answer(0, 0))
      .expect(noAnswerToDestroyed)
}

module guarded { import invokeLifecycle(DESIGN = "guarded", WEBKIT_DROPS = true).* from "./invoke-lifecycle" }
module anySender { import invokeLifecycle(DESIGN = "anySender", WEBKIT_DROPS = true).* from "./invoke-lifecycle" }
module noRemove { import invokeLifecycle(DESIGN = "noRemove", WEBKIT_DROPS = true).* from "./invoke-lifecycle" }
module noReject { import invokeLifecycle(DESIGN = "noReject", WEBKIT_DROPS = true).* from "./invoke-lifecycle" }
module guardedNoDrop { import invokeLifecycle(DESIGN = "guarded", WEBKIT_DROPS = false).* from "./invoke-lifecycle" }
