# cl-proteus

A Tauri-style application framework for Common Lisp, built on
[cl-iris](https://github.com/amersh-io/cl-iris): a native window, a web page
for the interface, and Lisp behind it, all in one SBCL process that you can
change from the REPL while it runs.

> **Status:** early. Commands and the page bridge work; the rest of the
> roadmap below is still to come. cl-proteus is an independent project, not
> affiliated with Tauri.

## Commands

A command is a Lisp function a page may call by name:

```lisp
(asdf:load-system "cl-proteus")
(defpackage #:hello (:use #:cl #:cl-iris #:cl-proteus))
(in-package #:hello)

(define-command greet (user-name)
  "Say hello."
  (format nil "Hello, ~A!" user-name))

(with-application ()
  (with-window (window :title "Hello")
    (make-app-webview window :html "<button onclick=\"
      proteus.invoke('greet', {userName: 'Ada'}).then(alert)\">Greet</button>")
    (sleep 60)))
```

- In the page, `proteus.invoke(command, args)` returns a Promise of the
  command's value. Arguments are matched to parameters by name, and a Lisp
  parameter `user-name` is the argument `userName`.
- Values cross as JSON does: strings, numbers, booleans, `null` (`:null` in
  Lisp), arrays (vectors) and objects (`equal` hash tables).
- An error in a command, an unknown command or a missing argument rejects
  the Promise with the error's message.
- Only registered commands can be called: nothing else in the image is
  reachable from a page.
- A command stays an ordinary function. Redefining it, or evaluating the
  `define-command` form again, changes what the page calls at once, with
  the window still open.

The call travels through WebKit's script message handler with reply, which
answers the page's Promise natively; no JavaScript is evaluated to carry a
call or its answer.

## Systems

| System | What it holds |
|---|---|
| `cl-proteus/core` | commands and the rest of an application that needs no window; does not load cl-iris or Cocoa |
| `cl-proteus/shell` | the page bridge (`make-app-webview`), on cl-iris |
| `cl-proteus` | both, and the `cl-proteus` package that re-exports them |

The core stays free of Cocoa so that a process which only defines an
application — commands, and later views — can load it without AppKit and
talk to a separate shell process that owns the windows.

## Roadmap

- Events both ways: Lisp emits to pages, pages emit to Lisp.
- An application definition: windows, their pages and settings in one form.
- Serving a directory of front-end files through a custom URL scheme.
- Application state shared by commands.
- Building a signed `.app` bundle.
- A socket transport, so commands and views can live in another Lisp image
  than the shell that shows them.

## Development

```sh
scripts/bootstrap    # SBCL 2.6.9 and qlot under .local/, cl-iris at a pinned commit
scripts/test         # the test suite; CL_PROTEUS_TEST_ONLY=<text> picks checks by name
```

Test windows are transparent so a run does not flash on the screen;
`CL_PROTEUS_TEST_VISIBLE=1` shows them.

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute cl-proteus
or work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
