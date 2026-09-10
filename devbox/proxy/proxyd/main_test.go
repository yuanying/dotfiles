package main

import (
	"strings"
	"testing"
)

// `check` is the one answer to "what is published" (docs/adr/0009), so where
// each name is forwarded to has to be in it, host and all (docs/adr/0011).
func TestCheckLineShowsWhereTheServiceIsForwarded(t *testing.T) {
	for _, tc := range []struct {
		name string
		svc  Service
		want string
	}{
		{
			name: "the loopback",
			svc:  Service{Name: "llama", Host: "127.0.0.1", Port: 8081, Auth: AuthNone},
			want: "llama.z.dev -> 127.0.0.1:8081 (auth: none)",
		},
		{
			name: "a container",
			svc:  Service{Name: "sd-webui", Host: "sd-webui", Port: 7860, Auth: AuthRequired, Viewers: Viewers{Logins: []string{"yuanying"}}},
			want: "sd-webui.z.dev -> sd-webui:7860 (auth: required) -- 1 viewer(s)",
		},
		{
			name: "an IPv6 address",
			svc:  Service{Name: "v6", Host: "fd00:5d::2", Port: 80, Auth: AuthNone},
			want: "v6.z.dev -> [fd00:5d::2]:80 (auth: none)",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := checkLine(tc.svc, "z.dev")
			if strings.TrimSpace(got) != tc.want {
				t.Errorf("checkLine = %q, want %q", got, tc.want)
			}
		})
	}
}
