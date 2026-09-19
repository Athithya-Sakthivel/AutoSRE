package queue

import (
	"sort"

	"go.opentelemetry.io/otel/propagation"
)

// MessageCarrier implements propagation.TextMapCarrier for Valkey Stream
// message fields.
type MessageCarrier map[string]string

var _ propagation.TextMapCarrier = MessageCarrier{}

func (c MessageCarrier) Get(key string) string {
	return c[key]
}

func (c MessageCarrier) Set(key, value string) {
	c[key] = value
}

func (c MessageCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for key := range c {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func NewMessageCarrier() MessageCarrier {
	return make(MessageCarrier, 2)
}

const (
	// TraceParentKey is the Valkey Stream field used for W3C traceparent.
	// It MUST match the W3C standard header name exactly for the propagator to work.
	TraceParentKey = "traceparent"

	// TraceStateKey is the Valkey Stream field used for W3C tracestate.
	// It MUST match the W3C standard header name exactly for the propagator to work.
	TraceStateKey = "tracestate"

	// PayloadKey is the Valkey Stream field containing the message payload.
	PayloadKey = "payload"
)
