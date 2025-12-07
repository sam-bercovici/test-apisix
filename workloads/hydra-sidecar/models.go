package main

import (
	"github.com/ory/hydra/v2/client"
)

// ClientData represents an OAuth2 client with sidecar extensions.
//
// Used for:
//   - POST /admin/clients response (client_secret=plaintext, client_secret_hash=hash)
//   - POST /admin/clients/rotate/{id} response (client_secret=new plaintext, client_secret_hash=new hash)
//   - POST /sync/clients request array element (client_secret_hash=required hash, client_secret=ignored)
//
// swagger:model clientData
type ClientData struct {
	// swagger:allOf
	client.Client

	// Pre-hashed client secret for storage and sync.
	//
	// In responses (create/rotate):
	//   Contains the hash of the plaintext secret - store this value.
	//
	// In sync requests:
	//   Required. Must contain the stored hash value.
	//   Note: client_secret is ignored in sync requests (use this field instead).
	ClientSecretHash string `json:"client_secret_hash,omitempty"`
}

// SyncClientsRequest is the request body for bulk client sync.
//
// swagger:model syncClientsRequest
type SyncClientsRequest struct {
	// Array of clients to sync.
	// Each client must have client_secret_hash set to the stored hash value.
	// The client_secret field is ignored (use client_secret_hash instead).
	Clients []ClientData `json:"clients"`
}

// RotateClientRequest is the optional request body for secret rotation.
//
// swagger:model rotateClientRequest
type RotateClientRequest struct {
	// Unix timestamp when the new secret expires (0 = never)
	ClientSecretExpiresAt int64 `json:"client_secret_expires_at,omitempty"`
}

// SyncResult is the response from bulk client sync.
//
// swagger:model syncResult
type SyncResult struct {
	// Number of clients created
	CreatedCount int `json:"created_count"`
	// Number of clients updated
	UpdatedCount int `json:"updated_count"`
	// Number of clients deleted
	DeletedCount int `json:"deleted_count"`
	// Number of operations that failed
	FailedCount int `json:"failed_count"`
	// Per-client operation results
	Results []ClientResult `json:"results"`
}

// ClientResult is the result for a single client in sync.
//
// swagger:model clientResult
type ClientResult struct {
	// Client ID
	ClientID string `json:"client_id"`
	// Operation status: "created", "updated", "deleted", or "failed"
	Status string `json:"status"`
	// Error message if status is "failed"
	Error *string `json:"error,omitempty"`
}

// TokenHookRequest represents the incoming request from Hydra token hook.
//
// swagger:model tokenHookRequest
type TokenHookRequest struct {
	Session struct {
		ClientID string `json:"client_id"`
	} `json:"session"`
	Request struct {
		ClientID string   `json:"client_id"`
		Scopes   []string `json:"granted_scopes"`
	} `json:"request"`
}

// TokenHookResponse represents the response to Hydra token hook.
//
// swagger:model tokenHookResponse
type TokenHookResponse struct {
	Session struct {
		AccessToken map[string]any `json:"access_token"`
	} `json:"session"`
}

// TokenHookErrorResponse represents an error response to Hydra token hook.
//
// swagger:model tokenHookErrorResponse
type TokenHookErrorResponse struct {
	// Error code (e.g., "access_denied")
	Error string `json:"error"`
	// Human-readable error description
	ErrorDescription string `json:"error_description"`
}

// ClientInfo holds client metadata and expiration info from Hydra.
// Used internally by the token hook.
type ClientInfo struct {
	Metadata              map[string]any `json:"metadata"`
	ClientSecretExpiresAt int64          `json:"client_secret_expires_at"`
}

// ==== Swagger Response Wrappers ====

// ErrorResponse represents an error response.
//
// swagger:response errorResponse
type ErrorResponse struct {
	// The error message
	// in: body
	Body struct {
		// Error message
		Error string `json:"error"`
	}
}

// NoContentResponse represents a 204 No Content response.
//
// swagger:response noContent
type NoContentResponse struct {
}

// HealthResponse represents a health check response.
//
// swagger:response healthResponse
type HealthResponse struct {
	// Health status
	// in: body
	Body string
}

// ClientDataResponse wraps ClientData for swagger response.
//
// swagger:response clientDataResponse
type ClientDataResponse struct {
	// in: body
	Body ClientData
}

// SyncResultResponse wraps SyncResult for swagger response.
//
// swagger:response syncResultResponse
type SyncResultResponse struct {
	// in: body
	Body SyncResult
}

// TokenHookResponseWrapper wraps TokenHookResponse for swagger.
//
// swagger:response tokenHookResponseWrapper
type TokenHookResponseWrapper struct {
	// in: body
	Body TokenHookResponse
}

// TokenHookErrorResponseWrapper wraps TokenHookErrorResponse for swagger.
//
// swagger:response tokenHookErrorResponseWrapper
type TokenHookErrorResponseWrapper struct {
	// in: body
	Body TokenHookErrorResponse
}

// ==== Swagger Parameter Definitions ====
// These types are used by go-swagger to generate API documentation.
// They are intentionally not referenced in Go code.

// swagger:parameters getClient deleteClient
type clientIDPathParam struct {
	// Client ID
	// in: path
	// required: true
	ClientID string `json:"client_id"`
}

// swagger:parameters rotateClient
type rotateClientParams struct {
	// Client ID
	// in: path
	// required: true
	ClientID string `json:"client_id"`
	// Optional rotation settings
	// in: body
	Body RotateClientRequest
}

// swagger:parameters createClient
type createClientParams struct {
	// OAuth2 client configuration (passed through to Hydra)
	// in: body
	// required: true
	Body client.Client
}

// swagger:parameters syncClients
type syncClientsParams struct {
	// Clients to sync (client_secret_hash must contain the stored hash)
	// in: body
	// required: true
	Body SyncClientsRequest
}

// swagger:parameters tokenHook
type tokenHookParams struct {
	// Token hook request from Hydra
	// in: body
	// required: true
	Body TokenHookRequest
}

// Ensure swagger parameter types are "used" to satisfy linters.
var (
	_ = clientIDPathParam{}
	_ = rotateClientParams{}
	_ = createClientParams{}
	_ = syncClientsParams{}
	_ = tokenHookParams{}
)
