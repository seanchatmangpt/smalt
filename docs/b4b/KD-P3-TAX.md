# KD-P3-TAX

Standing: UNVERIFIED

Plane 3 (tax/sanctions) published-doc vectors. Recalled from published docs; no network fetch
this lane. Re-verify against sources before promoting.

| KD | surface | vector source | close condition |
|---|---|---|---|
| KD-P3-01 | IRS TIN Matching codes 0-8 | IRS Pub 2108A | twin returns each code; unknown code typed error |
| KD-P3-02 | 1099 B-record positions (len 750, TIN 12-20) | IRS Pub 1220 | twin parses/emits offsets |
| KD-P3-03 | VIES checkVatNumber shape | EC VIES service | twin response has required keys |
| KD-P3-04 | OFAC SDN csv 12 columns | Treasury SDN list spec | twin match returns SDN row shape |

Receipt: tests in `test/taxsanctions_vectors/`; the module-driving test prints `[SKIP]` while
`lib/smalt/taxsanctions` is absent (it was absent at authoring).

## See Also

`test/taxsanctions_vectors/vectors.json`
