# KD-TREASURY

Standing: PARTIAL

| KD | Surface | Divergence | Close |
|---|---|---|---|
| KD-T1 | Column/MT objects | Subset of fields; no webhooks/idempotency keys | live probe |
| KD-T2 | Rails | Static limits ($1M); no participant directory | FedNow/RTP directory |
| KD-T3 | ASA | Wire response is result+token only; elapsed budget checked in-process | Lithic probe |
| KD-T4 | Plaid | access_token resolves directly to a seeded account | Plaid sandbox probe |
| KD-T5 | ISO 20022 | Regex XML parse, no XSD validation | xsd gate |
