# The shell socket protocol

A shell (`serve-shell`) and a client image (`connect-shell`) talk over a
Unix-domain socket. This page is what crosses it; `cl-proteus/client` is one
implementation, and anything that speaks it can be a client.

## Framing

- A stream of UTF-8 text, one JSON object per line, ended by `\n`. A
  newline inside a string is written as `\n`, so a line is always a whole
  message.
- Every message has a `"type"`. A receiver ignores a type it does not know
  (the shell also reports it on its error output).
- Values in `"args"`, `"value"` and `"payload"` follow the mapping commands
  use: strings, numbers, `true`/`false`, `null`, arrays and objects.

The socket file is mode `0600`; if `serve-shell` creates its directory, that
is `0700`. There is no other authentication: whoever can open the socket can
register commands that pages call.

## Client to shell

| Type | Fields | Meaning |
|---|---|---|
| `hello` | `protocol` (1), `name` (string or null) | Sent first. The shell answers `welcome`. `name` shows in `connection-name`. |
| `command` | `name`, `parameters` (array of argument names) | Register, or register again, a command this client runs. |
| `uncommand` | `name` | Forget a command this client registered. |
| `view` | `name`, `files` (object: relative path to base64 contents) | Define a view, or replace its files. Pages showing it are loaded again. |
| `emit` | `event`, `payload` | An event: the shell's Lisp listeners, every page and every other client get it. |
| `result` | `id`, `value` | The value of the invoke `id`. |
| `error` | `id`, `message` | The invoke `id` failed; the page's Promise is rejected with `message`. |

## Shell to client

| Type | Fields | Meaning |
|---|---|---|
| `welcome` | `protocol` | The answer to `hello`. |
| `invoke` | `id`, `name`, `args` (object) | Run the command `name` with `args` and answer with `result` or `error` carrying the same `id`. |
| `event` | `event`, `payload` | An event from a page, from the shell's Lisp, or from another client. |

## Lifecycle

1. The client connects, sends `hello`, then a `command` for each of its
   commands and a `view` for each of its views. It sends more `command`,
   `uncommand` and `view` messages whenever its definitions change.
2. A page calls `proteus.invoke(name, args)`. If a connected client
   registered `name`, the shell sends that client an `invoke` with a fresh
   `id`; otherwise the command runs in the shell. A command a client
   registered is used over a shell command of the same name.
3. The client answers each `invoke` once, with `result` or `error`. The
   shell accepts an answer only from the connection the invoke was sent to,
   and only while that invoke is pending; any other answer is ignored.
4. When the connection ends, for whatever reason, the shell forgets that
   client's commands and rejects each of its pending invokes once, with an
   error saying the client disconnected. The client's views stay, and so do
   the windows.
5. A new client -- a new generation of the same image, say -- connects and
   registers again (1). Pages that were open keep working; a page showing a
   view the new client defines again is loaded again.

`spec/invoke-lifecycle.qnt` models steps 2 to 5.
