package storage

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"golang.org/x/time/rate"
)

func TestWaitNSplitsReadsLargerThanBurst(t *testing.T) {
	limiter := rate.NewLimiter(rate.Limit(1<<20), 1024)

	// A single read larger than the burst must be split into burst-sized
	// waits instead of failing with "exceeds limiter's burst".
	if err := waitN(context.Background(), limiter, 4096); err != nil {
		t.Fatalf("waitN() error = %v, want nil", err)
	}
}

func TestRateLimitedReader(t *testing.T) {
	data := bytes.Repeat([]byte{0x1}, 8*1024)
	limiter := rate.NewLimiter(rate.Limit(1<<20), 1024)

	r := newRateLimitedReader(context.Background(), bytes.NewReader(data), limiter)

	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("read %d bytes, want %d", len(got), len(data))
	}
}

func TestRateLimitedReaderCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	limiter := rate.NewLimiter(rate.Limit(1024), 1024)
	r := newRateLimitedReader(ctx, bytes.NewReader(make([]byte, 64*1024)), limiter)

	cancel()

	if _, err := io.ReadAll(r); !errors.Is(err, context.Canceled) {
		t.Fatalf("read error = %v, want %v", err, context.Canceled)
	}
}
