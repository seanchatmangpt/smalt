# BK-VCOURTS lane (v26.10.22) — consolidated validation-board courts.
# One named court run covering three VALIDATION.md §3 PENDING rows;
# exits 1 on any leg failure.

# COURT-BOOT-REBIND (TTV-4 warm-restart replay court) + COURT-ATOM-CLAMP / COURT-CERT-OBS
@bkvc-court:
    export PATH="$HOME/.asdf/shims:$PATH"; \
    MIX_BUILD_ROOT=_build-bkvc mix test \
      test/integration/ttv4_journal_boot_replay_court_test.exs \
      test/internal/bkvc_consolidated_court_test.exs
