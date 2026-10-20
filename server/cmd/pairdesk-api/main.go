package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"pairdesk/server/internal/app"
	"time"
)

func main() {
	path := os.Getenv("PAIRDESK_DATA")
	if path == "" {
		path = "./data/pairdesk.json"
	}
	openCtx, cancelOpen := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancelOpen()
	st, e := app.OpenStoreFromEnv(openCtx, path)
	if e != nil {
		log.Fatal(e)
	}
	defer st.Close()
	api := app.New(st)
	go api.RunPushWorker(context.Background())
	addr := os.Getenv("PAIRDESK_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	srv := &http.Server{Addr: addr, Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second}
	log.Printf("Pairdesk API listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}
