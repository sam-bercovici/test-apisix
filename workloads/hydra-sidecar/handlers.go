package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gofrs/uuid"
	"github.com/ory/hydra/v2/client"
	"github.com/ory/x/sqlxx"
)

// Server holds the HTTP server dependencies
type Server struct {
	store           *Store
	hydraAdminURL   string
	hasherAlgorithm string
	networkID       uuid.UUID
	httpClient      *http.Client
}

// swagger:route POST /token-hook hooks tokenHook
//
// Token hook for JWT claim injection.
//
// Called by Hydra during token issuance to inject client metadata into JWT claims.
// Rejects expired clients with 403 Forbidden.
//
//	Consumes:
//	- application/json
//
//	Produces:
//	- application/json
//
//	Responses:
//	  200: tokenHookResponseWrapper
//	  400: errorResponse
//	  403: tokenHookErrorResponseWrapper
//
func (s *Server) handleTokenHook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req TokenHookRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("Error decoding request: %v", err)
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	clientID := req.Request.ClientID
	if clientID == "" {
		clientID = req.Session.ClientID
	}

	log.Printf("Token hook called for client_id: %s", clientID)

	// Fetch client info (metadata + expiration) from Hydra Admin API
	clientInfo, err := s.fetchClientInfo(clientID)
	if err != nil {
		log.Printf("Failed to fetch client info for %s: %v, using fallback", clientID, err)
		clientInfo = nil
	}

	// Check if client has expired
	if clientInfo != nil && clientInfo.ClientSecretExpiresAt > 0 {
		if time.Now().Unix() > clientInfo.ClientSecretExpiresAt {
			log.Printf("Client %s has expired (expired_at: %d)", clientID, clientInfo.ClientSecretExpiresAt)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			json.NewEncoder(w).Encode(TokenHookErrorResponse{
				Error:            "access_denied",
				ErrorDescription: "client has expired",
			})
			return
		}
	}

	// Build custom claims from client metadata - copy all metadata items
	customClaims := make(map[string]interface{})

	if clientInfo != nil && clientInfo.Metadata != nil {
		// Copy all metadata items to JWT claims
		for key, value := range clientInfo.Metadata {
			customClaims[key] = value
		}
		log.Printf("Injecting %d metadata fields for client: %s", len(clientInfo.Metadata), clientID)
	}

	// Build response
	resp := TokenHookResponse{}
	resp.Session.AccessToken = customClaims

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		log.Printf("Error encoding response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
}

// fetchClientInfo fetches client metadata and expiration from Hydra Admin API
func (s *Server) fetchClientInfo(clientID string) (*ClientInfo, error) {
	url := fmt.Sprintf("%s/admin/clients/%s", s.hydraAdminURL, clientID)
	resp, err := s.httpClient.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("failed to fetch client: %d", resp.StatusCode)
	}

	var c ClientInfo
	if err := json.NewDecoder(resp.Body).Decode(&c); err != nil {
		return nil, err
	}

	return &c, nil
}

