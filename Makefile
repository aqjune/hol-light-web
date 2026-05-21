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
#   site/                 — deployable directory: Web/ outputs + the parent
#                            HOL Light .ml sources (so loadt works in-browser)
#
# Open index.html through a local web server (jsoo bundles can't be
# loaded via file://).  `make serve` does that for you.

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

all: test_node.js hol_top_camlp5.js hol_top_worker.js site

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

# Tier C: browser bundle, loaded as a Web Worker.  Output streams to the
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

# Convenience: build site/ (so loadt resolves against the deployed tree)
# and serve it on http://localhost:8000/.  Depends on the worker bundle so
# a stale edit to hol_top_worker.ml gets rebuilt before the server starts.
serve: site
	python3 -m http.server -d $(SITE_DIR) 8000

# ---- Deployable site -------------------------------------------------------
# `make site` produces ./site/, ready to upload to GitHub Pages or any other
# static host.  Layout mirrors the parent HOL Light tree so the worker can
# resolve `loadt "Library/words.ml"` to `<origin>/Library/words.ml`:
#
#   site/
#     index.html, hol_top_worker.js, pcre2_stubs.js     (Web/ outputs)
#     <flattened copy of ..>                            (the .ml sources)
#
# The exclusion list keeps the deploy size sane: build artefacts, the opam
# switch, the Web/ dir itself, large generated checkpoints, and a few
# external sub-projects that aren't needed at proof-load time.
SITE_DIR    := site
SITE_EXCLUDES := \
  --exclude=/_opam/        --exclude=/Web/          --exclude=/site/         \
  --exclude=/hol-light-web/                                                  \
  --exclude=/TacticTrace/  --exclude=/UnitTests/    --exclude=/Proofrecording/ \
  --exclude=/ProofTrace/   --exclude=/Minisat/      --exclude=/Cadical/      \
  --exclude=/mcp/          --exclude=/pa_j/                                  \
  --exclude=/update_database/  --exclude=/update_database.ml                 \
  --exclude=/pa_j.ml                                                         \
  --exclude=/hol.ml        --exclude=/hol_lib.ml                             \
  --exclude=/hol_lib_use_module.ml                                           \
  --exclude=/load_camlp*.ml                                                  \
  --exclude=/README                                                          \
  --exclude=*_inlined.ml                                                     \
  --exclude=/opam          --exclude=/META          --exclude=/LICENSE       \
  --exclude=/CHANGES       --exclude=/Makefile                               \
  --exclude=*.txt          --exclude=*.sed          --exclude=*.sh           \
  --exclude=*.mk                                                             \
  --exclude=*.ckpt                                                           \
  --exclude=*.cmi   --exclude=*.cmo   --exclude=*.cmx   --exclude=*.cmxa     \
  --exclude=*.cma   --exclude=*.cmt   --exclude=*.cmti  --exclude=*.o        \
  --exclude=*.a     --exclude=*.so    --exclude=*.byte  --exclude=*.native   \
  --exclude=/ocaml-hol --exclude=/holtest_parallel --exclude=/a.out          \
  --exclude=.git/                                                            \
  --exclude=.gitignore     --exclude=.gitattributes                          \
  --exclude=.github/

site: hol_top_worker.js index.html
	rm -rf $(SITE_DIR)
	mkdir -p $(SITE_DIR)
	# 1. Mirror the parent HOL Light tree (just .ml/.hl/etc. — see SITE_EXCLUDES).
	rsync -a --delete $(SITE_EXCLUDES) $(HOL)/ $(SITE_DIR)/
	# 2. Drop the Web/ outputs at the site root so index.html is the entrypoint.
	#    pcre2_stubs.js is linked into hol_top_worker.js at build time, not
	#    loaded by the page, so it isn't deployed.
	cp index.html hol_top_worker.js $(SITE_DIR)/
	@echo
	@echo "site/ ready ($$(du -sh $(SITE_DIR) | cut -f1)).  Try:"
	@echo "    python3 -m http.server -d $(SITE_DIR) 8000"

clean:
	rm -f *.cmo *.cmi *.byte export.txt
	rm -f test_node.js hol_top_camlp5.js hol_top_worker.js
	rm -rf $(SITE_DIR)

.PHONY: all serve site clean
