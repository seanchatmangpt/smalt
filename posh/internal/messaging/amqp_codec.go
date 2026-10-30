package messaging

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// AMQPFrameHeader represents an 8-byte AMQP 1.0 frame header.
type AMQPFrameHeader struct {
	Size    uint32
	DOFF    uint8  // Data offset in 4-byte words (typically 2 for standard frames)
	Type    uint8  // 0 = AMQP frame, 1 = SASL frame
	Channel uint16 // 16-bit channel number
}

// ParseAMQPFrameHeader decodes an 8-byte AMQP 1.0 frame header.
func ParseAMQPFrameHeader(r io.Reader) (*AMQPFrameHeader, error) {
	var buf [8]byte
	if _, err := io.ReadFull(r, buf[:]); err != nil {
		return nil, err
	}

	size := binary.BigEndian.Uint32(buf[0:4])
	if size < 8 {
		return nil, fmt.Errorf("invalid AMQP frame size: %d (min 8)", size)
	}

	doff := buf[4]
	frameType := buf[5]
	channel := binary.BigEndian.Uint16(buf[6:8])

	return &AMQPFrameHeader{
		Size:    size,
		DOFF:    doff,
		Type:    frameType,
		Channel: channel,
	}, nil
}

// EncodeAMQPFrameHeader encodes an 8-byte header into dst.
func EncodeAMQPFrameHeader(h *AMQPFrameHeader, dst []byte) error {
	if len(dst) < 8 {
		return errors.New("dst buffer too small for 8-byte AMQP frame header")
	}
	binary.BigEndian.PutUint32(dst[0:4], h.Size)
	dst[4] = h.DOFF
	dst[5] = h.Type
	binary.BigEndian.PutUint16(dst[6:8], h.Channel)
	return nil
}

// ChannelMultiplexer dispatches AMQP frames across 16-bit channels without cross-process locks.
type ChannelMultiplexer struct {
	handlers [65536]func(h *AMQPFrameHeader, payload []byte) error
}

// NewChannelMultiplexer constructs a multiplexer.
func NewChannelMultiplexer() *ChannelMultiplexer {
	return &ChannelMultiplexer{}
}

// RegisterChannel binds a handler to a specific 16-bit channel.
func (cm *ChannelMultiplexer) RegisterChannel(channel uint16, fn func(h *AMQPFrameHeader, payload []byte) error) {
	cm.handlers[channel] = fn
}

// Dispatch routes a frame to the registered channel handler.
func (cm *ChannelMultiplexer) Dispatch(h *AMQPFrameHeader, payload []byte) error {
	fn := cm.handlers[h.Channel]
	if fn == nil {
		return fmt.Errorf("no handler registered for AMQP channel %d", h.Channel)
	}
	return fn(h, payload)
}
