package main

import (
	"strings"
	"testing"
	"time"
)

func TestHostLevel(t *testing.T) {
	for _, tc := range []struct {
		name   string
		report hostReport
		want   level
	}{
		{
			name:   "plenty of time left",
			report: hostReport{Host: "a.z.dev", Expiry: epoch.Add(67 * 24 * time.Hour)},
			want:   levelOK,
		},
		{
			name:   "no certificate yet",
			report: hostReport{Host: "a.z.dev"},
			want:   levelPending,
		},
		{
			name: "close to expiry and the last renewal failed",
			report: hostReport{
				Host:   "a.z.dev",
				Expiry: epoch.Add(8 * 24 * time.Hour),
				Last:   &Renewal{Host: "a.z.dev", At: epoch.Add(-time.Hour), OK: false, Problem: "acme: unauthorized"},
			},
			want: levelWarning,
		},
		{
			// Inside the renewal window but nothing has been attempted: the
			// loop should have tried by now.
			name:   "close to expiry with nothing attempted",
			report: hostReport{Host: "a.z.dev", Expiry: epoch.Add(8 * 24 * time.Hour)},
			want:   levelWarning,
		},
		{
			// Renewed successfully but the file on disk is the old one -- the
			// next handshake picks up the new one. Not a problem.
			name: "close to expiry but the last renewal worked",
			report: hostReport{
				Host:   "a.z.dev",
				Expiry: epoch.Add(20 * 24 * time.Hour),
				Last:   &Renewal{Host: "a.z.dev", At: epoch.Add(-time.Hour), OK: true},
			},
			want: levelOK,
		},
		{
			// Close enough that a success on record is no longer reassuring.
			name: "days from expiry",
			report: hostReport{
				Host:   "a.z.dev",
				Expiry: epoch.Add(3 * 24 * time.Hour),
				Last:   &Renewal{Host: "a.z.dev", At: epoch.Add(-time.Hour), OK: true},
			},
			want: levelWarning,
		},
		{
			name:   "already expired",
			report: hostReport{Host: "a.z.dev", Expiry: epoch.Add(-time.Hour)},
			want:   levelError,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.report.level(epoch); got != tc.want {
				t.Errorf("level = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestFormatReportSaysWhatIsWrong(t *testing.T) {
	reports := []hostReport{
		{Host: "auth.z.dev", Expiry: epoch.Add(67 * 24 * time.Hour)},
		{
			Host:   "sd-webui.z.dev",
			Expiry: epoch.Add(8 * 24 * time.Hour),
			Last: &Renewal{
				Host: "sd-webui.z.dev", At: epoch.Add(-30 * time.Hour),
				OK: false, Problem: "acme: 403 urn:ietf:params:acme:error:unauthorized",
			},
		},
		{Host: "docs.z.dev"},
	}
	out := formatReport(reports, epoch, true, 1234)

	for _, want := range []string{
		"1234", // the pid, so it can be looked at
		"auth.z.dev",
		"67 days",
		"sd-webui.z.dev",
		"urn:ietf:params:acme:error:unauthorized", // the reason, in full
		"docs.z.dev",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the report does not mention %q:\n%s", want, out)
		}
	}
}

func TestFormatReportWhenStopped(t *testing.T) {
	// 0008: the certificate answers still have to come out when the process is
	// not running, because that is when they matter most.
	out := formatReport([]hostReport{
		{Host: "a.z.dev", Expiry: epoch.Add(67 * 24 * time.Hour)},
	}, epoch, false, 0)

	if !strings.Contains(out, "a.z.dev") || !strings.Contains(out, "67 days") {
		t.Errorf("a stopped proxy reported nothing useful:\n%s", out)
	}
	if !strings.Contains(strings.ToLower(out), "not running") {
		t.Errorf("the report does not say the proxy is stopped:\n%s", out)
	}
}

func TestWarningsAreOnlyTheProblems(t *testing.T) {
	reports := []hostReport{
		{Host: "fine.z.dev", Expiry: epoch.Add(67 * 24 * time.Hour)},
		{Host: "new.z.dev"},
		{
			Host:   "stuck.z.dev",
			Expiry: epoch.Add(8 * 24 * time.Hour),
			Last:   &Renewal{Host: "stuck.z.dev", At: epoch, OK: false, Problem: "boom"},
		},
	}
	warnings := warnings(reports, epoch)

	if len(warnings) != 1 {
		t.Fatalf("got %d warnings, want 1: %v", len(warnings), warnings)
	}
	if !strings.Contains(warnings[0], "stuck.z.dev") {
		t.Errorf("warning = %q", warnings[0])
	}
}

// A devbox that has just been built has no certificates and that is normal;
// entrypoint.sh must not print alarms on every first boot.
func TestNothingIssuedYetIsNotAWarning(t *testing.T) {
	reports := []hostReport{
		{Host: "a.z.dev"},
		{Host: "b.z.dev"},
	}
	if w := warnings(reports, epoch); len(w) != 0 {
		t.Errorf("a fresh devbox produced warnings: %v", w)
	}
}
