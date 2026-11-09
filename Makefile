# sdk builds the Turso C ABI outside any sandbox; `opam install` needs it first.
.PHONY: sdk test test-rust test-ocaml test-python
sdk:
	cd ocaml/sdk && sh build-sdk.sh --cache-only
test: test-rust test-ocaml test-python
test-rust:
	cargo test --features turso
test-ocaml:
	opam exec --switch=default -- dune test --root . --build-dir _build-default --force
	opam exec --switch=5.4.0+ox -- dune test --root . --build-dir _build-5.4.0+ox --force
test-python:
	cd python && uv run --locked pytest -q
