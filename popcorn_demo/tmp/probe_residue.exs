# W7-B residue-seeding probe (scratch, tmp/): seed a soft-deleted popcorn-cert
# (create + DELETE, NO purge) — the state a crashed previous run leaves — then
# run PopcornDemo.LiveCerts.run/0. preflight_clean/1 must purge the residue so
# create wins and the walk lands certs=OK(popcorn-cert:purge).
base = "http://127.0.0.1:8443"
sts = "http://127.0.0.1:9443"

{:ok, %{status: 200, body: tok_body}} =
  PopcornDemo.Transport.Httpc.request(%{
    method: "POST",
    url: sts <> "/default/oauth2/v2.0/token",
    headers: [{"content-type", "application/x-www-form-urlencoded"}],
    body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
  })

token = Jason.decode!(tok_body)["access_token"]
IO.puts("SEED token: " <> (if token, do: "ok", else: "MISSING"))

{:ok, %{status: cs}} =
  PopcornDemo.Transport.Httpc.request(%{
    method: "POST",
    url: base <> "/certificates/popcorn-cert/create?api-version=7.4",
    headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
    body: ~s({"policy":{"x509_props":{"subject":"CN=seed-residue","validity_months":12}}})
  })

IO.puts("SEED create: " <> Integer.to_string(cs))

{:ok, %{status: ds}} =
  PopcornDemo.Transport.Httpc.request(%{
    method: "DELETE",
    url: base <> "/certificates/popcorn-cert?api-version=7.4",
    headers: [{"authorization", "Bearer " <> token}]
  })

IO.puts("SEED delete (residue left soft-deleted, NO purge): " <> Integer.to_string(ds))

IO.puts("PROBE run/0 over seeded residue:")
IO.inspect(PopcornDemo.LiveCerts.run(), label: "PROBE")
