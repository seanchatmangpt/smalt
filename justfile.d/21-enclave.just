# 21-enclave — e1 enclave-loop bench lane (scripts/tf_enclave_loop.sh)

# Provision a terraform enclave, drive data plane + console + residue; emits e1-enclave-loop.jsonl. Loud-skip exit 3 when terraform/prereqs missing.
enclave-loop:
    @bash scripts/tf_enclave_loop.sh
