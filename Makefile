# sdk builds the Turso C ABI outside any sandbox; `opam install` needs it first.
.PHONY: sdk test
sdk:
	cd ocaml/sdk && sh build-sdk.sh --cache-only
test:
	cargo test --features turso
	opam exec --switch=default -- dune test --root . --build-dir _build-default --force
	opam exec --switch=5.2.0+ox -- dune test --root . --build-dir _build-5.2.0+ox --force
