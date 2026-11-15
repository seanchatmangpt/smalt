# KD-H08 Treasury and Rates Gap Register

Standing: PARTIAL

Lane H08. Implementation under `lib/smalt/h08/`, tests under `test/h08/`. Not compiled or run
in-lane (compile hook blocked); the coordinator owns `mix test`.

## Surfaces served

| Surface | Route | Handler |
|---|---|---|
| pain.001.001.09 build | POST /treasury/h08/iso20022/pain001/build | lib/smalt/h08/treasury_router.ex |
| pain.001 intake, pain.002-style report | POST /treasury/h08/iso20022/pain001 | lib/smalt/h08/pain001.ex |
| camt.053 | GET /treasury/h08/iso20022/camt053/:account_id | lib/smalt/h08/statements.ex |
| camt.054 | GET /treasury/h08/iso20022/camt054/:account_id?since_seq= | lib/smalt/h08/statements.ex |
| Lithic ASA with funds logic | POST /treasury/lithic/asa (+ /clearing, /void) | lib/smalt/h08/asa.ex |
| Plaid transactions | POST /treasury/plaid/transactions/get | lib/smalt/h08/treasury_router.ex |
| NACHA build/validate | POST /treasury/h08/nacha/file, /validate | lib/smalt/h08/nacha.ex |
| NY Fed SOFR/EFFR last/search | GET /rates/api/rates/{secured/sofr,unsecured/effr}/... | lib/smalt/h08/rates_router.ex |
| SOFR curve, compounded average | GET /rates/h08/sofr/curve, /average | lib/smalt/h08/sofr_curve.ex |
| ABS loan tape | POST/GET /rates/h08/abs/tape | lib/smalt/h08/abs_tape.ex |

Mount: `forward("/", to: ...)` lines added before the final `match _` in
`lib/smalt/treasury/router.ex` and `lib/smalt/rates/http.ex`.

## Known divergences

| ID | Surface | Divergence | Evidence | Close condition |
|---|---|---|---|---|
| KD-H08-01 | /webhooks/asa (pre-existing) | Rule-only decision, no balance check, `result` DECLINED/APPROVED | lib/smalt/treasury/router.ex | Repoint consumers to /lithic/asa, retire route |
| KD-H08-02 | /plaid/auth/get, /accounts/balance/get (pre-existing) | Balances emitted as decimal strings; real Plaid emits numbers; error shape is {type,message} | lib/smalt/treasury/router.ex | Rewrite to Plaid error/number shape |
| KD-H08-03 | pain.001 | Single PmtInf, USD only, no BIC/IBAN agents, no pain.002 XML (JSON report) | pain001.ex | Add PmtInf multiplicity and pain.002 XML |
| KD-H08-04 | NACHA | No addenda (type 7), IAT, or prenote codes; one effective-date check only | nacha.ex | Add addenda and codes 23/28/33/38 |
| KD-H08-05 | SOFR curve | NY Fed publishes no curve; knots are the offset vocabulary on the latest print | vocab.ex curve_knots | Source forward curve from a real market feed |
| KD-H08-06 | SOFR series | Four-print fixed series; average accrues last print one day | lib/smalt/rates/ny_fed.ex | Longer series, business-day calendar |
| KD-H08-07 | State | ETS-only (`:smalt_treasury`), lost on restart; pain.001 debit+credit not atomic across accounts | ledger.ex | Persist ledger via Smalt.Store |
| KD-H08-08 | ASA | No velocity limits, AVS, or 3DS | asa.ex | Add rule dimensions |

## See Also

lib/smalt/h08/vocab.ex, /Users/sac/fnox/docs/v26.11.14/required-apis/h08.json
