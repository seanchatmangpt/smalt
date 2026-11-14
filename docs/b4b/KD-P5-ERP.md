# KD-P5-ERP

Standing: UNVERIFIED

Published-doc vectors for ERP journal planes, in `test/erp_vectors/`.

| id | surface | vector | divergence | close condition |
|---|---|---|---|---|
| KD-P5-01 | QBO JournalEntry/Account | `qbo_journal_entry.json`, `qbo_account.json` | twin absent | `lib/smalt/erp` serves QBO routes |
| KD-P5-02 | Xero ManualJournals | `xero_manual_journal.json` | twin absent | twin accepts signed LineAmount |
| KD-P5-03 | NetSuite journalentry | `netsuite_journalentry.json` | twin absent | twin accepts debit/credit items |

Vectors are authored from published docs, not captured from live services.

## See Also
`test/erp_vectors/erp_vectors_test.exs`
