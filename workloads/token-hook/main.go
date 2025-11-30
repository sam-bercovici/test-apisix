package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
)

var hydraAdminURL string

func init() {
	hydraAdminURL = os.Getenv("HYDRA_ADMIN_URL")
	if hydraAdminURL == "" {
		hydraAdminURL = "http://localhost:4445" // Default for sidecar
	}
}

// TokenHookRequest represents the incoming request from Hydra
type TokenHookRequest struct {
	Session struct {
		ClientID string `json:"client_id"`
	} `json:"session"`
	Request struct {
		ClientID string   `json:"client_id"`
		Scopes   []string `json:"granted_scopes"`
	} `json:"request"`
}

// TokenHookResponse represents the response to Hydra
type TokenHookResponse struct {
	Session struct {
		AccessToken map[string]interface{} `json:"access_token"`
	} `json:"session"`
}

// HydraClient represents the client object returned by Hydra Admin API
type HydraClient struct {
	ClientID string                 `json:"client_id"`
	Metadata map[string]interface{} `json:"metadata"`
}

// fetchClientMetadata fetches client metadata from Hydra Admin API
func fetchClientMetadata(clientID string) (map[string]interface{}, error) {
	url := fmt.Sprintf("%s/admin/clients/%s", hydraAdminURL, clientID)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("failed to fetch client: %d", resp.StatusCode)
	}

	var client HydraClient
	if err := json.NewDecoder(resp.Body).Decode(&client); err != nil {
		return nil, err
	}

	return client.Metadata, nil
}

func tokenHook(w http.ResponseWriter, r *http.Request) {
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

	// Fetch client metadata from Hydra Admin API
	metadata, err := fetchClientMetadata(clientID)
	if err != nil {
		log.Printf("Failed to fetch metadata for %s: %v, using fallback", clientID, err)
		metadata = nil
	}

	// Build custom claims from client metadata
	customClaims := make(map[string]interface{})

	if metadata != nil {
		// Extract org_id from metadata
		if orgID, ok := metadata["org_id"].(string); ok {
			customClaims["org_id"] = orgID
			log.Printf("Setting org_id: %s for client: %s", orgID, clientID)
		}

		// Extract tier from metadata (for tiered rate limiting)
		if tier, ok := metadata["tier"].(string); ok {
			customClaims["tier"] = tier
		}

		// Extract any other custom fields
		if orgName, ok := metadata["org_name"].(string); ok {
			customClaims["org_name"] = orgName
		}
	}

	// If no org_id in metadata, fall back to client_id
	if _, hasOrgID := customClaims["org_id"]; !hasOrgID {
		customClaims["org_id"] = clientID
		log.Printf("No org_id in metadata, using client_id: %s", clientID)
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

func healthCheck(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/token-hook", tokenHook)
	http.HandleFunc("/health", healthCheck)

	log.Printf("Token hook service starting on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
