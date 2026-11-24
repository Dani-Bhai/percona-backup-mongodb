package storage_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/percona/percona-backup-mongodb/pbm/compress"
	"github.com/percona/percona-backup-mongodb/pbm/storage"
	"github.com/percona/percona-backup-mongodb/pbm/storage/fs"
)

func TestUploadWithRateLimit(t *testing.T) {
	const (
		size    = 256 * 1024
		rateBps = 512 * 1024
		burst   = 64 * 1024
	)

	data := bytes.Repeat([]byte{0x5a}, size)

	stg, err := fs.New(&fs.Config{Path: t.TempDir()})
	if err != nil {
		t.Fatalf("create fs storage: %v", err)
	}

	limiter := rate.NewLimiter(rate.Limit(rateBps), burst)

	start := time.Now()
	_, err = storage.UploadWithOpts(
		context.Background(),
		bytes.NewBuffer(data),
		stg,
		compress.CompressionTypeNone,
		nil,
		"backup/test-file",
		-1,
		nil,
		nil,
		storage.WithRateLimit(limiter),
	)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	// The limiter starts with a full burst, so only size-burst bytes are paced.
	minElapsed := time.Duration(float64(size-burst)/rateBps*float64(time.Second)) / 2
	if elapsed < minElapsed {
		t.Errorf("upload is not rate limited: took %v, want at least %v", elapsed, minElapsed)
	}
	if elapsed > 10*time.Second {
		t.Errorf("upload took too long: %v", elapsed)
	}

	rc, err := stg.SourceReader("backup/test-file")
	if err != nil {
		t.Fatalf("open uploaded file: %v", err)
	}
	defer rc.Close()

	got, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("read uploaded file: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Errorf("uploaded data differs from the source: got %d bytes, want %d", len(got), len(data))
	}
}

func TestUploadWithRateLimitCancel(t *testing.T) {
	stg, err := fs.New(&fs.Config{Path: t.TempDir()})
	if err != nil {
		t.Fatalf("create fs storage: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	limiter := rate.NewLimiter(rate.Limit(1024), 1024) // 1 KiB/s

	errCh := make(chan error, 1)
	go func() {
		_, err := storage.UploadWithOpts(
			ctx,
			bytes.NewBuffer(make([]byte, 64*1024)),
			stg,
			compress.CompressionTypeNone,
			nil,
			"backup/test-file",
			-1,
			nil,
			nil,
			storage.WithRateLimit(limiter),
		)
		errCh <- err
	}()

	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case err := <-errCh:
		if !errors.Is(err, storage.ErrCancelled) && !errors.Is(err, context.Canceled) {
			t.Fatalf("upload error = %v, want %v or %v", err, storage.ErrCancelled, context.Canceled)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("upload did not stop after context cancellation")
	}
}
