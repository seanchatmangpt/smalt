import pathlib
import subprocess
import os
env = dict(os.environ)
subprocess.run([
    "/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt", "-e",
    'Application.put_env(:smalt, :sts_signing_secret, "py-lane6-known-secret-0123456789abcdef");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    ''
    'Application.put_env(:smalt, :arm_port, 19443);'
    'Application.put_env(:smalt, :egress_port, 18443);'
    'Application.put_env(:smalt, :arm_tls_port, 19444);'
    'Application.put_env(:smalt, :mcp_port, 19545);'
    'Application.put_env(:smalt, :amqp_port, 25672);'
    'Application.put_env(:smalt, :event_hubs_port, 25673);'
    '{:ok, _} = Application.ensure_all_started(:smalt)'
], cwd=str(pathlib.Path(__file__).resolve().parents[2]), env=env)
