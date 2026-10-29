# v26.10.19 clean-room reset: the legacy suite (303 files) was deleted in this
# commit; the residual internal tier is re-authored fresh under test/internal/
# (see docs/jira/v26.10.19/WORK_ORDERS.md WO-10). Zero legacy test text was
# copied forward — history lives in git only.
ExUnit.start()

# BK-PATW (v26.10.22): the distributed-runner-only courts are excluded by
# default when this runner is NOT distributed, so a batched
# `mix test test/integration` loud-skips them instead of invalidating them
# (peer.start_link needs a distributed node). With a distributed runner they
# run in-batch. To force-run on a non-distributed node: --include <tag>.
if node() == :nonode@nohost do
  ExUnit.configure(exclude: [:peer_two_node_court, :swarm_court])
end
