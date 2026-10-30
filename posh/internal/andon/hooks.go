package andon

// OnTransition is the counter hook invoked by Machine.Apply on every
// receipted signal transition (holds included). It is nil by default —
// the metrics registry in cmd/posh wires it; when nil, Apply is a
// no-op beyond the state machine itself.
var OnTransition func(gate string, from, to State)
