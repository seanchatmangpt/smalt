# KD-H09

Standing: UNVERIFIED

Lane H09 (tax, ERP, SWAR). Provider code: `lib/smalt/h09/`; tests: `test/h09/h09_test.exs`.
Not compiled or run in this lane (hook blocks); coordinator runs `mix test test/h09`.

Wiring needed: in `lib/smalt/planes/router.ex` add `forward("/h09", to: Smalt.H09.Router)`.

| id | surface | divergence | evidence | close condition |
|---|---|---|---|---|
| KD-H09-01 | FIRE T/A/F record offsets | only B-record offsets and TIN 12-20 match Pub 1220 vectors; T/A/C/F offsets recalled | `Fire.build_file/1` | vectors for T/A/C/F in `test/erp_vectors` style |
| KD-H09-02 | SDN list | fixture list of synthetic entities, scores are Jaro-Winkler bps, not Treasury scoring | `Vocab.sdn_fixture/0` | loader for real SDN csv |
| KD-H09-03 | state sales tax | fixture state rates, single rate per state, no local jurisdictions or sourcing rules | `Vocab.state_rates_bps/0` | rate-table plane (`Smalt.Rates`) lookup |
| KD-H09-04 | IRIS | JSON shape is a twin, not the IRS A2A XML schema; no TCC auth | `Fire.iris_submit/1` | A2A XML vectors |
| KD-H09-05 | TIN match, NetSuite/QBO routes | already served by `Smalt.TaxSanctions.Http` (`/tax/tin-match`) and `Smalt.Erp.Router`; not duplicated | existing modules | none |

## See Also
`docs/b4b/KD-P3-TAX.md`, `docs/b4b/KD-P5-ERP.md`
