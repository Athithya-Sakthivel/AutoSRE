package processor

import "fmt"

// OrderEvent represents the domain payload for e-commerce order ingestion.
type OrderEvent struct {
	EventID  string `json:"event_id"`
	UserID   string `json:"user_id"`
	SKU      string `json:"sku"`
	Quantity int    `json:"quantity"`
}

// Validate enforces domain-level invariants.
func (e OrderEvent) Validate() error {
	if e.EventID == "" {
		return fmt.Errorf("missing event_id")
	}
	if e.UserID == "" {
		return fmt.Errorf("missing user_id")
	}
	if e.SKU == "" {
		return fmt.Errorf("missing sku")
	}
	if e.Quantity <= 0 {
		return fmt.Errorf("invalid quantity: %d", e.Quantity)
	}

	return nil
}

// PermanentError indicates a domain-level failure that should not be retried.
type PermanentError struct {
	msg string
}

func (e *PermanentError) Error() string {
	return e.msg
}

// NewPermanentError creates a new PermanentError with formatted text.
func NewPermanentError(format string, args ...interface{}) *PermanentError {
	return &PermanentError{
		msg: fmt.Sprintf(format, args...),
	}
}
