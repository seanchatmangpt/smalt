# T-14 — Azure Service Health: availability statuses, events, chaos-coupled incidents

- window: v26.10.28 · maps-to: Topaz v1.14 "Azure Service Health — Resource Health statuses · Service Health events · chaos-injectable incidents" · verdict-at-open: **GAP**
- size: **M** · depends-on: T-12 (chaos flags are the incident source)

## current state (evidence)

No `Microsoft.ResourceHealth` provider (verified — absent from the
13-provider route set). Nearest internal surface is the substrate's own
adaptive health probes (egress readiness/liveness), which are not an ARM
surface (map row).

## scope

1. `Microsoft.ResourceHealth/availabilityStatuses` — `listByResource` +
   `get` per resource id, `list` at RG/subscription scopes: `Available`
   by default, derived from plane/liveness state.
2. `Microsoft.ResourceHealth/events` — service-health event rows
   (Active/Resolved lifecycle) at subscription scope.
3. Chaos coupling: the T-12 injector flags (and a new
   `:resource_health_unavailable` marker) flip the affected resource's
   availability to `Unavailable` with the real reason codes
   (`CustomerInitiated`, platform-event classes), and mint/resolve a
   matching service-health event — the incident is observable, not just
   injected.

## non-goals

- Azure Status page/rss feeds; email/SMS action wiring.

## Definition of Done — the Azure developer's view

Your monitoring dashboard queries resource health the way it does in
Azure: `az rest --uri <resourceId>/providers/Microsoft.ResourceHealth/
availabilityStatuses/current?api-version=...` returns `Available` for your
running substrate resources. You flip a documented chaos flag (or trigger
an AMQP injector from T-12) and — without restarting anything — the same
query returns `Unavailable` with the real reason/summary structure, a
service-health `events` row appears as Active for the affected scope, and
your alerting code path (the one that parses these shapes in production)
fires. Clearing the flag resolves the event and restores `Available`,
each transition timestamped.

## receipts required

available→unavailable→available transition receipt (query-observable,
poll-based, zero-sleep compliant); events lifecycle receipt; scope-variant
receipt (resource vs RG vs subscription listing).
