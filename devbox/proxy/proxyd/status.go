package main

// What `devbox-proxy status` prints.
//
// docs/adr/0002 listed "nothing warns about expiry" as the cost of a
// fifteen-year certificate. docs/adr/0006 renews automatically instead, which
// trades that for a different failure: renewal quietly not working, noticed
// about thirty days later by a browser. This file is the answer to that -- the
// question "when does this expire, and did the last attempt fail?" has to be
// answerable, including while the process is stopped.

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

type level int

const (
	levelOK level = iota
	levelPending
	levelWarning
	levelError
)

func (l level) String() string {
	switch l {
	case levelOK:
		return "ok"
	case levelPending:
		return "pending"
	case levelWarning:
		return "warning"
	default:
		return "error"
	}
}

const (
	// renewalWindow is roughly when certmagic starts trying: a third of a
	// ninety-day certificate. Inside it, no attempt on record means the loop
	// is not doing its job.
	renewalWindow = 30 * 24 * time.Hour
	// criticalWindow is close enough that a success on record is no longer
	// reassuring -- if it had worked, the file would say so.
	criticalWindow = 7 * 24 * time.Hour
)

type hostReport struct {
	Host   string
	Expiry time.Time // zero when no certificate has been issued
	Last   *Renewal
}

func (h hostReport) level(now time.Time) level {
	if h.Expiry.IsZero() {
		// A devbox that has just been built has none of these yet, and the
		// first visitor causes one to be issued. Normal, not a problem.
		return levelPending
	}
	left := h.Expiry.Sub(now)
	switch {
	case left <= 0:
		return levelError
	case left < criticalWindow:
		return levelWarning
	case left < renewalWindow:
		if h.Last == nil || !h.Last.OK {
			return levelWarning
		}
	}
	return levelOK
}

func (h hostReport) summary(now time.Time) string {
	if h.Expiry.IsZero() {
		return "no certificate yet"
	}
	left := h.Expiry.Sub(now)
	if left <= 0 {
		return fmt.Sprintf("expired %s", h.Expiry.Format("2006-01-02"))
	}
	return fmt.Sprintf("%d days left", int(left.Hours()/24))
}

// formatReport is the whole of `status`.
func formatReport(reports []hostReport, now time.Time, running bool, pid int) string {
	var b strings.Builder

	if running {
		fmt.Fprintf(&b, "devbox-proxy: running (pid %d)\n", pid)
	} else {
		b.WriteString("devbox-proxy: not running\n")
	}
	if len(reports) == 0 {
		b.WriteString("\nnothing is published\n")
		return b.String()
	}
	b.WriteString("\n")

	sorted := append([]hostReport(nil), reports...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Host < sorted[j].Host })

	width := 0
	for _, r := range sorted {
		if len(r.Host) > width {
			width = len(r.Host)
		}
	}

	for _, r := range sorted {
		lvl := r.level(now)
		fmt.Fprintf(&b, "%-*s  %-8s  %s\n", width, r.Host, lvl, r.summary(now))
		if r.Last == nil {
			continue
		}
		// The detail is only interesting when something is wrong, or when the
		// last thing that happened was a failure.
		if lvl == levelOK && r.Last.OK {
			continue
		}
		outcome := "succeeded"
		if !r.Last.OK {
			outcome = "failed"
		}
		fmt.Fprintf(&b, "%-*s    last attempt %s, %s\n", width, "", r.Last.At.Format("2006-01-02 15:04 MST"), outcome)
		if r.Last.Problem != "" {
			fmt.Fprintf(&b, "%-*s    %s\n", width, "", r.Last.Problem)
		}
	}
	return b.String()
}

// warnings is the short form entrypoint.sh prints at container start: only
// what is wrong, and nothing at all when nothing is.
func warnings(reports []hostReport, now time.Time) []string {
	var out []string
	for _, r := range reports {
		lvl := r.level(now)
		if lvl != levelWarning && lvl != levelError {
			continue
		}
		line := fmt.Sprintf("%s: %s", r.Host, r.summary(now))
		if r.Last != nil && !r.Last.OK {
			line += fmt.Sprintf(", last renewal failed (%s)", r.Last.Problem)
		} else if r.Last == nil {
			line += ", no renewal has been attempted"
		}
		out = append(out, line)
	}
	sort.Strings(out)
	return out
}

// collectReports gathers what status needs, entirely from disk.
func collectReports(cfg *Config, storagePath string, log *RenewalLog) []hostReport {
	recorded, err := log.All()
	if err != nil {
		// A note we cannot read is not a reason to refuse to say anything
		// about the certificates.
		recorded = map[string]Renewal{}
	}

	var out []hostReport
	for _, host := range cfg.Hostnames() {
		r := hostReport{Host: host}
		if expiry, err := CertificateExpiry(storagePath, host); err == nil {
			r.Expiry = expiry
		}
		if last, ok := recorded[host]; ok {
			r.Last = &last
		}
		out = append(out, r)
	}
	return out
}