// swagger:route POST /admin/clients clients createClient
//
// Create OAuth2 client.
//
// Proxies client creation to Hydra Admin API and returns the response enriched with client_secret_hash.
//
// Response fields:
//   - client_secret: Plaintext secret (show to user, NEVER store)
//   - client_secret_hash: Hash of secret (store this for sync)
//
//	Consumes:
//	- application/json
//
//	Produces:
//	- application/json
//
//	Responses:
//	  201: clientDataResponse
//	  400: errorResponse
//	  502: errorResponse
//
func (s *Server) handleCreateClient(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Read the request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("Error reading request body: %v", err)
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	// Forward to Hydra Admin API
	hydraURL := fmt.Sprintf("%s/admin/clients", s.hydraAdminURL)
	hydraReq, err := http.NewRequest(http.MethodPost, hydraURL, bytes.NewReader(body))
	if err != nil {
		log.Printf("Error creating Hydra request: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	hydraReq.Header.Set("Content-Type", "application/json")

	hydraResp, err := s.httpClient.Do(hydraReq)
	if err != nil {
		log.Printf("Error calling Hydra: %v", err)
		http.Error(w, "Failed to create client in Hydra", http.StatusBadGateway)
		return
	}
	defer hydraResp.Body.Close()

	// Read Hydra response
	hydraBody, err := io.ReadAll(hydraResp.Body)
	if err != nil {
		log.Printf("Error reading Hydra response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// If Hydra returned an error, pass it through
	if hydraResp.StatusCode >= 400 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(hydraResp.StatusCode)
		w.Write(hydraBody)
		return
	}

	// Parse Hydra response into ClientData (which embeds client.Client)
	var clientData ClientData
	if err := json.Unmarshal(hydraBody, &clientData); err != nil {
		log.Printf("Error parsing Hydra response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// Get the hashed secret from the database
	hashedSecret, err := s.store.GetHashedSecret(r.Context(), clientData.ID, s.networkID)
	if err != nil {
		log.Printf("Warning: Could not retrieve hashed secret for %s: %v", clientData.ID, err)
		// Still return the response, just without the hash
	}

	// Add the hash to the response
	clientData.ClientSecretHash = hashedSecret

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(hydraResp.StatusCode)
	if err := json.NewEncoder(w).Encode(clientData); err != nil {
		log.Printf("Error encoding response: %v", err)
	}
}

// swagger:route GET /admin/clients/{client_id} clients getClient
//
// Get OAuth2 client.
//
// Returns client details from Hydra (passthrough). Note: client_secret is never returned by Hydra.
//
//	Produces:
//	- application/json
//
//	Responses:
//	  200: clientDataResponse
//	  404: errorResponse
//	  502: errorResponse
//
func (s *Server) handleClientByID(w http.ResponseWriter, r *http.Request) {
	// Extract client_id from path: /admin/clients/{client_id}
	clientID := strings.TrimPrefix(r.URL.Path, "/admin/clients/")
	if clientID == "" {
		http.Error(w, "Bad request: missing client_id", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		s.getClient(w, r, clientID)
	case http.MethodDelete:
		s.deleteClient(w, r, clientID)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

// getClient retrieves a client from Hydra
func (s *Server) getClient(w http.ResponseWriter, _ *http.Request, clientID string) {
	log.Printf("Getting client: %s", clientID)

	hydraURL := fmt.Sprintf("%s/admin/clients/%s", s.hydraAdminURL, clientID)
	hydraResp, err := s.httpClient.Get(hydraURL)
	if err != nil {
		log.Printf("Error calling Hydra: %v", err)
		http.Error(w, "Failed to get client from Hydra", http.StatusBadGateway)
		return
	}
	defer hydraResp.Body.Close()

	body, _ := io.ReadAll(hydraResp.Body)

	if hydraResp.StatusCode == http.StatusNotFound {
		http.Error(w, "Client not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(hydraResp.StatusCode)
	w.Write(body)
}

// swagger:route DELETE /admin/clients/{client_id} clients deleteClient
//
// Delete OAuth2 client.
//
// Deletes a client from Hydra by client_id.
//
//	Responses:
//	  204: noContent
//	  404: errorResponse
//	  502: errorResponse
//
func (s *Server) deleteClient(w http.ResponseWriter, _ *http.Request, clientID string) {
	log.Printf("Deleting client: %s", clientID)

	// Forward delete to Hydra Admin API
	hydraURL := fmt.Sprintf("%s/admin/clients/%s", s.hydraAdminURL, clientID)
	hydraReq, err := http.NewRequest(http.MethodDelete, hydraURL, nil)
	if err != nil {
		log.Printf("Error creating Hydra request: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	hydraResp, err := s.httpClient.Do(hydraReq)
	if err != nil {
		log.Printf("Error calling Hydra: %v", err)
		http.Error(w, "Failed to delete client in Hydra", http.StatusBadGateway)
		return
	}
	defer hydraResp.Body.Close()

	// Pass through Hydra's response status
	if hydraResp.StatusCode == http.StatusNoContent || hydraResp.StatusCode == http.StatusOK {
		log.Printf("Client %s deleted successfully", clientID)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if hydraResp.StatusCode == http.StatusNotFound {
		http.Error(w, "Client not found", http.StatusNotFound)
		return
	}

	// Pass through other errors
	body, _ := io.ReadAll(hydraResp.Body)
	log.Printf("Hydra returned error %d: %s", hydraResp.StatusCode, string(body))
	w.WriteHeader(hydraResp.StatusCode)
	w.Write(body)
}

// swagger:route POST /admin/clients/rotate/{client_id} clients rotateClient
//
// Rotate client secret.
//
// Rotates the client secret and returns the new secret along with its hash.
// Optionally accepts client_secret_expires_at to set expiration for the new secret.
//
// Response fields:
//   - client_secret: New plaintext secret (show to user, NEVER store)
//   - client_secret_hash: Hash of new secret (update stored value)
//
//	Consumes:
//	- application/json
//
//	Produces:
//	- application/json
//
//	Responses:
//	  200: clientDataResponse
//	  400: errorResponse
//	  404: errorResponse
//	  502: errorResponse
//
func (s *Server) handleRotateClient(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract client_id from path: /admin/clients/rotate/{client_id}
	clientID := strings.TrimPrefix(r.URL.Path, "/admin/clients/rotate/")
	if clientID == "" {
		http.Error(w, "Bad request: missing client_id", http.StatusBadRequest)
		return
	}

	// Parse optional request body for client_secret_expires_at
	var rotateReq RotateClientRequest
	if r.Body != nil && r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&rotateReq); err != nil {
			log.Printf("Error decoding rotate request: %v", err)
			http.Error(w, "Bad request: invalid JSON", http.StatusBadRequest)
			return
		}
	}

	log.Printf("Rotating secret for client: %s", clientID)

	// Call Hydra Admin API to rotate secret
	hydraURL := fmt.Sprintf("%s/admin/clients/%s/rotate", s.hydraAdminURL, clientID)
	hydraReq, err := http.NewRequest(http.MethodPost, hydraURL, nil)
	if err != nil {
		log.Printf("Error creating Hydra request: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	hydraReq.Header.Set("Content-Type", "application/json")

	hydraResp, err := s.httpClient.Do(hydraReq)
	if err != nil {
		log.Printf("Error calling Hydra: %v", err)
		http.Error(w, "Failed to rotate client secret in Hydra", http.StatusBadGateway)
		return
	}
	defer hydraResp.Body.Close()

	// Read Hydra response
	hydraBody, err := io.ReadAll(hydraResp.Body)
	if err != nil {
		log.Printf("Error reading Hydra response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// If Hydra returned an error, pass it through
	if hydraResp.StatusCode >= 400 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(hydraResp.StatusCode)
		w.Write(hydraBody)
		return
	}

	// Parse Hydra response into ClientData (which embeds client.Client)
	var clientData ClientData
	if err := json.Unmarshal(hydraBody, &clientData); err != nil {
		log.Printf("Error parsing Hydra response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// If client_secret_expires_at was provided, update the client via PATCH
	if rotateReq.ClientSecretExpiresAt > 0 {
		if err := s.updateClientExpiration(clientID, rotateReq.ClientSecretExpiresAt); err != nil {
			log.Printf("Warning: Failed to update client expiration: %v", err)
			// Continue anyway - the secret was rotated successfully
		} else {
			clientData.SecretExpiresAt = int(rotateReq.ClientSecretExpiresAt)
			log.Printf("Updated client %s expiration to %d", clientID, rotateReq.ClientSecretExpiresAt)
		}
	}

	// Get the hashed secret from the database
	hashedSecret, err := s.store.GetHashedSecret(r.Context(), clientData.ID, s.networkID)
	if err != nil {
		log.Printf("Warning: Could not retrieve hashed secret for %s: %v", clientData.ID, err)
		// Still return the response, just without the hash
	}

	// Add the hash to the response
	clientData.ClientSecretHash = hashedSecret

	log.Printf("Client %s secret rotated successfully", clientID)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(hydraResp.StatusCode)
	if err := json.NewEncoder(w).Encode(clientData); err != nil {
		log.Printf("Error encoding response: %v", err)
	}
}

// updateClientExpiration updates the client_secret_expires_at via PATCH to Hydra
func (s *Server) updateClientExpiration(clientID string, expiresAt int64) error {
	patchBody := map[string]interface{}{
		"client_secret_expires_at": expiresAt,
	}
	bodyBytes, err := json.Marshal(patchBody)
	if err != nil {
		return fmt.Errorf("failed to marshal patch body: %w", err)
	}

	hydraURL := fmt.Sprintf("%s/admin/clients/%s", s.hydraAdminURL, clientID)
	req, err := http.NewRequest(http.MethodPatch, hydraURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return fmt.Errorf("failed to create PATCH request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to call Hydra: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("Hydra returned %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// swagger:route POST /sync/clients clients syncClients
//
// Bulk sync OAuth2 clients.
//
// Performs full reconciliation of clients - creates new, updates existing, deletes removed.
//
// Request field behavior:
//   - client_secret: Must contain the stored hash (from client_secret_hash in creation response)
//   - client_secret_hash: Ignored (use client_secret for the hash)
//
//	Consumes:
//	- application/json
//
//	Produces:
//	- application/json
//
//	Responses:
//	  200: syncResultResponse
//	  400: errorResponse
//	  500: errorResponse
//
func (s *Server) handleSyncClients(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req SyncClientsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("Error decoding sync request: %v", err)
		http.Error(w, "Bad request: invalid JSON", http.StatusBadRequest)
		return
	}

	if len(req.Clients) == 0 {
		http.Error(w, "Bad request: clients array is empty", http.StatusBadRequest)
		return
	}

	// Validate all hashes match configured algorithm
	for _, c := range req.Clients {
		// Warn if client_secret is populated in sync request.
		// In API responses, client_secret contains the plaintext (shown once at creation).
		// For sync, callers should use client_secret_hash which contains the stored hash.
		// We ignore client_secret here to prevent accidental plaintext submission.
		if c.Secret != "" {
			log.Printf("Warning: client %s has client_secret populated in sync request, ignoring (use client_secret_hash)", c.ID)
		}
		// Validate the hash from client_secret_hash field
		if err := s.validateHash(c.ClientSecretHash); err != nil {
			http.Error(w, fmt.Sprintf("Bad request: client %s: %v", c.ID, err), http.StatusBadRequest)
			return
		}
	}

	// Ensure we have a network ID
	nid := s.networkID
	if nid == uuid.Nil {
		// Try to get it again
		var err error
		nid, err = s.store.GetDefaultNetworkID(r.Context())
		if err != nil {
			log.Printf("Error getting network ID: %v", err)
			http.Error(w, "Internal error: no network ID available", http.StatusInternalServerError)
			return
		}
		s.networkID = nid
	}

	// Convert ClientData to client.Client structs with defaults
	hydraClients := make([]client.Client, len(req.Clients))
	for i, c := range req.Clients {
		// Start with the embedded client.Client
		hydraClients[i] = c.Client
		hydraClients[i].NID = nid

		// Copy hash from ClientSecretHash to Secret for database storage.
		// Note: Hydra's Secret field stores the HASHED value in the database,
		// even though the JSON field name is "client_secret". When Hydra creates
		// a client via API, it hashes the plaintext before storing. Since we're
		// bypassing the API and writing directly to the DB via SyncClients(),
		// we must provide the pre-hashed value here.
		hydraClients[i].Secret = c.ClientSecretHash

		// Set default grant types if not provided
		if len(hydraClients[i].GrantTypes) == 0 {
			hydraClients[i].GrantTypes = sqlxx.StringSliceJSONFormat{"client_credentials"}
		}

		// Set default token endpoint auth method if not provided
		if hydraClients[i].TokenEndpointAuthMethod == "" {
			hydraClients[i].TokenEndpointAuthMethod = "client_secret_basic"
		}
	}

	// Perform sync
	result, err := s.store.SyncClients(r.Context(), hydraClients, nid)
	if err != nil {
		log.Printf("Error syncing clients: %v", err)
		http.Error(w, "Internal error during sync", http.StatusInternalServerError)
		return
	}

	log.Printf("Sync completed: created=%d, updated=%d, deleted=%d, failed=%d",
		result.CreatedCount, result.UpdatedCount, result.DeletedCount, result.FailedCount)

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(result); err != nil {
		log.Printf("Error encoding sync result: %v", err)
	}
}

// validateHash checks if the hash format matches the configured algorithm
func (s *Server) validateHash(hash string) error {
	if hash == "" {
		return fmt.Errorf("client_secret (hash) is required")
	}

	switch s.hasherAlgorithm {
	case "pbkdf2":
		if !isPbkdf2Hash(hash) {
			return fmt.Errorf("expected PBKDF2 hash format ($pbkdf2-sha...), got: %s", detectHashFormat(hash))
		}
	case "bcrypt":
		if !isBcryptHash(hash) {
			return fmt.Errorf("expected BCrypt hash format ($2a$...), got: %s", detectHashFormat(hash))
		}
	default:
		return fmt.Errorf("unknown hasher algorithm: %s", s.hasherAlgorithm)
	}

	return nil
}

// isPbkdf2Hash checks if the hash is in PBKDF2 format
func isPbkdf2Hash(hash string) bool {
	return strings.HasPrefix(hash, "$pbkdf2-sha")
}

// isBcryptHash checks if the hash is in BCrypt format
func isBcryptHash(hash string) bool {
	return strings.HasPrefix(hash, "$2a$") || strings.HasPrefix(hash, "$2b$") || strings.HasPrefix(hash, "$2y$")
}

// detectHashFormat returns a description of the hash format for error messages
func detectHashFormat(hash string) string {
	if isPbkdf2Hash(hash) {
		return "PBKDF2"
	}
	if isBcryptHash(hash) {
		return "BCrypt"
	}
	if len(hash) > 20 {
		return fmt.Sprintf("unknown (starts with: %s...)", hash[:20])
	}
	return fmt.Sprintf("unknown (%s)", hash)
}


// swagger:route GET /health health healthCheck
//
// Health check (liveness probe).
//
// Returns OK if the server is running.
//
//	Produces:
//	- text/plain
//
//	Responses:
//	  200: healthResponse
//
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// swagger:route GET /ready health readinessCheck
//
// Readiness check (readiness probe).
//
// Returns OK if the database connection is healthy.
//
//	Produces:
//	- text/plain
//
//	Responses:
//	  200: healthResponse
//	  503: errorResponse
//
func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := s.store.Ping(ctx); err != nil {
		log.Printf("Readiness check failed: %v", err)
		http.Error(w, "Database not ready", http.StatusServiceUnavailable)
		return
	}

	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}
