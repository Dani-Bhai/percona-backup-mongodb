package backup

import (
	"testing"

	"golang.org/x/time/rate"

	"github.com/percona/percona-backup-mongodb/pbm/config"
	"github.com/percona/percona-backup-mongodb/pbm/storage"
)

func TestGetRateLimitMBs(t *testing.T) {
	cfg := func(mbps int) *config.Config {
		return &config.Config{Backup: &config.BackupConf{RateLimitMBs: mbps}}
	}

	tests := []struct {
		name string
		b    *Backup
		want int
	}{
		{name: "no config", b: &Backup{}, want: 0},
		{name: "no backup section", b: &Backup{config: &config.Config{}}, want: 0},
		{name: "config value", b: &Backup{config: cfg(100)}, want: 100},
		{name: "command value overrides config", b: &Backup{config: cfg(100), rateLimitMBs: 50}, want: 50},
		{name: "zero command falls back to config", b: &Backup{config: cfg(100)}, want: 100},
		{name: "negative config means no limit", b: &Backup{config: cfg(-1)}, want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.b.getRateLimitMBs(); got != tt.want {
				t.Errorf("getRateLimitMBs() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestRateLimiter(t *testing.T) {
	b := &Backup{}
	if lim := b.rateLimiter(); lim != nil {
		t.Fatalf("rateLimiter() = %v, want nil", lim)
	}

	b.SetRateLimitMBs(100)

	lim := b.rateLimiter()
	if lim == nil {
		t.Fatal("rateLimiter() = nil, want non-nil")
	}
	if got, want := lim.Limit(), rate.Limit(100*storage.MiB); got != want {
		t.Errorf("limit = %v, want %v", got, want)
	}
	if got := lim.Burst(); got != rateLimitBurst {
		t.Errorf("burst = %d, want %d", got, rateLimitBurst)
	}
}
