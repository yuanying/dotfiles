package main

// devbox-proxyd: the whole public proxy in one process.
//
// docs/adr/0005 replaced Traefik, a Python verifier, two Cloudflare scripts and
// a certificate issuer with this. docs/adr/0008 keeps the shell interface the
// old one had -- start, stop, restart, reload, status -- and puts process
// management in the wrapper, so what is here is `serve`, `status` and `check`
// and nothing else. Everything the wrapper needs to know is a file.

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/caddyserver/certmagic"
)

const (
	// cookieTTL is how long a session lasts before GitHub is consulted again.
	cookieTTL = 7 * 24 * time.Hour
	// shutdownGrace is how long in-flight requests have to finish.
	shutdownGrace = 10 * time.Second
)

func main() {
	log.SetFlags(log.Ldate | log.Ltime)
	log.SetPrefix("devbox-proxyd: ")

	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(os.Args[2:])
	case "status":
		err = status(os.Args[2:])
	case "check":
		err = check(os.Args[2:])
	case "-h", "--help", "help":
		usage()
		return
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "devbox-proxyd: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `usage: devbox-proxyd {serve|status|check} [options]

  serve    bind the ports and publish what the declaration file declares
  status   what is running, when certificates expire, what renewal did last
  check    validate the declaration file and stop

Options are shared: --config is the declaration file, --state the directory
holding the signing key, the GitHub credentials and the certificates.
`)
}

// paths are the two locations every subcommand needs.
type paths struct {
	config string
	state  string
}

func (p *paths) bind(fs *flag.FlagSet) {
	fs.StringVar(&p.config, "config", os.Getenv("DEVBOX_PROXY_CONFIG"), "declaration file")
	fs.StringVar(&p.state, "state", defaultState(), "state directory")
}

func defaultState() string {
	if s := os.Getenv("DEVBOX_PROXY_STATE"); s != "" {
		return s
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".devbox-proxy"
	}
	return filepath.Join(home, ".config", "devbox-proxy")
}

func (p *paths) load() (*Config, error) {
	if p.config == "" {
		return nil, errors.New("no declaration file given; pass --config")
	}
	return Load(p.config)
}

func (p *paths) sessionKey() string  { return filepath.Join(p.state, "session.key") }
func (p *paths) credentials() string { return filepath.Join(p.state, "github.yaml") }
func (p *paths) certs() string       { return filepath.Join(p.state, "certs") }
func (p *paths) renewals() string    { return filepath.Join(p.state, "renewal.json") }
func (p *paths) pidFile() string     { return filepath.Join(p.state, "run", "devbox-proxyd.pid") }

func check(args []string) error {
	var p paths
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	p.bind(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := p.load()
	if err != nil {
		return err
	}
	fmt.Printf("%s: %d service(s) on %s\n", p.config, len(cfg.Services), cfg.Zone)
	for _, s := range cfg.Services {
		fmt.Printf("  %s.%s -> 127.0.0.1:%d (auth: %s)\n", s.Name, cfg.Zone, s.Port, s.Auth)
	}
	return nil
}

func status(args []string) error {
	var p paths
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	p.bind(fs)
	onlyWarnings := fs.Bool("warnings", false, "print only what is wrong, and nothing when nothing is")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := p.load()
	if err != nil {
		return err
	}
	reports := collectReports(cfg, p.certs(), &RenewalLog{path: p.renewals()})
	now := time.Now()

	if *onlyWarnings {
		for _, w := range warnings(reports, now) {
			fmt.Println(w)
		}
		return nil
	}

	pid, running := readPID(p.pidFile())
	fmt.Print(formatReport(reports, now, running, pid))
	return nil
}

func serve(args []string) error {
	var p paths
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	p.bind(fs)
	httpPort := fs.Int("http-port", 80, "port for ACME challenges and the redirect to HTTPS")
	httpsPort := fs.Int("https-port", 443, "port for everything else")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := p.load()
	if err != nil {
		return err
	}

	key, err := LoadOrCreateKey(p.sessionKey())
	if err != nil {
		return fmt.Errorf("signing key: %w", err)
	}
	signer := NewSigner(key)

	github, err := githubClient(&p, cfg)
	if err != nil {
		return err
	}

	router := NewRouter(signer, github, cfg.AuthHost(), cookieTTL)
	router.Set(cfg)

	certs := NewCertManager(p.state, router.Config, acmeDirectory())
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	if err := certs.Manage(ctx, cfg.Hostnames()); err != nil {
		// Not fatal: on-demand issuance still covers every declared name, and
		// a devbox with no uplink has to come up anyway (docs/adr/0006).
		log.Printf("could not register names for renewal: %v", err)
	}

	httpsServer := &http.Server{
		Addr:      ":" + strconv.Itoa(*httpsPort),
		Handler:   router,
		TLSConfig: certs.TLSConfig(),
	}
	httpServer := &http.Server{
		Addr:    ":" + strconv.Itoa(*httpPort),
		Handler: certs.ChallengeHandler(http.HandlerFunc(redirectToHTTPS)),
	}

	if err := writePID(p.pidFile()); err != nil {
		return err
	}
	defer os.Remove(p.pidFile())

	errs := make(chan error, 2)
	go func() {
		log.Printf("listening on :%d for ACME challenges and redirects", *httpPort)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- fmt.Errorf("port %d: %w", *httpPort, err)
		}
	}()
	go func() {
		log.Printf("publishing %s on :%d", strings.Join(cfg.Hostnames(), ", "), *httpsPort)
		if err := httpsServer.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- fmt.Errorf("port %d: %w", *httpsPort, err)
		}
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)

	for {
		select {
		case err := <-errs:
			return err
		case sig := <-signals:
			if sig != syscall.SIGHUP {
				log.Printf("stopping on %s", sig)
				shutdown(httpServer, httpsServer)
				return nil
			}
			reload(ctx, &p, router, certs)
		}
	}
}

// reload puts a new declaration into force without the process going away.
// docs/adr/0008: a file that does not validate changes nothing.
func reload(ctx context.Context, p *paths, router *Router, certs *CertManager) {
	next, err := p.load()
	if err != nil {
		log.Printf("reload refused, carrying on with what is running: %v", err)
		return
	}
	if current := router.Config(); current != nil && current.Zone != next.Zone {
		// The auth host, every certificate and every route would change at
		// once. That is a restart, not a reload.
		log.Printf("reload refused: the zone changed from %s to %s; restart instead", current.Zone, next.Zone)
		return
	}

	router.Set(next)
	if err := certs.Manage(ctx, next.Hostnames()); err != nil {
		log.Printf("reloaded, but could not register names for renewal: %v", err)
	}
	log.Printf("reloaded: %s", strings.Join(next.Hostnames(), ", "))
}

func shutdown(servers ...*http.Server) {
	ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	for _, s := range servers {
		if err := s.Shutdown(ctx); err != nil {
			log.Printf("shutting down %s: %v", s.Addr, err)
		}
	}
}

// githubClient is only needed when something asks for a login. A devbox
// publishing nothing but `auth: none` services should not need credentials it
// will never use.
func githubClient(p *paths, cfg *Config) (*GitHub, error) {
	needed := false
	for _, s := range cfg.Services {
		if s.Auth == AuthRequired {
			needed = true
			break
		}
	}

	creds, err := LoadGitHubCredentials(p.credentials())
	if err != nil {
		if !needed && errors.Is(err, os.ErrNotExist) {
			log.Printf("no GitHub credentials at %s, and nothing needs a login", p.credentials())
			return NewGitHub("", ""), nil
		}
		return nil, fmt.Errorf("GitHub credentials: %w", err)
	}
	return NewGitHub(creds.ClientID, creds.ClientSecret), nil
}

func acmeDirectory() string {
	if d := os.Getenv("DEVBOX_PROXY_ACME_DIRECTORY"); d != "" {
		return d
	}
	return certmagic.LetsEncryptProductionCA
}

func redirectToHTTPS(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "https://"+normaliseHost(r.Host)+r.URL.RequestURI(), http.StatusMovedPermanently)
}

func writePID(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644)
}

// readPID reports the pid in the file and whether that process is alive.
func readPID(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return pid, false
	}
	// Signal 0 asks the kernel whether it could be delivered.
	return pid, proc.Signal(syscall.Signal(0)) == nil
}
