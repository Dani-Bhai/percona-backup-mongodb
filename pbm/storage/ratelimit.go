package storage

import (
	"context"
	"io"

	"golang.org/x/time/rate"
)

// UploadOption configures an upload started with UploadWithOpts.
type UploadOption func(*uploadOpts)

type uploadOpts struct {
	rateLimiter *rate.Limiter
}

// WithRateLimit limits the bandwidth of an upload to the given limiter's rate.
// The limiter is applied to the stream sent to the storage backend (after
// compression), so it caps the bytes written to the backup storage.
// A nil limiter means no limit.
func WithRateLimit(limiter *rate.Limiter) UploadOption {
	return func(o *uploadOpts) {
		o.rateLimiter = limiter
	}
}

// rateLimitedReader paces reads from r according to limiter. It throttles the
// backup stream on its way to the storage backend.
type rateLimitedReader struct {
	ctx     context.Context
	limiter *rate.Limiter
	r       io.Reader
}

func newRateLimitedReader(ctx context.Context, r io.Reader, limiter *rate.Limiter) *rateLimitedReader {
	return &rateLimitedReader{ctx: ctx, limiter: limiter, r: r}
}

func (r *rateLimitedReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	if n > 0 {
		if werr := waitN(r.ctx, r.limiter, n); werr != nil {
			if ctxErr := r.ctx.Err(); ctxErr != nil {
				return n, ctxErr
			}
			return n, werr
		}
	}

	return n, err
}

// waitN waits until limiter permits n bytes. Reads larger than the limiter's
// burst are split into burst-sized waits, as rate.Limiter.WaitN rejects n
// greater than the burst size.
func waitN(ctx context.Context, limiter *rate.Limiter, n int) error {
	burst := limiter.Burst()
	for n > 0 {
		chunk := min(n, burst)
		if err := limiter.WaitN(ctx, chunk); err != nil {
			return err
		}
		n -= chunk
	}

	return nil
}
