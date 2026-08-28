package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

var version = "1.1.0"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", homeHandler)
	http.HandleFunc("/health", healthHandler)

	log.Printf("Server starting on port %s (version %s)", port, version)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	fmt.Fprintf(w, `<!DOCTYPE html>
<html>
<body style="font-family:sans-serif;max-width:600px;margin:60px auto;text-align:center">
  <h1>Hello from Go + Docker CI/CD PoC</h1>
  <p><strong>Version:</strong> %s</p>
  <p><strong>Host:</strong> %s</p>
  <p>Push to <code>main</code> → GitHub Actions builds &amp; redeploys automatically.</p>
</body>
</html>`, version, hostname)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","version":"%s"}`, version)
}
