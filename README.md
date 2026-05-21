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

## Run it without building

The `site/` directory in this repo is **pre-built and self-contained** —
just serve it.  No opam, no `make`, no compiler:

```sh
python3 -m http.server -d site 8000
# then open http://localhost:8000/
```

You only need the "Build" section below if you want to rebuild the bundle
(e.g. you edited `hol_top_worker.ml` or want to bump the parent HOL Light
version).

The committed `site/` was built from
[jrh13/hol-light @ 9b510bc](https://github.com/jrh13/hol-light/commit/9b510bc76da4cecf6e509be44d327c9236ec273f)
("Bump python-multipart from 0.0.24 to 0.0.27 in /mcp", 2026-05-18).
Whoever rebuilds `site/` should update this reference **here** and in the
sidebar link in `index.html` (search for "Built from" to find it).

## What's here

### Hand-written sources

These files are the actual contributions of this directory; they live in
git and are what you edit:

| File | What it does |
| --- | --- |
| `web_init.ml` | Tiny module linked **first** into the worker bundle.  Installs `Sys_js.set_channel_flusher` on `stdout`/`stderr` before HOL Light's bootstrap runs, so the kernel's "solved at N" lines stream to the page instead of being lost. |
| `hol_top_worker.ml` | Web Worker entry point.  Mounts an HTTP-backed pseudo-FS (`Sys_js.mount` + sync XHR), opens four `Sys_js` channels (stdout/stderr/sharp/caml) plus their flushers, runs `JsooTop.initialize`, opens `Hol_lib`, installs the colored printers, wires `Hol_loader.file_loader` so `loads/loadt/needs` work, and runs the postMessage loop driven by `index.html`. |
| `hol_top_node.ml` | Node-side smoke REPL.  Same idea as the worker, minus the postMessage / Sys_js plumbing — handy for testing that the camlp5 + `Hol_lib` link works at all (`node hol_top_camlp5.js`). |
| `test_node.ml` | Smallest-possible bundle: a single `prove` call with no REPL.  Useful as a minimum-working-example. |
| `index.html` | REPL UI: dark-theme two-pane layout, `↑/↓` history backed by `localStorage`, `Ctrl+L` clear, `Ctrl+K` reset, ANSI-color rendering of HOL Light's colored printers.  Modelled on jsoo's `lwt_toplevel/index.html`. |
| `pcre2_stubs.js` | No-op JS stubs for camlp5's pcre2 dependency (HOL Light never exercises it).  Linked into the worker bundle at build time. |
| `patches/*.patch` | Tiny unified diffs applied to the deployed `site/`'s copy of upstream files.  Each patch adds a hook (a `ref` callback) so jsoo-specific behaviour can be injected without forking the upstream file.  `make site` applies them with `patch -F0 --forward`; ANY drift in surrounding context fails the build, so we notice when an upstream edit lands near a hook. |
| `Makefile`, `README.md`, `.gitignore` | Build glue, this file, and what to keep out of git. |

#### Current patches

| Patch | Hook it adds | Why |
| --- | --- | --- |
| `patches/help.ml.patch` | `help_listing` and `help_render` refs | Upstream `help` calls `Sys.readdir` (no directory enumeration over HTTP) and `Sys.command "sed -f doc-to-help.sed"` (no shell under jsoo).  The worker installs hooks that read a pre-computed `Help/index.txt` and apply a minimal OCaml port of doc-to-help.sed. |

Note: `update_database.ml` is *not* shipped to `site/` (excluded in the
Makefile) and is *not* loaded by the worker.  Under `HOLLIGHT_USE_MODULE=1`
the env walker has to round-trip every candidate name through the
typechecker, which makes `search` unusably slow in the browser.  Users
who want it can paste `loadt "update_database.ml";;` themselves.

#### Refreshing a patch after upstream churn

If `make site` reports `PATCH FAILED: patches/foo.ml.patch`:

```sh
# 1. Mirror the latest parent file untouched, then apply the old patch
#    by hand, fix any rejects, and regenerate the .patch file.
cp ../foo.ml /tmp/foo.ml.orig
cp /tmp/foo.ml.orig /tmp/foo.ml.new
# ... edit /tmp/foo.ml.new to re-introduce the hook ...
diff -u /tmp/foo.ml.orig /tmp/foo.ml.new \
  | sed 's|/tmp/foo.ml.orig|a/foo.ml|; s|/tmp/foo.ml.new|b/foo.ml|' \
  > patches/foo.ml.patch
make site   # should now apply cleanly
```

### Generated artefacts

These are produced by `make`.  Most are excluded from git (see `.gitignore`);
the exception is `site/`, which is checked in pre-built so the demo runs
without building anything (see "Run it without building" above).

| Output | In git? | How it's produced |
| --- | --- | --- |
| `*.cmo` / `*.cmi` / `*.byte` | no | `ocamlfind ocamlc` from the `.ml`s above plus the parent tree's `bignum.cmo`, `hol_loader.cmo`, `hol_lib.cmo`, and `pa_j.cmo`. |
| `export.txt` | no | `jsoo_listunits` enumeration of the OCaml units the toplevel must keep around at runtime (so `JsooTop` can resolve identifiers in `Hol_lib`, `Stdlib`, `Zarith`, …). |
| `test_node.js`, `hol_top_camlp5.js`, `hol_top_worker.js` (top-level copies) | no | `js_of_ocaml --toplevel --export export.txt …` over the corresponding `.byte`.  The worker bundle additionally passes `--effects=cps` (see "How streaming works"). |
| `site/` | **yes** | `make site` (or `make all`, which now includes it) — `rsync` of the parent HOL Light tree minus excludes, plus `index.html` and `hol_top_worker.js` dropped at the root.  Re-running `make site` regenerates the directory in place; commit the diff alongside the parent-commit reference at the top of this README. |

## Build

Prerequisites:

1. **Parent switch + `hol_lib.cma`.**  The worker bundle links the parent's
   `.cmo`s directly, so the parent tree's opam switch must exist and
   `hol_lib.cma` must have been built at least once:

   ```sh
   cd ..
   make switch-5
   eval $(opam env --set-switch)
   export HOLLIGHT_USE_MODULE=1
   make            # one-time, in the parent tree
   cd Web
   ```
2. **Extra opam packages** for jsoo (the parent switch doesn't install
   these by default):

   ```sh
   opam install -y js_of_ocaml js_of_ocaml-toplevel zarith_stubs_js
   ```

   `js_of_ocaml` provides the compiler and runtime, `*-toplevel` provides
   `JsooTop` (the in-bundle REPL machinery), and `zarith_stubs_js` ships
   the JS implementation of zarith's C primitives.  The other packages
   this Makefile pulls in (`zarith`, `camlp5`, `fmt`, `pcre2`,
   `camlp-streams`) come along with `make switch-5` and the parent build.

Then, from this directory:

| Command | What it does |
| --- | --- |
| `make` / `make all` | Builds `test_node.js`, `hol_top_camlp5.js`, `hol_top_worker.js`, **and** mirrors the parent tree into `./site/` (see "Deploy"). |
| `make serve` | Builds `site/` (so `loadt` resolves against the deployed tree) and starts `python3 -m http.server -d site 8000`.  Open <http://localhost:8000/> to use the demo. |
| `make site` | Just the `site/` step — already covered by `make all`, but useful if you only want the deploy directory. |
| `make clean` | Removes build artefacts (`*.cmo`, `*.cmi`, `*.byte`, `export.txt`) and the top-level JS bundles.  **Does not touch `site/`** — that's checked in. |
| `make clean-site` | Removes `site/`.  After this you'll need `make site` (or just `make`) to recreate it. |
| `make distclean` | `clean` + `clean-site`. |

## Try it

```sh
node hol_top_camlp5.js          # ~60s startup; runs three smoke proofs
```

This is also what CI runs — see `.github/workflows/ci.yml`, which builds
the bundle from a fresh switch on every PR/push and asserts the three
smoke phrases produce their expected output under Node.js.

For the browser demo, open `http://localhost:8000/` after `make serve`.

The page boots the Worker immediately and shows the kernel's bootstrap output
(the `0..0..1..solved at N` lines) live in the terminal pane.  Once `* HOL-Light
syntax in effect *` and the printer-install lines appear, the input is enabled
and you can type phrases.

> **Don't open `index.html` directly via `file://`.**  Browsers treat every
> `file://` URL as a unique origin and refuse to construct a Web Worker from
> one (`SecurityError: Failed to construct 'Worker': … cannot be accessed
> from origin 'null'`).  Always serve the directory over HTTP — `make serve`
> handles this, or run `python3 -m http.server -d site 8000` against an
> already-built `site/` and open <http://localhost:8000/>.  Once deployed
> to GitHub Pages / Netlify the constraint goes away because the page is
> served over `https://`.

## Deploy

`make site` produces a self-contained `site/` directory you can upload to
GitHub Pages, Netlify, or any other static host:

```
site/
├── index.html, hol_top_worker.js                   (Web/ outputs)
├── 100/, Library/, Multivariate/, Probability/, …  (HOL Light .ml sources)
├── *.ml                                            (kernel sources)
└── …
```

The layout mirrors the parent HOL Light tree, so `loadt "Library/words.ml"`
resolves to `<origin>/Library/words.ml` over plain HTTP — see the next
section.

`make site` excludes the opam switch, build artefacts (`*.cmo`, `*.byte`,
checkpoints, native binaries), and a few sub-projects that aren't needed at
proof-load time (`TacticTrace`, `UnitTests`, `Proofrecording`, `ProofTrace`,
`Minisat`, `Cadical`, `mcp`, `pa_j/`, `update_database/`, `*.ckpt`).
Everything else from the parent tree comes along.

Total deploy size: ~70 MB.  ~16 MB of that is `hol_top_worker.js` (compresses
to ~3 MB on the wire under brotli/gzip).

## How `loads`/`loadt`/`needs` work

HOL Light's `loadt "Library/words.ml"` (and `loads`, `needs`) read `.ml` files
off disk and feed them through the toplevel.  Under jsoo there is no disk —
so we synthesize one out of `Sys_js.mount` plus synchronous XHR.

The wiring, all in `hol_top_worker.ml`:

1. `Sys_js.mount ~path:"/" hol_fs_handler` — when the OCaml runtime tries
   `Sys.file_exists "/Library/words.ml"` or `open_in "/Library/words.ml"`
   and the file isn't already in the in-memory FS, jsoo calls
   `hol_fs_handler` with the path, which runs a synchronous
   `XMLHttpRequest GET /Library/words.ml`.  Sync XHR is allowed inside Web
   Workers (only deprecated on the main thread), so `loadt`'s assumption
   that file reads are synchronous is satisfiable.  The fetched bytes get
   cached in the in-memory FS, so `Digest.file` works (HOL Light's
   `loaded_files` de-dup) and re-`loadt` is a no-op.
2. `Hol_loader.hol_dir := "/"` — HOL Light's default `load_path` is
   `["."; "$"]`, with `$` substituted by `!hol_dir`.  Pointing it at `/`
   means `loadt "Library/words.ml"` resolves to `/Library/words.ml`, which
   our handler then fetches over HTTP.
3. `Hol_loader.file_loader := (fun fname -> ...)` — the worker installs a
   custom loader that reads the (now cached) file and calls
   `JsooTop.use Format.std_formatter` on its contents.  That runs each
   `;;`-terminated phrase through the same toplevel as the REPL, so
   camlp5's backquote syntax extension is in effect for loaded files.

Net effect: with the deployed `site/` layout, you can paste

```ocaml
loadt "Library/words.ml";;
```

into the REPL and the worker will fetch the source from `<origin>/Library/words.ml`,
evaluate it phrase by phrase with output streaming live, and remember it so
subsequent `needs`/`loadt` calls short-circuit.

(Limits: only `.ml` sources work — `loadt "foo.cma"` would need
`Dynlink`-style support, not yet wired up.  And anything `loadt`'s file
ends up referencing must also be reachable under the deploy root.)

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
- **No `Unix`.**  Filesystem reads (`Sys.file_exists`, `open_in`,
  `loadt`) are served by `Sys_js.mount` + sync XHR (see "How
  loads/loadt/needs work" above), so plain `.ml` loads work.  But
  anything that needs `Unix` proper — `fork`, sockets, file metadata
  beyond `Sys.file_exists` — won't.
- **`.cma` loading is not wired up.**  Only `.ml` sources can be loaded
  at runtime.  Loading additional `.cma`s would require `Dynlink`-on-jsoo;
  for now the only way to get extra modules into the bundle is to link
  them into `hol_lib.cma` ahead of time.
- **Memory.**  `node --max-old-space-size=8192 …` is recommended for
  bigger proofs; the default 4 GiB is sometimes tight.
- **pcre2 stubs** are shims; if camlp5 ever lexes an OCaml `{%foo|…|}`
  quoted-extension the match call will throw a `Failure` we can detect.
