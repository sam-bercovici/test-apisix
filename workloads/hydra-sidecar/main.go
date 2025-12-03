// Package main Hydra Sidecar API
//
// Sidecar service for Ory Hydra that provides token hook functionality,
// client creation with secret hashing, and bulk client sync.
//
//	@title			Hydra Sidecar API
//	@version		1.0
//	@description	Sidecar service for Ory Hydra that provides token hook functionality, client creation with secret hashing, and bulk client sync.
//
//	@contact.name	API Support
//
//	@license.name	Apache 2.0
//	@license.url	http://www.apache.org/licenses/LICENSE-2.0.html
//
//	@host			localhost:8080
//	@BasePath		/
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// Config holds the sidecar configuration
type Config struct {
	Port            string
	DatabaseURL     string
	HydraAdminURL   string
	HasherAlgorithm string
}

func loadConfig() Config {
	cfg := Config{
		Port:            getEnv("PORT", "8080"),
		DatabaseURL:     getEnv("DATABASE_URL", ""),
		HydraAdminURL:   getEnv("HYDRA_ADMIN_URL", "http://localhost:4445"),
		HasherAlgorithm: getEnv("HASHER_ALGORITHM", "pbkdf2"),
	}

	if cfg.DatabaseURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	return cfg
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func main() {
	cfg := loadConfig()

	// Initialize database store
	store, err := NewStore(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer store.Close()

	// Get network ID at startup (single-tenant: one network)
	nid, err := store.GetDefaultNetworkID(context.Background())
	if err != nil {
		log.Printf("Warning: Could not get network ID: %v (will be set on first sync)", err)
	}

	// Create server with dependencies
	server := &Server{
		store:           store,
		hydraAdminURL:   cfg.HydraAdminURL,
		hasherAlgorithm: cfg.HasherAlgorithm,
		networkID:       nid,
		httpClient:      &http.Client{Timeout: 30 * time.Second},
	}

	// Register handlers
	mux := http.NewServeMux()
	mux.HandleFunc("/token-hook", server.handleTokenHook)
	mux.HandleFunc("/admin/clients", server.handleCreateClient)
	mux.HandleFunc("/admin/clients/", server.handleClientByID)       // GET/DELETE /admin/clients/{id}
	mux.HandleFunc("/admin/clients/rotate/", server.handleRotateClient) // POST /admin/clients/rotate/{id}
	mux.HandleFunc("/sync/clients", server.handleSyncClients)
	mux.HandleFunc("/health", server.handleHealth)
	mux.HandleFunc("/ready", server.handleReady)

	// Create HTTP server
	httpServer := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Start server in goroutine
	go func() {
		log.Printf("Hydra sidecar starting on port %s", cfg.Port)
		log.Printf("  Hasher algorithm: %s", cfg.HasherAlgorithm)
		log.Printf("  Hydra Admin URL: %s", cfg.HydraAdminURL)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start server: %v", err)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}
