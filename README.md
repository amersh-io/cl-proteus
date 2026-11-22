# cl-proteus

A Tauri-style application framework for Common Lisp, built on
[cl-iris](https://github.com/amersh-io/cl-iris): native windows, web pages
for the interface, and Lisp behind them, all in one SBCL process that you
can change from the REPL while it runs.

> **Status:** early. Commands, events, applications, a served front end,
> shared state, signed `.app` bundles and remote images over a socket work.
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
  under the front end), `:view` (a view's name), `:url` or `:html`.
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

## Bundling

`cl-proteus/bundle` builds a signed macOS application from an app:

```lisp
(asdf:load-system "cl-proteus/bundle")
(cl-proteus/bundle:bundle-app "cl-proteus.examples.frontend-dir::frontend-dir"
                              :load "examples/frontend-dir.lisp"
                              :identifier "org.example.frontend-dir")
;; => #P".../Front end.app/"
```

or, from a shell, `scripts/bundle <app> <file.lisp | system> [:option value]...`.

- A fresh Lisp loads the `:system` or the `:load` files and saves the image;
  it never runs the app, so no window or other Cocoa state is saved with it.
  While it loads, the feature `:cl-proteus-bundle` is present, so a file
  that runs its app when loaded can skip that (`#-cl-proteus-bundle (main)`).
- The app is named by a symbol, or by its text when this Lisp does not have
  the app's package yet.
- The front-end directory is copied into the bundle, and the app serves it
  from there.
- `:name`, `:identifier`, `:version`, `:icon` (an `.icns` file) and `:info`
  (more `Info.plist` entries) describe the bundle; `:run-options` go to
  `run-app`.
- The bundle is signed under the hardened runtime, ad hoc unless
  `:identity` names a signing identity. SBCL runs code it compiles into
  memory, so its runtime gets the one entitlement that allows that
  (`*entitlements*`).
- `:notary-profile` notarizes a bundle signed with a Developer ID: it is
  sent to Apple, waited for, stapled and checked with Gatekeeper. The
  profile is one made once with `xcrun notarytool store-credentials`.

```
Front end.app/Contents/
  Info.plist
  MacOS/frontend-dir     a small launcher, the bundle's executable
  MacOS/sbcl             the SBCL runtime
  Resources/app.core     the saved image
  Resources/frontend/    the front end
```

The image is kept apart from the runtime because a code signature cannot
cover a core appended to an executable, which is how `save-lisp-and-die`
makes one; the launcher starts the runtime with the core whatever
`SBCL_HOME` says. Building it needs a C compiler (`xcode-select --install`).

## Views

A view is a small front end kept in the image instead of a directory,
served at `proteus://view/NAME/`:

```lisp
(define-view notes
  :files ("index.html" "<!doctype html><title>Notes</title><script src=app.js></script>"
          "app.js" "proteus.invoke('list-notes').then(...)"))

(define-view settings :directory "ui/settings/")   ; files read now
```

Evaluating `define-view` again replaces the files, and every page showing
the view is loaded again in its window. `show-view` loads one in a webview;
a window spec takes `:view`.

## Remote images

The windows can live in one process and everything else in another. The
shell runs `serve-shell` on a Unix-domain socket; an image that loads only
`cl-proteus/client` -- no cl-iris, no Cocoa, so it can fork or
`save-lisp-and-die` freely -- connects to it:

```lisp
;; The shell
(serve-shell "/tmp/my-app/shell.sock")
(run-app 'my-shell)                      ; its window shows :view "home"

;; The other image
(asdf:load-system "cl-proteus/client")
(define-command roll (sides) (1+ (random sides)))
(define-view home :files ("index.html" "..."))
(connect-shell "/tmp/my-app/shell.sock")
```

- The client's commands and views are registered on connecting, and any
  defined or changed later are sent at once; a page's `proteus.invoke` of
  one of its commands runs in the client.
- `emit` in the client reaches the shell's pages and Lisp listeners;
  events from pages and from the shell's Lisp reach the client's listeners.
- When the client goes away, its commands go with it and the invokes it
  had not answered are rejected, each once. The windows stay; the next
  client -- the image's next generation -- registers again and the same
  pages carry on.
- The socket and its directory are this user's only. The protocol is
  newline-separated JSON, described in [docs/protocol.md](docs/protocol.md)
  and modelled in [spec/](spec/).

## Systems

| System | What it holds |
|---|---|
| `cl-proteus/core` | commands, events, views, applications and their state, JSON; does not load cl-iris or Cocoa |
| `cl-proteus/shell` | the page bridge, the front-end and view server, `run-app` and the socket server, on cl-iris |
| `cl-proteus` | both, and the `cl-proteus` package that re-exports them |
| `cl-proteus/client` | connecting an image without windows to a shell; core only |
| `cl-proteus/bundle` | building a signed `.app`; loaded where you build, not in the app |

The core stays free of Cocoa so that a process which only defines
commands and views can load it without AppKit and talk to a separate shell
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
| `remote/shell.lisp`, `remote/agent.lisp` | a window in one process, its view and command in another |

```sh
qlot exec sbcl --load examples/hello.lisp
```

## Roadmap

- A first release.
- A shell that restarts its client image when it dies.

## Development

```sh
scripts/bootstrap    # SBCL 2.6.9 and qlot under .local/, cl-iris 0.2.0
scripts/test         # the test suite; CL_PROTEUS_TEST_ONLY=<text> picks checks by name
scripts/check-spec   # the Quint model's tests (needs quint)
```

Test windows are transparent so a run does not flash on the screen;
`CL_PROTEUS_TEST_VISIBLE=1` shows them. Changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute cl-proteus
or work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
