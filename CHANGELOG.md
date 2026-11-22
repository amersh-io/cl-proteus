# Changelog

All notable changes to cl-proteus are listed here. The project follows
[Semantic Versioning](https://semver.org/); until 1.0, a minor release may
change the API. No version has been released yet.

## Unreleased

### Commands

- `define-command` registers a Lisp function pages call with
  `proteus.invoke(command, args)`, a Promise; arguments match parameters by
  name (`user-name` is `userName`), and errors reject the Promise.
- Each call runs on a thread of its own, with `*command-caller*` and `*app*`
  bound; redefining a command takes effect with pages open.

### Events

- `emit`, `emit-to`, `listen-event`, `listen-event-once` and
  `unlisten-event` in Lisp; `proteus.emit`, `proteus.listen` and
  `proteus.once` in pages. Events from pages reach Lisp, with
  `*event-source*` bound, and every page.

### Applications

- `define-app` declares windows, their pages, a front-end directory and
  shared state; `run-app` shows them. Evaluating `define-app` again while
  the app runs is applied to its open windows.
- `app-state`, its `setf` and `update-app-state` share state between
  commands under the app's lock.
- A front-end directory is served at `proteus://app/`, with nothing outside
  it reachable.

### Bundling

- `cl-proteus/bundle`: `bundle-app` builds `Name.app` from an app, its
  image saved by a fresh Lisp that never runs it, its front end copied in
  and served from the bundle, and signs it under the hardened runtime (ad
  hoc, or with a signing identity). `scripts/bundle` does the same from a
  shell.
- The runtime and the image are kept apart, started by a small launcher, so
  that `codesign --verify --deep --strict` passes.
- Examples skip running their app when loaded for a bundle
  (`:cl-proteus-bundle`).

### Around the code

- Examples in `examples/`, each run by the test suite in a child Lisp.
- A check that every external symbol is documented.
- Tests keep their windows transparent; CI on macOS.
- Depends on cl-iris 0.2.0.
