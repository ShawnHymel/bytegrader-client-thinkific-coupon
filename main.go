package main

import (
	"fmt"
	"log"
	"net/http"
)

var config *Config

func main() {
	var err error
	config, err = loadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)

	addr := fmt.Sprintf(":%s", config.ClientPort)
	log.Printf("starting server on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
