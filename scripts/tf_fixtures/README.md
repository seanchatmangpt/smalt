# scripts/tf_fixtures — terraform fixture (v26.10.19 re-author)

Fresh home of the terraform fixture after test/terraform_fixture was
deleted at 64f6099. Re-authored (not byte-copied) from the deleted
fixture's contract; resource names + provider pins are preserved because
they are load-bearing (22-native data-plane verify, tf ladder exit codes).

Golden path (unchanged semantics):

    bash scripts/bootstrap_env.sh
    just substrate-up
    cd scripts/tf_fixtures
    terraform init / plan / apply / plan -detailed-exitcode / destroy

`scripts/smalt-tf` supplies the environment (ARM_ENDPOINT,
ARM_METADATA_HOSTNAME, credentials); the .tf files stay standard so smalt
is exercised against unmodified Terraform input.
