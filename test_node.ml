(* Smoke test: prove a trivial theorem entirely from OCaml source
   (no backquote syntax — uses parse_term explicitly), then run under node. *)

open Hol_lib;;

let () =
  let tm = parse_term "x + 1 = 1 + x" in
  let th = prove (tm, ARITH_TAC) in
  Format.printf "Proved: %s@." (string_of_thm th);
  Format.printf "Done.@.";;
