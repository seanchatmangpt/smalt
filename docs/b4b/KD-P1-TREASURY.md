# KD-P1-TREASURY

Standing: UNVERIFIED

Known-divergence register for Plane 1 (treasury) b4b wire twins. Vectors live in
`test/treasury_vectors/`; evidence receipts are produced when the coordinator runs the gate.

## Vector inventory

| id | surface | fixture | check |
|---|---|---|---|
| V1 | ISO 20022 pacs.008.001.08 | `iso20022/pacs008.xml` | mandatory-element xpath, UETR v4, BICFI |
| V2 | ISO 20022 camt.053.001.08 | `iso20022/camt053.xml` | element xpath, closing = opening + entry |
| V3 | Lithic ASA request | `lithic/asa_request.json` | required keys, integer cents |
| V4 | Lithic ASA response | `lithic/asa_response*.json` | token echo, avs_result, decline reason |
| V5 | Plaid /auth/get | `plaid/auth_get_*.json` | accounts/numbers/item/request_id, routing 9 digits |

## Divergence register

| KD | surface | divergence | evidence | close condition |
|---|---|---|---|---|
| KD-P1-01 | all | `lib/smalt/treasury` absent; module court loud-skips | `[SKIP]` line in test output | module lands and test replays V1-V5 against it |
| KD-P1-02 | ISO 20022 | shape checked by xpath, not full XSD validation (no vendored XSD) | test source | vendor pacs.008/camt.053 XSD, use `:xmerl_xsd` |
| KD-P1-03 | Lithic/Plaid | vectors hand-transcribed from published docs, not live captures | fixtures | capture from sandbox in a cloud-authorised lane |

## Gate

Coordinator runs: `mix test test/treasury_vectors/treasury_vectors_test.exs` in `/Users/sac/smalt`.

## See Also

`test/treasury_vectors/treasury_vectors_test.exs`
