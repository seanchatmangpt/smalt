# KD-109 close witness — typed appconfig feature flags on the wire (lane K7, 2026-10-9... 2026-10-21)

**Standing:** PASS
Context: solo

The typed flag engine (lib/smalt/data_plane/appconfig_features.ex, wave-6 lane
w6ax) had ZERO callers — the /kv wire still passed flag content through
opaquely. Lane K7 wired it: put /kv/:key in lib/smalt/egress/AppConfigRoutes.ex
now routes `.appconfig.featureflag/{name}` keys through
AppConfigFeatures.put_flag/4 (typed validation), marked `# KD-COVERS: KD-109`;
invalid flag bodies get the engine's typed 400 InvalidFeatureFlag refusal
instead of a silent opaque store.

Live wire over the TLS twin (9444, bearer + x-ms-version), App Config record
shape {"value": "<flag json string>", "contentType": ff+json}:

    put-flag:201    PUT /kv/.appconfig.featureflag%2Fk7flag — normalized flag row
                    (conditions normalized, etag minted, ff content type kept)
    get-flag:200    GET → typed record back, value is canonical flag JSON
    put-bad:400     {"code":"InvalidFeatureFlag","message":"value must be valid feature-flag JSON"}

Falsifier (feature-flag get/set roundtrip with typed shape + typed refusal)
passes. KD-109 is FLIP-ELIGIBLE.