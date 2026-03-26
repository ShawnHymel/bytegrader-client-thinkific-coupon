package main

import (
	"fmt"
	"log"
	"net/http"
)

var (
	config *Config
	bg     *bgClient
)

func main() {
	var err error
	config, err = loadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	bg = newBGClient(config.BytegraderURL, config.BytegraderAPIKey)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/portal", portalHandler)

	addr := fmt.Sprintf(":%s", config.ClientPort)
	log.Printf("starting server on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
