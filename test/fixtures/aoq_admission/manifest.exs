# AoQ admission conformance corpus manifest (lane 9, v26.11.6).
# Each entry: {file, expected verdict class}.
#   :admit  -> {:ok, %{admitted: true, ...}}
#   atom    -> the {:refused, code, _} code
[
  {"conforming_frame.ttl", :admit},
  {"violating_crc.ttl", :smalt_shacl_violation},
  {"violating_oov.ttl", :smalt_shacl_violation}
]
