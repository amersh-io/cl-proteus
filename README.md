# cl-proteus

A Tauri-style application framework for Common Lisp, built on
[cl-iris](https://github.com/amersh-io/cl-iris): native windows, web pages
for the interface, and Lisp behind them, all in one SBCL process that you
can change from the REPL while it runs.

> **Status:** early. Commands, events, applications, a served front end and
> shared state work; bundling and a socket transport are still to come.
> cl-proteus is an independent project, not affiliated with Tauri.

```lisp
(asdf:load-system "cl-proteus")
(defpackage #:hello (:use #:cl #:cl-proteus))
(in-package #:hello)

(define-command greet (user-name)
  "Say hello."
  (format nil "Hello, ~A!" user-name))

(define-app hello
  (:title "Hello")
  (:window main :title "Hello" :width 480 :height 240
           :html "<button onclick=\"proteus.invoke('greet', {userName: 'Ada'})
                                      .then(v => document.body.append(v))\">Greet</button>"))

(run-app 'hello)   ; on the main thread; returns when the window is closed
```

## Commands

A command is a Lisp function a page may call by name, with
`proteus.invoke(command, args)`, which returns a Promise of its value.

- Arguments are matched to parameters by name; a Lisp parameter
  `user-name` is the argument `userName`.
- Values cross as JSON does: strings, numbers, booleans, `null` (`:null` in
  Lisp), arrays (vectors) and objects (`equal` hash tables).
- An error in a command, an unknown command or a missing argument rejects
  the Promise with the error's message.
- Each call runs on a thread of its own, so a slow command never holds up
  the window. While it runs, `*command-caller*` is the calling webview and
  `*app*` its application. A command that touches AppKit itself wraps that
  part in cl-iris's `with-main-thread`.
- Only registered commands can be called: nothing else in the image is
  reachable from a page.
- A command stays an ordinary function. Redefining it, or evaluating the
  `define-command` form again, changes what pages call at once.

The call travels through WebKit's script message handler with reply, which
answers the Promise natively; no JavaScript is evaluated to carry it.

## Events

Events are named messages with a JSON-like payload, heard by any number of
listeners in Lisp and in pages.

| From | To | How |
|---|---|---|
| Lisp | Lisp listeners and every page | `(emit "saved" payload)` |
| Lisp | one page | `(emit-to webview "saved" payload)` |
| a page | Lisp listeners and every page | `proteus.emit('saved', payload)` |
| — | listening in Lisp | `(listen-event "saved" fn)`, `listen-event-once`, `unlisten-event` |
| — | listening in a page | `proteus.listen('saved', fn)` and `proteus.once(...)`, which return a function that stops listening |

While a Lisp listener runs, `*event-source*` is the webview a page's event
came from. A listener given as a symbol follows its redefinitions, and an
error in one listener is reported without stopping the others.

## Applications

`define-app` declares an application's windows, their pages, a front-end
directory and the state its commands share; `run-app` shows it.

```lisp
(define-app notes
  (:title "Notes")
  (:frontend "frontend/")               ; next to this source file
  (:state :count 0)
  (:window main :title "Notes" :width 720 :height 480 :page "index.html"))

(define-command count-up ()
  (update-app-state :count #'1+))       ; for *APP*, the app being run
```

- A window takes `make-window`'s options and, for its page, `:page` (a path
  under the front end), `:url` or `:html`.
- The front end is served at `proteus://app/`: content types by extension,
  `index.html` for a directory path, and nothing outside the directory —
  `..` segments are refused even when escaped, and symbolic links that lead
  out are not followed.
- `app-state`, its `setf` and `update-app-state` read and change the state
  under the app's lock.
- Evaluating `define-app` again while the app runs is applied to it: open
  windows are retitled and resized, a changed page is loaded again, new
  windows open and removed ones close. The state is kept.
- `app-window` and `app-webview` find a running app's windows;
  `describe` shows an app's windows and state.

## Systems

| System | What it holds |
|---|---|
| `cl-proteus/core` | commands, events, applications and their state; does not load cl-iris or Cocoa |
| `cl-proteus/shell` | the page bridge, the front-end server and `run-app`, on cl-iris |
| `cl-proteus` | both, and the `cl-proteus` package that re-exports them |

The core stays free of Cocoa so that a process which only defines an
application can load it without AppKit and, later, talk to a separate shell
process that owns the windows.

## Going below

cl-proteus is a thin layer, and everything under it stays reachable:
`app-webview` returns cl-iris `webview` objects, so every cl-iris function
(`eval-js`, `webview-zoom`, `cookies`, ...) works on them, and
`webview-pointer` goes down to the `WKWebView` itself. `make-app-webview`
makes a bridged webview in any cl-iris window, outside an app; `to-json`
writes a value as pages will read it; `list-commands`, `find-command` and
`listeners` show what is registered.

## Examples

`examples/` holds runnable programs; each is run by the test suite.

| Example | Shows |
|---|---|
| `hello.lisp` | a command called from a page |
| `events.lisp` | events both ways and shared state |
| `frontend-dir.lisp` | a front end served from `examples/frontend/` |

```sh
qlot exec sbcl --load examples/hello.lisp
```

## Roadmap

- Building a signed `.app` bundle.
- A socket transport, so commands and views can live in another Lisp image
  than the shell that shows them.

## Development

```sh
scripts/bootstrap    # SBCL 2.6.9 and qlot under .local/, cl-iris 0.2.0
scripts/test         # the test suite; CL_PROTEUS_TEST_ONLY=<text> picks checks by name
```

Test windows are transparent so a run does not flash on the screen;
`CL_PROTEUS_TEST_VISIBLE=1` shows them. Changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute cl-proteus
or work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
