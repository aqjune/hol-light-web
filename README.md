# HOL Light in the browser via js_of_ocaml

This directory is an experiment in running HOL Light in JavaScript using
[`js_of_ocaml`](https://ocsigen.org/js_of_ocaml/).  All the moving pieces from
`hol.sh` (the OCaml toplevel, camlp5 with HOL Light's backquote syntax,
`zarith` big integers, the full `hol_lib`) end up linked into a single `.js`
bundle that runs unmodified in node and in modern browsers.

The browser demo (`index.html` + `hol_top_worker.js`) loads HOL Light into a
**Web Worker** so the UI stays responsive during the ~1–2 minute kernel
bootstrap, and stdout/stderr stream live to the page as Format buffers
flush — same hook jsoo's own `lwt_toplevel` example uses.

## What's here

| File | What it does |
| --- | --- |
| `test_node.ml` / `test_node.js` | Smallest possible smoke test: a single `prove` call, no REPL. Uses camlp5 only at *compile* time. |
| `hol_top_node.ml` / `hol_top_camlp5.js` | Node-side REPL that links camlp5 + `pa_j.cmo` *into* the JS bundle, so backquoted terms parse natively. |
| `hol_top_worker.ml` / `hol_top_worker.js` | Web Worker bundle.  Posts each Sys_js channel flush back to the page as a `{kind:"out",stream,text}` message; the page renders them live. |
| `index.html` | REPL UI: dark-theme two-pane layout, `↑/↓` history backed by `localStorage`, `Ctrl+L` clear, `Ctrl+K` reset, ANSI-color rendering of HOL Light's colored printers. Modelled on jsoo's `lwt_toplevel/index.html`. |
| `hol_top_browser.ml` / `hol_top_browser.js` | (Legacy) main-thread bundle exposing `window.holEval(src)`.  Not built by `make all` anymore but kept for reference / embedding. Build with `make hol_top_browser.js`. |
| `pcre2_stubs.js` | No-op JS stubs for camlp5's pcre2 dependency (HOL Light never exercises it). |

## Build

```sh
eval $(opam env --switch .. --set-switch)
# the parent tree must already have `make hol_lib.cma`
make            # builds test_node.js, hol_top_camlp5.js, hol_top_worker.js
make serve      # starts python3 -m http.server on :8000
```

## Try it

```sh
node hol_top_camlp5.js          # ~60s startup; runs three smoke proofs
```

For the browser demo, open `http://localhost:8000/` after `make serve`.

The page boots the Worker immediately and shows the kernel's bootstrap output
(the `0..0..1..solved at N` lines) live in the terminal pane.  Once `* HOL-Light
syntax in effect *` and the printer-install lines appear, the input is enabled
and you can type phrases.

## How the camlp5 trick works

Without camlp5, the in-browser OCaml parser refuses identifiers like
`ARITH_TAC` in expression position — uppercase means *constructor* in
plain OCaml.  HOL Light side-steps this with a camlp5 syntax extension
(`pa_j.cmo`) that flips `Pcaml.no_constructors_arity` to `True`.

The recipe:

1. Static-link `camlp5o.cma` (which already bundles
   `Pcaml`/`Grammar`/`Camlp5_top_funs`) plus `pa_j.cmo` into the bytecode
   that becomes the JS toplevel.
2. Provide JS stubs for pcre2's C primitives (camlp5 imports `pcre2` for
   its `Quotedext` lexer).  HOL Light never triggers that path, so the
   stubs need only be no-ops.
3. Pass the assembled bytecode through `js_of_ocaml --toplevel
   --export export.txt`, including the right `-I` directories so jsoo
   embeds `Hol_lib`'s CMI alongside `Stdlib`'s.

That's it: the `* HOL-Light syntax in effect *` banner now prints inside
the JavaScript runtime, and `g \`...\`;; e ARITH_TAC;; top_thm()` works
end-to-end.

## How the printers get installed

The browser toplevel doesn't run `hol.ml`, so HOL Light's printer
registrations there don't fire.  After the kernel finishes loading, the
worker emits these phrases via `JsooTop.execute` so the toplevel resolves
the names against the just-opened `Hol_lib` environment:

```
open Hol_lib;;
#install_printer pp_print_num;;
#install_printer pp_print_fpf;;
#install_printer pp_print_colored_qterm;;
#install_printer pp_print_colored_qtype;;
#install_printer pp_print_colored_thm;;
#install_printer pp_print_colored_goal;;
#install_printer pp_print_colored_goalstack;;
```

The colored variants emit raw ANSI escape sequences (e.g. `\x1b[36m` for
types, `\x1b[31m` for invented type variables); `index.html` translates
them to `<span class="ansi-N">…</span>` on the page side.

## How streaming works

`hol_top_worker.ml` opens four `Sys_js` channels (`stdout`, `stderr`,
`/dev/sharp`, `/dev/caml`) and registers a flusher on each that calls
`Worker.post_message ({kind:"out", stream, text})`.  The flushers are
installed *before* `JsooTop.initialize`, so even the kernel's bootstrap
output (~140s of "solved at N" lines) reaches the page as it's produced.

`index.html` listens for these messages and appends them to the output
`<pre>` with a CSS class per stream.  Because all of this happens on the
main thread, the page can repaint between flushes — the browser feels
responsive even while the worker is busy.

## Caveats / known gotchas

- **First-load cost.**  ~140 s in node v22 to bootstrap the whole kernel
  (vs ~33 s native bytecode).  After that, individual proofs run at
  jsoo speed.  A `make-checkpoint`-style serialized image would skip
  the bootstrap; `Marshal` works under jsoo so that is feasible.
- **No `Unix`, no filesystem.**  Anything that calls `Sys.getcwd`,
  `loadt`, or reads files from disk needs to be backed by jsoo's
  in-memory filesystem (`Sys_js.create_file`).  HOL Light's `loadt`
  paths assume `Sys.file_exists`, which jsoo supports for files
  registered through `Sys_js.create_file`.
- **`Library/words.ml` and other extra modules** are NOT in the bundle.
  Only what's already statically linked into `hol_lib.cma` is available.
  Loading them at runtime requires `Dynlink`-on-jsoo (works for
  bytecode `.cma`s, but each extra `.cma` needs to be served and fed in
  through `Sys_js.create_file`).
- **Memory.**  `node --max-old-space-size=8192 …` is recommended for
  bigger proofs; the default 4 GiB is sometimes tight.
- **pcre2 stubs** are shims; if camlp5 ever lexes an OCaml `{%foo|…|}`
  quoted-extension the match call will throw a `Failure` we can detect.
