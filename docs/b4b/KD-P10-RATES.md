# KD-P10-RATES

Standing: UNVERIFIED

Wire-twin vectors for NY Fed refrates, FRED observations, EDGAR submissions.

## Vectors

| id | surface | fixture | published-doc facts pinned |
|---|---|---|---|
| V1 | NY Fed `/api/rates/secured/sofr/last/1.json` | `nyfed_refrates_sofr_latest.json` | `refRates[]`, percentile ordering |
| V2 | FRED `series/observations` | `fred_observations_dgs10.json` | values are strings, `"."` = missing |
| V3 | SEC `data.sec.gov/submissions/CIK##########.json` | `edgar_submissions_cik.json` | 10-digit CIK, parallel `filings.recent` arrays |

## Divergence register

| KD | surface | divergence | close condition |
|---|---|---|---|
| KD-P10-01 | all | `lib/smalt/rates` absent at authoring; twin not driven | module lands, test stops printing `[SKIP]` |
| KD-P10-02 | all | fixtures hand-authored from docs, not captured live | probe receipt per vector |
| KD-P10-03 | EDGAR | live API requires a declared User-Agent; twin behavior unpinned | twin test for missing UA |

## See Also

`test/rates_vectors/rates_vectors_test.exs`
