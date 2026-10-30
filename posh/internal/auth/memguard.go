package auth

import (
	"crypto/subtle"
	"errors"
	"sync"
)

// LockedBuffer holds sensitive cryptographic key bytes in protected, zeroizable memory.
type LockedBuffer struct {
	mu        sync.Mutex
	data      []byte
	destroyed bool
}

// NewLockedBuffer allocates a buffer and copies sensitive bytes into it.
// The caller should wipe their original copy if necessary.
func NewLockedBuffer(secret []byte) (*LockedBuffer, error) {
	if len(secret) == 0 {
		return nil, errors.New("cannot lock empty secret buffer")
	}

	buf := make([]byte, len(secret))
	copy(buf, secret)

	lb := &LockedBuffer{
		data: buf,
	}
	return lb, nil
}

// Read executes a function with access to the locked bytes.
func (lb *LockedBuffer) Read(fn func(b []byte) error) error {
	lb.mu.Lock()
	defer lb.mu.Unlock()

	if lb.destroyed {
		return errors.New("attempted to read destroyed locked buffer")
	}
	return fn(lb.data)
}

// Destroy securely overwrites the memory buffer with zeros and marks it dead.
func (lb *LockedBuffer) Destroy() {
	lb.mu.Lock()
	defer lb.mu.Unlock()

	if lb.destroyed {
		return
	}

	// Constant-time zeroization of key material
	Memzero(lb.data)
	lb.destroyed = true
	lb.data = nil
}

// IsDestroyed returns true if the buffer has been wiped.
func (lb *LockedBuffer) IsDestroyed() bool {
	lb.mu.Lock()
	defer lb.mu.Unlock()
	return lb.destroyed
}

// Memzero securely wipes a byte slice with zeros.
func Memzero(b []byte) {
	for i := range b {
		b[i] = 0
	}
	// Subtle check to ensure compiler does not optimize away the zeroing loop
	if len(b) > 0 {
		_ = subtle.ConstantTimeByteEq(b[0], 0)
	}
}

// ConstantTimeCompare compares two byte slices in constant time.
func ConstantTimeCompare(a, b []byte) bool {
	return subtle.ConstantTimeCompare(a, b) == 1
}
