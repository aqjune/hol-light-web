//Provides: pcre2_ocaml_init
function pcre2_ocaml_init() { return 0; }

// Compile returns an opaque "regex" object — we never run it (HOL Light
// does not exercise the camlp5 quoted-extension lexer path), so a dummy
// suffices.  It must NOT throw at compile time, since camlp5 calls
// Pcre2.regexp at module-init time for its quotedext lexer.
//Provides: pcre2_compile_stub_bc
function pcre2_compile_stub_bc() { return [0, 0]; }

// Match never gets called for HOL Light's expected inputs.  If it ever
// does, raise so we notice rather than silently misbehaving.
//Provides: pcre2_match_stub_bc
//Requires: caml_failwith
function pcre2_match_stub_bc() {
  caml_failwith("pcre2_match_stub_bc: not available in jsoo");
}

//Provides: pcre2_capturecount_stub_bc
function pcre2_capturecount_stub_bc() { return 0; }

//Provides: pcre2_config_unicode_stub
function pcre2_config_unicode_stub() { return 1; }

//Provides: pcre2_config_newline_stub
function pcre2_config_newline_stub() { return 10; }

//Provides: pcre2_config_link_size_stub_bc
function pcre2_config_link_size_stub_bc() { return 2; }

//Provides: pcre2_config_match_limit_stub_bc
function pcre2_config_match_limit_stub_bc() { return 10000000; }

//Provides: pcre2_config_depth_limit_stub_bc
function pcre2_config_depth_limit_stub_bc() { return 10000000; }

//Provides: pcre2_config_stackrecurse_stub
function pcre2_config_stackrecurse_stub() { return 0; }

//Provides: pcre2_set_imp_match_limit_stub_bc
function pcre2_set_imp_match_limit_stub_bc(re, _) { return re; }

//Provides: pcre2_set_imp_depth_limit_stub_bc
function pcre2_set_imp_depth_limit_stub_bc(re, _) { return re; }

//Provides: pcre2_version_stub
function pcre2_version_stub() { return "pcre2-stub-jsoo"; }
