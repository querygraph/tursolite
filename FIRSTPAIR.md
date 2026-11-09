slug: tursolite
shelf: unix
default_edition: full

# Publication contract

This repository owns the code, the manual in `docs/tursolite-manual.md`, and the
cover and headboard in `cover/`. FirstPair owns catalog entries, stable download
and reader routes, and Blob manifests. Follow the shared `~/src/firstpair/AGENTS.md`
publication rules.

The manual is by Alexy Khrabrov with Claude as co-author. The code is Apache 2.0;
Turso's C header, `ocaml/sdk/turso.h`, is MIT.

`cover/tursolite-cover.png` is the book cover and `cover/tursolite-headboard.png`,
without text, is the shelf headboard; both are the user's art.

```sh
PATH=/usr/local/bin:$PATH ~/src/firstpair/publishing/scripts/build-library-book.sh --repo-root ~/src/tursolite
cd ~/src/firstpair
npm run library:publish -- ~/src/tursolite --source https://github.com/querygraph/tursolite
```
