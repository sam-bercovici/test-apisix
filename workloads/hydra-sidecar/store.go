package main

import (
	"context"
	"fmt"

	"github.com/gobuffalo/pop/v6"
	"github.com/gofrs/uuid"
	"github.com/ory/hydra/v2/client"
)

// Store handles database operations using pop (same ORM as Hydra)
type Store struct {
	conn *pop.Connection
}

// NewStore creates a new database store
func NewStore(databaseURL string) (*Store, error) {
	// Create connection details from URL
	details := &pop.ConnectionDetails{
		URL: databaseURL,
	}

	conn, err := pop.NewConnection(details)
	if err != nil {
		return nil, fmt.Errorf("failed to create connection: %w", err)
	}

	if err := conn.Open(); err != nil {
		return nil, fmt.Errorf("failed to open connection: %w", err)
	}

	return &Store{conn: conn}, nil
}

// Close closes the database connection
func (s *Store) Close() error {
	return s.conn.Close()
}

// GetDefaultNetworkID retrieves the single network ID for single-tenant deployments
func (s *Store) GetDefaultNetworkID(ctx context.Context) (uuid.UUID, error) {
	var nid uuid.UUID
	err := s.conn.RawQuery("SELECT id FROM networks LIMIT 1").First(&nid)
	if err != nil {
		return uuid.Nil, fmt.Errorf("failed to get network ID: %w", err)
	}
	return nid, nil
}

// GetHashedSecret retrieves the hashed secret for a client
func (s *Store) GetHashedSecret(ctx context.Context, clientID string, nid uuid.UUID) (string, error) {
	var c client.Client
	err := s.conn.Where("id = ? AND nid = ?", clientID, nid).First(&c)
	if err != nil {
		return "", fmt.Errorf("failed to get client: %w", err)
	}
	return c.Secret, nil
}

// GetAllClientIDs retrieves all client IDs for a network
func (s *Store) GetAllClientIDs(ctx context.Context, nid uuid.UUID) ([]string, error) {
	var clients []client.Client
	err := s.conn.Where("nid = ?", nid).Select("id").All(&clients)
	if err != nil {
		return nil, fmt.Errorf("failed to get client IDs: %w", err)
	}

	ids := make([]string, len(clients))
	for i, c := range clients {
		ids[i] = c.ID
	}
	return ids, nil
}

// UpsertClient creates or updates a client in the database
func (s *Store) UpsertClient(ctx context.Context, c *client.Client) error {
	// Check if client exists
	existing := &client.Client{}
	err := s.conn.Where("id = ? AND nid = ?", c.ID, c.NID).First(existing)

	if err != nil {
		// Client doesn't exist, create it
		return s.conn.Create(c)
	}

	// Client exists, update it
	return s.conn.Update(c)
}

// DeleteClient deletes a client by ID
func (s *Store) DeleteClient(ctx context.Context, clientID string, nid uuid.UUID) error {
	return s.conn.RawQuery("DELETE FROM hydra_client WHERE id = ? AND nid = ?", clientID, nid).Exec()
}

// Ping checks database connectivity
func (s *Store) Ping(ctx context.Context) error {
	return s.conn.RawQuery("SELECT 1").Exec()
}

// SyncClients performs full reconciliation of clients
func (s *Store) SyncClients(ctx context.Context, clients []client.Client, nid uuid.UUID) (*SyncResult, error) {
	result := &SyncResult{
		Results: make([]ClientResult, 0),
	}

	// 1. Get all existing client IDs
	existingIDs, err := s.GetAllClientIDs(ctx, nid)
	if err != nil {
		return nil, fmt.Errorf("failed to get existing clients: %w", err)
	}

	existingMap := make(map[string]bool)
	for _, id := range existingIDs {
		existingMap[id] = true
	}

	// 2. Track which IDs are in the sync request
	syncedIDs := make(map[string]bool)

	// 3. Upsert each client
	for _, c := range clients {
		c.NID = nid
		syncedIDs[c.ID] = true

		wasExisting := existingMap[c.ID]

		if err := s.UpsertClient(ctx, &c); err != nil {
			errStr := err.Error()
			result.Results = append(result.Results, ClientResult{
				ClientID: c.ID,
				Status:   "failed",
				Error:    &errStr,
			})
			result.FailedCount++
			continue
		}

		if wasExisting {
			result.Results = append(result.Results, ClientResult{
				ClientID: c.ID,
				Status:   "updated",
			})
			result.UpdatedCount++
		} else {
			result.Results = append(result.Results, ClientResult{
				ClientID: c.ID,
				Status:   "created",
			})
			result.CreatedCount++
		}
	}

	// 4. Delete clients not in sync request
	for _, id := range existingIDs {
		if !syncedIDs[id] {
			if err := s.DeleteClient(ctx, id, nid); err != nil {
				errStr := err.Error()
				result.Results = append(result.Results, ClientResult{
					ClientID: id,
					Status:   "failed",
					Error:    &errStr,
				})
				result.FailedCount++
				continue
			}
			result.Results = append(result.Results, ClientResult{
				ClientID: id,
				Status:   "deleted",
			})
			result.DeletedCount++
		}
	}

	return result, nil
}
