# SOURCE-CHECK-P1-P3

Standing: PARTIAL

Checked 2026-11-14 against public docs. Test files not edited.

| Fixture | Row | Source | Result | Before -> After |
|---|---|---|---|---|
| taxsanctions vectors.json | IRS TIN match codes 0-8, match set 0/6/7/8 | Pub 2108A text (search result) | MATCH | unchanged |
| taxsanctions vectors.json | Pub 1220 B-record positions, length 750, record types | irs.gov/pub/irs-pdf/p1220.pdf (Rev. 5-2026), pdftotext | MATCH (1, 2-5, 6, 7-10, 11, 12-20, 21-40, 41-44, 55-66; type of TIN 1=EIN, 2=SSN/ITIN/ATIN) | unchanged |
| taxsanctions vectors.json | VIES check-vat-number keys | live POST ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number | requestDate is ISO datetime, not date | `2026-11-14` -> `2026-11-14T22:45:10.815Z` |
| taxsanctions vectors.json | VIES optional keys | same live response | extra real keys: requestIdentifier, traderName/Street/PostalCode/City/CompanyType (+ *Match); absent values are `---` | unchanged (optional list is a subset) |
| taxsanctions vectors.json | OFAC SDN.CSV 12 columns | live treasury.gov/ofac/downloads/sdn.csv | nulls are bare `-0- ` (trailing space), not quoted `"-0-"`; SDN_Type etc. unquoted | sample quoted `"-0-"` -> bare `-0- ` (real row 36) |
| treasury lithic/asa_response.json | ASA response | docs.lithic.com ASA guide | `result` is the only required field (APPROVED, ...); fixture lacked it | `{token,avs_result}` -> `{token,result:"APPROVED",avs_result}` |
| treasury lithic/asa_response_decline.json | ASA decline | same | no `DECLINE` result and no `reason` field; INSUFFICIENT_FUNDS is itself a `result` value | NOT EDITED: test asserts `result=="DECLINE"` and `reason=="INSUFFICIENT_FUNDS"`. Test change needed: assert `result == "INSUFFICIENT_FUNDS"`, then fixture -> `{token,result:"INSUFFICIENT_FUNDS"}` |
| treasury lithic/asa_request.json | ASA request keys | same (guide defers to API reference) | PARTIAL: guide nests `card{token,...}`, `amounts{...}`, `merchant`, `pos`, `avs`; fixture is flat (`card_token`, `amount`, `currency`, `status`, `created`). Exact schema not retrievable | UNVERIFIED; test requires the flat keys |
| treasury plaid/auth_get_* | /auth/get shape | plaid.com/docs/api/products/auth (summary only) | accounts, numbers(ach/eft/international/bacs), item, request_id, `wire_routing` in ach consistent; field-level detail not retrieved | UNVERIFIED (shape consistent) |
| treasury iso20022/pacs008.xml | element names | iso20022.org 403 | unreachable | UNVERIFIED |
| treasury iso20022/camt053.xml | element names | iso20022.org 403 | unreachable | UNVERIFIED |
