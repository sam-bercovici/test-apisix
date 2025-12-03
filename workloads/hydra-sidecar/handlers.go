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
	hydrax "github.com/ory/hydra/v2/x"
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

// TokenHookRequest represents the incoming request from Hydra
type TokenHookRequest struct {
	Session struct {
		ClientID string `json:"client_id" example:"acme-service-1"`
	} `json:"session"`
	Request struct {
		ClientID string   `json:"client_id" example:"acme-service-1"`
		Scopes   []string `json:"granted_scopes" example:"read,write"`
	} `json:"request"`
}

// TokenHookResponse represents the response to Hydra
type TokenHookResponse struct {
	Session struct {
		AccessToken map[string]interface{} `json:"access_token"`
	} `json:"session"`
}

// HydraClientResponse represents the Hydra Admin API response for client creation
type HydraClientResponse struct {
	// OAuth2 client ID
	ClientID string `json:"client_id" example:"acme-service-1"`
	// Client secret (only returned on creation)
	ClientSecret string `json:"client_secret,omitempty" example:"secret123"`
	// Human-readable client name
	ClientName string `json:"client_name,omitempty" example:"Acme Service 1"`
	// Unix timestamp when client secret expires (0 = never)
	ClientSecretExpiresAt int64 `json:"client_secret_expires_at,omitempty" example:"1735689600"`
	// Access token lifespan for client_credentials grant
	ClientCredentialsGrantAccessTokenLifespan string `json:"client_credentials_grant_access_token_lifespan,omitempty" example:"1h"`
	// Client metadata
	Metadata map[string]interface{} `json:"metadata,omitempty"`
}

// EnhancedClientResponse adds the hashed secret to the Hydra response
type EnhancedClientResponse struct {
	HydraClientResponse
	ClientSecretHash string `json:"client_secret_hash,omitempty" example:"$pbkdf2-sha512$..."`
}

// SyncClientsRequest represents the bulk sync request
type SyncClientsRequest struct {
	Clients []SyncClient `json:"clients"`
}

// SyncClient represents a client in the sync request
type SyncClient struct {
	// Client ID (required)
	ClientID string `json:"client_id" example:"acme-service-1"`
	// Pre-hashed client secret (required)
	ClientSecret string `json:"client_secret" example:"$pbkdf2-sha512$..."`
	// Human-readable client name (optional)
	ClientName string `json:"client_name,omitempty" example:"Acme Service 1"`
	// OAuth2 grant types (optional, defaults to ["client_credentials"])
	GrantTypes []string `json:"grant_types,omitempty" example:"client_credentials"`
	// OAuth2 response types (optional)
	ResponseTypes []string `json:"response_types,omitempty" example:"token"`
	// Space-separated list of scopes (optional)
	Scope string `json:"scope,omitempty" example:"read write"`
	// Token endpoint auth method (optional, defaults to "client_secret_basic")
	TokenEndpointAuthMethod string `json:"token_endpoint_auth_method,omitempty" example:"client_secret_basic"`
	// Client metadata for JWT claims (optional)
	Metadata map[string]interface{} `json:"metadata,omitempty"`
	// Redirect URIs (optional)
	RedirectURIs []string `json:"redirect_uris,omitempty"`
	// Allowed audiences (optional)
	Audience []string `json:"audience,omitempty"`
	// Unix timestamp when client secret expires, 0 means never (optional)
	ClientSecretExpiresAt int64 `json:"client_secret_expires_at,omitempty" example:"1735689600"`
	// Access token lifespan for client_credentials grant, e.g. "1h", "30m" (optional)
	ClientCredentialsGrantAccessTokenLifespan string `json:"client_credentials_grant_access_token_lifespan,omitempty" example:"1h"`
}

// TokenHookErrorResponse represents an error response to Hydra token hook
type TokenHookErrorResponse struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// RotateClientRequest represents the optional request body for rotating a client secret
type RotateClientRequest struct {
	// Unix timestamp when the new client secret expires, 0 means never (optional)
	ClientSecretExpiresAt int64 `json:"client_secret_expires_at,omitempty" example:"1735689600"`
}


