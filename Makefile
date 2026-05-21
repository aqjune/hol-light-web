# Build HOL Light for the browser via js_of_ocaml.
#
# Run from this directory.  Assumes the local opam switch one level up has
# been activated (`eval $(opam env --switch ../ --set-switch)`) and that
# `make hol_lib.cma` has already been run in the parent HOL Light tree.
#
# Outputs:
#   test_node.js          — node smoke test (no toplevel)
#   hol_top_camlp5.js     — node REPL with camlp5 + backquote syntax
#   hol_top_worker.js     — Web Worker bundle driving index.html
#   hol_top_browser.js    — (legacy) main-thread bundle exposing window.holEval;
#                            kept as a reference, not built by default
#
# Open index.html through a local web server (jsoo bundles can't be
# loaded via file://).  E.g.:
#     python3 -m http.server -d . 8000
#     # then open http://localhost:8000/

HOL    := ..
CAMLP5 := $(shell ocamlfind query camlp5)
ZJS    := $(shell ocamlfind query zarith_stubs_js)/runtime.js

CMOS   := $(HOL)/bignum.cmo $(HOL)/hol_loader.cmo $(HOL)/hol_lib.cmo
CAMLP5_LINK := $(CAMLP5)/camlp5o.cma $(HOL)/pa_j.cmo

PKGS   := zarith,js_of_ocaml,js_of_ocaml-toplevel,fmt,pcre2,camlp-streams

INCS   := -I $(HOL) \
          -I $(HOL)/_opam/lib/zarith \
          -I $(HOL)/_opam/lib/ocaml/compiler-libs \
          -I $(HOL)/_opam/lib/js_of_ocaml-toplevel \
          -I $(CAMLP5)

JSOO_FLAGS := --toplevel --export export.txt --disable shortvar \
              -w no-missing-effects-backend $(INCS) $(ZJS) pcre2_stubs.js

all: test_node.js hol_top_camlp5.js hol_top_worker.js

# Export list shared by all toplevel bundles
export.txt:
	jsoo_listunits -o $@ stdlib zarith js_of_ocaml-toplevel \
	  $(HOL)/hol_lib.cmi $(HOL)/bignum.cmi $(HOL)/hol_loader.cmi

# Tier A: tiny program (no REPL) that just runs prove (...).  Useful as a
# minimum-working-example for "HOL Light evaluation runs in node".
test_node.byte: test_node.ml $(CMOS)
	ocamlfind ocamlc -package zarith -pp "`$(HOL)/hol.sh -pp`" \
	  -I $(HOL) -c $<
	ocamlfind ocamlc -package zarith -linkpkg -I $(HOL) \
	  $(CMOS) test_node.cmo -o $@

test_node.js: test_node.byte
	js_of_ocaml $(ZJS) $< -o $@

# Tier B: node REPL with camlp5+pa_j linked.  Demonstrates full backquote
# syntax + g/e/top_thm working under jsoo.
hol_top_camlp5.byte: hol_top_node.ml $(CMOS) $(HOL)/pa_j.cmo
	ocamlfind ocamlc -linkall -linkpkg -package $(PKGS) \
	  -I $(HOL) -I $(CAMLP5) \
	  $(CMOS) $(CAMLP5_LINK) $< -o $@

hol_top_camlp5.js: hol_top_camlp5.byte export.txt pcre2_stubs.js
	js_of_ocaml $(JSOO_FLAGS) $< -o $@

# Tier C: browser bundle.  index.html drives this via window.holEval.
hol_top_browser.byte: hol_top_browser.ml $(CMOS) $(HOL)/pa_j.cmo
	ocamlfind ocamlc -linkall -linkpkg -package $(PKGS) \
	  -I $(HOL) -I $(CAMLP5) \
	  $(CMOS) $(CAMLP5_LINK) $< -o $@

hol_top_browser.js: hol_top_browser.byte export.txt pcre2_stubs.js
	js_of_ocaml $(JSOO_FLAGS) $< -o $@

# Tier D: same as Tier C but loaded as a Web Worker.  Output streams to the
# main page via postMessage so HOL Light's bootstrap and proof commands feel
# like a live REPL.  index.html drives this via new Worker(...).
#
# web_init.cmo is linked BEFORE hol_lib.cmo so its top-level code installs
# the Sys_js channel flushers before HOL Light starts emitting "solved at N"
# during boot — otherwise that output races past our flushers and is lost.
web_init.cmo: web_init.ml
	ocamlfind ocamlc -package js_of_ocaml -I $(HOL) -c $<

hol_top_worker.byte: hol_top_worker.ml web_init.cmo $(CMOS) $(HOL)/pa_j.cmo
	ocamlfind ocamlc -linkall -linkpkg -package $(PKGS) \
	  -I $(HOL) -I $(CAMLP5) \
	  web_init.cmo $(CMOS) $(CAMLP5_LINK) $< -o $@

hol_top_worker.js: hol_top_worker.byte export.txt pcre2_stubs.js
	# --effects=cps trampolines every call so HOL Light's deep bootstrap
	# recursion doesn't blow the Web Worker's small JS stack (≈0.5 MB in
	# Chrome).  Costs ~2x runtime + ~30% bundle, but it's the only way to
	# avoid "Stack_overflow" in the worker; main-thread bundles get away
	# without it because they have a ~8 MB stack.
	js_of_ocaml $(JSOO_FLAGS) --effects=cps $< -o $@

# Convenience: serve the browser demo locally on http://localhost:8000/.
# Depends on the bundles index.html actually loads, so a stale edit to
# hol_top_worker.ml gets rebuilt before the server starts.
serve: hol_top_worker.js index.html pcre2_stubs.js
	python3 -m http.server -d . 8000

clean:
	rm -f *.cmo *.cmi *.byte export.txt
	rm -f test_node.js hol_top_camlp5.js hol_top_browser.js hol_top_worker.js

.PHONY: all serve clean
