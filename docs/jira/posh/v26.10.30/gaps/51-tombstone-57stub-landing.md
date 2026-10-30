# Lane 51 — Tombstone hard-delete + 57-tf-provider archived-stub landing

Date: 2026-10-30. Executes G13's closes. Subject: `/Users/sac/smalt`.

## (1) Tombstone hard-delete

`/Users/sac/smalt/terraform-provider-smalt/` held only the untracked
`README.md` tombstone. Removed (plain rm, no git action; the record is the
archive tarball).

Falsifier (posh007-errc-delete-receipt.json check), verbatim:

```
$ test ! -d /Users/sac/smalt/terraform-provider-smalt && echo "FALSIFIER-PASS: dir gone"
FALSIFIER-PASS: dir gone
```

## (2) justfile.d/57-tf-provider.just stub guards

mix.exs existence guard added at the top of the shebang body of
`provider-build`, `provider-install`, `provider-court-elixir`, and the
deprecated alias `provider-court` (before any kind ladder / delegation):

```just
if [ ! -f "{{TFROOT}}/{{SMALT_TF_DIR}}/mix.exs" ]; then
  echo "[TF-ARCHIVED] {{SMALT_TF_DIR}}/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)" >&2
  exit 4
fi
```

## (3) F15 pointer fold-in

One-line index note added to
`docs/jira/posh/v26.10.30/README.md` (POSH-007 row) folding in the
archive-stub README pointer: sole record of the Elixir spike tree is
`tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
(78,080,628 bytes, Oct 30 11:07); active implementation is
`adapters/terraform-provider-smalt`.

## Verification (verbatim outputs)

```
$ just --evaluate                      # exit 0
evaluate exit=0

$ just provider-build                  # exit 4, typed line, no build attempted
[TF-PREREQ] just/kubectl/terraform/mix present (go not required)
[TF-ARCHIVED] terraform-provider-smalt/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)
error: recipe `provider-build` failed with exit code 4

$ just provider-court-elixir           # exit 4, fast (prereq checks only, NO kind ladder)
[KIND-PREREQ] kind/kubectl/docker present
[TF-PREREQ] just/kubectl/terraform/mix present (go not required)
[TF-ARCHIVED] terraform-provider-smalt/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)
error: recipe `provider-court-elixir` failed with exit code 4

$ just provider-court                  # deprecated alias: exit 4, fast (guard before deprecation echo)
[TF-ARCHIVED] terraform-provider-smalt/mix.exs absent — Elixir spike tree archived to tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz; active implementation: adapters/terraform-provider-smalt (GA court: just posh-court, 58-posh.just)
error: recipe `provider-court` failed with exit code 4
```

## Standing

ALIVE — falsifier green (`test ! -d` passes) + stub exit 4 with typed
`[TF-ARCHIVED]` on all three recipes and the alias. Files touched:
`justfile.d/57-tf-provider.just` (4 guards),
`docs/jira/posh/v26.10.30/README.md` (1 line), tombstone dir deleted.