// handleTokenHook injects JWT claims from client metadata
//
//	@Summary		Token hook for JWT claim injection
//	@Description	Called by Hydra during token issuance to inject client metadata into JWT claims. Rejects expired clients.
//	@Tags			hooks
//	@Accept			json
//	@Produce		json
//	@Param			request	body		TokenHookRequest	true	"Token hook request from Hydra"
//	@Success		200		{object}	TokenHookResponse	"Token hook response with custom claims"
//	@Failure		400		{string}	string				"Bad request"
//	@Failure		403		{object}	TokenHookErrorResponse	"Client expired"
//	@Failure		405		{string}	string				"Method not allowed"
//	@Router			/token-hook [post]
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

// ClientInfo holds client metadata and expiration info from Hydra
type ClientInfo struct {
	Metadata              map[string]interface{} `json:"metadata"`
	ClientSecretExpiresAt int64                  `json:"client_secret_expires_at"`
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

// handleCreateClient proxies to Hydra and enriches response with hashed secret
//
//	@Summary		Create OAuth2 client
//	@Description	Proxies client creation to Hydra Admin API and returns the response enriched with client_secret_hash
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client	body		HydraClientResponse		true	"Client configuration"
//	@Success		200		{object}	EnhancedClientResponse	"Client created with secret hash"
//	@Success		201		{object}	EnhancedClientResponse	"Client created with secret hash"
//	@Failure		400		{string}	string					"Bad request"
//	@Failure		405		{string}	string					"Method not allowed"
//	@Failure		502		{string}	string					"Failed to create client in Hydra"
//	@Router			/admin/clients [post]
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

	// Parse Hydra response
	var hydraClient HydraClientResponse
	if err := json.Unmarshal(hydraBody, &hydraClient); err != nil {
		log.Printf("Error parsing Hydra response: %v", err)
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// Get the hashed secret from the database
	hashedSecret, err := s.store.GetHashedSecret(r.Context(), hydraClient.ClientID, s.networkID)
	if err != nil {
		log.Printf("Warning: Could not retrieve hashed secret for %s: %v", hydraClient.ClientID, err)
		// Still return the response, just without the hash
	}

	// Build enhanced response
	enhanced := EnhancedClientResponse{
		HydraClientResponse: hydraClient,
		ClientSecretHash:    hashedSecret,
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(hydraResp.StatusCode)
	if err := json.NewEncoder(w).Encode(enhanced); err != nil {
		log.Printf("Error encoding response: %v", err)
	}
}

// handleClientByID handles GET and DELETE for /admin/clients/{client_id}
//
//	@Summary		Get OAuth2 client
//	@Description	Retrieves a client from Hydra by client_id
//	@Tags			clients
//	@Produce		json
//	@Param			client_id	path		string				true	"Client ID"
//	@Success		200			{object}	HydraClientResponse	"Client details"
//	@Failure		400			{string}	string				"Bad request - missing client_id"
//	@Failure		404			{string}	string				"Client not found"
//	@Failure		502			{string}	string				"Failed to get client from Hydra"
//	@Router			/admin/clients/{client_id} [get]
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

// deleteClient deletes a client from Hydra
//
//	@Summary		Delete OAuth2 client
//	@Description	Deletes a client from Hydra by client_id
//	@Tags			clients
//	@Param			client_id	path	string	true	"Client ID to delete"
//	@Success		204			"Client deleted"
//	@Failure		400			{string}	string	"Bad request - missing client_id"
//	@Failure		404			{string}	string	"Client not found"
//	@Failure		502			{string}	string	"Failed to delete client in Hydra"
//	@Router			/admin/clients/{client_id} [delete]
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

// handleRotateClient rotates the client secret and returns the new secret with its hash
//
//	@Summary		Rotate client secret
//	@Description	Rotates the client secret and returns the new secret along with its hash from the database. Optionally accepts client_secret_expires_at to set expiration for the new secret.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client_id	path		string					true	"Client ID"
//	@Param			request		body		RotateClientRequest		false	"Optional expiration settings"
//	@Success		200			{object}	EnhancedClientResponse	"Client with new secret and hash"
//	@Failure		400			{string}	string					"Bad request - missing client_id"
//	@Failure		404			{string}	string					"Client not found"
//	@Failure		405			{string}	string					"Method not allowed"
//	@Failure		502			{string}	string					"Failed to rotate client secret in Hydra"
//	@Router			/admin/clients/rotate/{client_id} [post]
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

	// Parse Hydra response
	var hydraClient HydraClientResponse
	if err := json.Unmarshal(hydraBody, &hydraClient); err != nil {
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
			hydraClient.ClientSecretExpiresAt = rotateReq.ClientSecretExpiresAt
			log.Printf("Updated client %s expiration to %d", clientID, rotateReq.ClientSecretExpiresAt)
		}
	}

	// Get the hashed secret from the database
	hashedSecret, err := s.store.GetHashedSecret(r.Context(), hydraClient.ClientID, s.networkID)
	if err != nil {
		log.Printf("Warning: Could not retrieve hashed secret for %s: %v", hydraClient.ClientID, err)
		// Still return the response, just without the hash
	}

	// Build enhanced response
	enhanced := EnhancedClientResponse{
		HydraClientResponse: hydraClient,
		ClientSecretHash:    hashedSecret,
	}

	log.Printf("Client %s secret rotated successfully", clientID)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(hydraResp.StatusCode)
	if err := json.NewEncoder(w).Encode(enhanced); err != nil {
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

// handleSyncClients performs full reconciliation of clients
//
//	@Summary		Bulk sync OAuth2 clients
//	@Description	Performs full reconciliation of clients - creates new, updates existing, deletes removed. Expects pre-hashed secrets.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			clients	body		SyncClientsRequest	true	"List of clients to sync"
//	@Success		200		{object}	SyncResult			"Sync completed"
//	@Failure		400		{string}	string				"Bad request - invalid JSON or hash format"
//	@Failure		405		{string}	string				"Method not allowed"
//	@Failure		500		{string}	string				"Internal error during sync"
//	@Router			/sync/clients [post]
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
		if err := s.validateHash(c.ClientSecret); err != nil {
			http.Error(w, fmt.Sprintf("Bad request: client %s: %v", c.ClientID, err), http.StatusBadRequest)
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

	// Convert to official client.Client structs
	hydraClients := make([]client.Client, len(req.Clients))
	for i, c := range req.Clients {
		// Set default grant types if not provided
		grantTypes := c.GrantTypes
		if len(grantTypes) == 0 {
			grantTypes = []string{"client_credentials"}
		}

		tokenAuthMethod := c.TokenEndpointAuthMethod
		if tokenAuthMethod == "" {
			tokenAuthMethod = "client_secret_basic"
		}

		hydraClients[i] = client.Client{
			ID:                      c.ClientID,
			NID:                     nid,
			Name:                    c.ClientName,
			Secret:                  c.ClientSecret,
			GrantTypes:              sqlxx.StringSliceJSONFormat(grantTypes),
			ResponseTypes:           sqlxx.StringSliceJSONFormat(c.ResponseTypes),
			Scope:                   c.Scope,
			TokenEndpointAuthMethod: tokenAuthMethod,
			RedirectURIs:            sqlxx.StringSliceJSONFormat(c.RedirectURIs),
			Audience:                sqlxx.StringSliceJSONFormat(c.Audience),
			SecretExpiresAt:         int(c.ClientSecretExpiresAt),
		}

		// Handle client_credentials_grant_access_token_lifespan
		if c.ClientCredentialsGrantAccessTokenLifespan != "" {
			if duration, err := time.ParseDuration(c.ClientCredentialsGrantAccessTokenLifespan); err == nil {
				hydraClients[i].Lifespans.ClientCredentialsGrantAccessTokenLifespan = hydrax.NullDuration{
					Duration: duration,
					Valid:    true,
				}
			} else {
				log.Printf("Warning: invalid lifespan format for client %s: %v", c.ClientID, err)
			}
		}

		// Handle metadata - convert map to sqlxx.JSONRawMessage
		if c.Metadata != nil {
			if metadataBytes, err := json.Marshal(c.Metadata); err == nil {
				hydraClients[i].Metadata = metadataBytes
			}
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


// handleHealth returns 200 if the server is running
//
//	@Summary		Health check
//	@Description	Returns OK if the server is running (liveness probe)
//	@Tags			health
//	@Produce		plain
//	@Success		200	{string}	string	"OK"
//	@Router			/health [get]
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// handleReady returns 200 if the database is connected
//
//	@Summary		Readiness check
//	@Description	Returns OK if the database connection is healthy (readiness probe)
//	@Tags			health
//	@Produce		plain
//	@Success		200	{string}	string	"OK"
//	@Failure		503	{string}	string	"Database not ready"
//	@Router			/ready [get]
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
