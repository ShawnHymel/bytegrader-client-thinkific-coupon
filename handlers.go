package main

import (
	"embed"
	"encoding/json"
	"net/http"
)

//go:embed web/portal.html
var portalFS embed.FS

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func portalHandler(w http.ResponseWriter, r *http.Request) {
	data, err := portalFS.ReadFile("web/portal.html")
	if err != nil {
		http.Error(w, "portal unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}
