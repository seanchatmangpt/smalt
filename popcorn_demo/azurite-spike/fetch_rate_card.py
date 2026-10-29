#!/usr/bin/env python3
"""Fetch the Azure Retail Prices API rate card for smalt's exercised meters.

Public API, no auth. Writes azurite-spike/rate-card.json containing the full
raw price records for five service families (eastus, USD) plus a curated
`rates` resolution table mapping rate keys to exact raw records. Rerun to
refresh: python3 azurite-spike/fetch_rate_card.py
"""
import datetime
import json
import urllib.parse
import urllib.request

BASE = "https://prices.azure.com/api/retail/prices"

KEEP = ("serviceName", "productName", "skuName", "meterName", "unitOfMeasure")

QUERIES = [
    ("cosmos", "serviceName eq 'Azure Cosmos DB' and armRegionName eq 'eastus'"),
    ("storage",
     "serviceName eq 'Storage' and armRegionName eq 'eastus' and "
     "productName eq 'General Block Blob v2 Hierarchical Namespace'"),
    ("servicebus", "serviceName eq 'Service Bus' and armRegionName eq 'eastus'"),
    ("keyvault", "serviceName eq 'Key Vault' and armRegionName eq 'eastus'"),
    ("eventhubs", "serviceName eq 'Event Hubs' and armRegionName eq 'eastus' "
                  "and productName eq 'Event Hubs'"),
]

# rate key -> (family, exact-match fields against raw records)
RESOLVE = [
    ("cosmos_provisioned_rus", ("cosmos", {
        "skuName": "RUs", "meterName": "100 RU/s",
        "unitOfMeasure": "1/Hour"})),
    ("cosmos_burst_1m_rus", ("cosmos", {
        "skuName": "RUs", "meterName": "1M RUs", "unitOfMeasure": "1M"})),
    ("blob_read_ops", ("storage", {
        "skuName": "Hot LRS", "meterName": "Hot LRS Read Operations",
        "unitOfMeasure": "10K"})),
    ("blob_write_ops", ("storage", {
        "skuName": "Hot LRS", "meterName": "Hot LRS Write Operations",
        "unitOfMeasure": "10K"})),
    ("blob_stored_gb", ("storage", {
        "skuName": "Hot LRS", "meterName": "Hot LRS Data Stored",
        "unitOfMeasure": "1 GB/Month"})),
    ("sb_standard_base_unit", ("servicebus", {
        "skuName": "Standard", "meterName": "Standard Base Unit",
        "unitOfMeasure": "1/Hour"})),
    ("sb_standard_ops", ("servicebus", {
        "skuName": "Standard", "meterName": "Standard Messaging Operations",
        "unitOfMeasure": "1M"})),
    ("sb_premium_mu", ("servicebus", {
        "skuName": "Premium", "meterName": "Premium Messaging Unit",
        "unitOfMeasure": "1/Hour"})),
    ("kv_ops", ("keyvault", {
        "skuName": "Standard", "meterName": "Operations",
        "unitOfMeasure": "10K"})),
    ("eh_standard_tu", ("eventhubs", {
        "skuName": "Standard", "meterName": "Standard Throughput Unit",
        "unitOfMeasure": "1 Hour"})),
]


def fetch_all(fltr):
    """Fetch every page of a filtered Retail Prices query."""
    url = BASE + "?currencyCode=USD&" + urllib.parse.urlencode(
        {"$filter": fltr})
    items = []
    while url:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            page = json.load(resp)
        items.extend(page["Items"])
        url = page.get("NextPageLink")
    return items


def match(items, want):
    return [
        i for i in items
        if all(str(i.get(k)) == v for k, v in want.items())
    ]


def main():
    card = {
        "_meta": {
            "source": BASE,
            "currency": "USD",
            "region": "eastus",
            "fetched_at": datetime.datetime.now(datetime.timezone.utc)
            .isoformat(),
            "generator": "azurite-spike/fetch_rate_card.py",
        },
        "families": {},
    }
    for name, fltr in QUERIES:
        items = fetch_all(fltr)
        card["families"][name] = {
            "filter": fltr,
            "fetched_at": datetime.datetime.now(datetime.timezone.utc)
            .isoformat(),
            "count": len(items),
            "items": items,
        }
        print(f"{name}: {len(items)} raw records")

    resolved = {}
    for key, (fam, want) in RESOLVE:
        hits = match(card["families"][fam]["items"], want)
        if len(hits) != 1:
            print(f"WARN {key}: {len(hits)} matches for {want}")
        if hits:
            resolved[key] = hits[0]
    card["rates"] = resolved
    card["_meta"]["rate_count"] = len(resolved)

    path = "azurite-spike/rate-card.json"
    with open(path, "w") as f:
        json.dump(card, f, indent=2)
    print(f"wrote {path} with {len(resolved)} curated rates")
    for key, r in resolved.items():
        print(f"  {key}: {r['retailPrice']} USD / {r['unitOfMeasure']} "
              f"({r['meterName']}, sku={r['skuName']})")
    missing = [k for k, _ in RESOLVE if k not in resolved]
    if missing:
        raise SystemExit(f"MISSING RATES: {missing}")


if __name__ == "__main__":
    main()
