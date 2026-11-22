# Quint model of cl-proteus's invoke lifecycle

`invoke-lifecycle.qnt` models a page's `proteus.invoke` of a command that a
client image runs, across the client's death and the next client's arrival
(`src/shell/server.lisp`: `CALL-REMOTE`, `SETTLE`, `HANDLE-MESSAGE`,
`DROP-CONNECTION`). The protocol itself is described in
[../docs/protocol.md](../docs/protocol.md).

The file has a base module with two constants -- `DESIGN`, the shell's
behaviour, and `WEBKIT_DROPS`, an assumption about WebKit -- one module per
instance at the bottom, the invariants, and `run` tests for `quint test`.

Checked with Quint 0.32.0. "TLC: holds" means TLC explored the whole
reachable state space of the instance, within the bounds below, and found no
violation of `safe` (all four invariants).

## Scope

Up to three clients, connecting one after another (generations of one
image); the latest to connect owns the command, and any open client may
disconnect or die at any time. Up to three invokes, from two webviews, each
sent to the client that owns the command when it is made, under a fresh id.
A client answers an invoke it was sent, once, and may also send an answer for
an id it was never sent. Either webview may be destroyed at any time. Each
step is atomic, as the code makes it with `*SERVER-LOCK*`.

## Invariants

- `atMostOnce` -- no page invoke is answered twice.
- `rightAnswerer` -- an invoke is settled only by the connection it was sent
  to, or rejected when that connection ends: never by a client that
  registered after it was sent, nor by any other.
- `noStranded` -- no invoke stays pending on a connection that has ended.
- `noAnswerToDestroyed` -- no answer reaches a destroyed webview.

## Results

| Instance | Design or assumption | Result |
|---|---|---|
| `guarded` | the code: an answer is taken only for a pending id, only from the connection it was sent to; a dropped connection's pending ids are rejected; WebKit drops a reply to a destroyed webview | TLC: holds (29,660 distinct states, depth 15) |
| `anySender` | no check of who answers | **violation** of `rightAnswerer`: a client answers an id it was never sent -- a later generation answers its predecessor's invoke |
| `noRemove` | no check that the id is still pending | **violation** of `atMostOnce`: a client answers, then sends an answer for the same id again |
| `noReject` | a dropped connection's pending ids are left alone | **violation** of `noStranded`: the client dies and the page's Promise never settles |
| `guardedNoDrop` | the code, if WebKit delivered replies to a destroyed webview | **violation** of `noAnswerToDestroyed`: the shell would need a check of its own |

`WEBKIT_DROPS` is measured, not assumed blindly: the test "an answer for a
webview destroyed meanwhile does no harm" destroys a webview while a client's
command is running for it, and the shell and its other webviews carry on.

## Running it

```sh
scripts/check-spec                         # the run tests, as CI does
quint verify spec/invoke-lifecycle.qnt --main guarded \
  --backend tlc --tlc-config spec/tlc.json --invariant safe   # needs Java
```

## Simplified away

Arguments, values and error messages; the command's name (there is one
command); local commands; events and views; the per-invoke threads.
