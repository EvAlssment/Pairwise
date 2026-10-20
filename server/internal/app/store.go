package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type User struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Email        string `json:"email"`
	PasswordHash string `json:"passwordHash"`
	Enabled      bool   `json:"enabled"`
	Admin        bool   `json:"admin"`
}
type Session struct {
	UserID    string    `json:"userId"`
	ExpiresAt time.Time `json:"expiresAt"`
}
type Member struct {
	UserID   string    `json:"userId"`
	LastSeen time.Time `json:"lastSeen"`
}
type Room struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	Members       map[string]Member `json:"members"`
	DirectOnly    bool              `json:"directOnly,omitempty"`
	SharingUserID string            `json:"sharingUserId,omitempty"`
	CreatedAt     time.Time         `json:"createdAt"`
}
type CallInvitation struct {
	ID        string    `json:"id"`
	CallerID  string    `json:"callerId"`
	TargetID  string    `json:"targetId"`
	RoomID    string    `json:"roomId"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	ExpiresAt time.Time `json:"expiresAt"`
}
type CallJoinRequest struct {
	ID          string    `json:"id"`
	RequesterID string    `json:"requesterId"`
	RoomID      string    `json:"roomId"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
	ExpiresAt   time.Time `json:"expiresAt"`
}
type DeviceRegistration struct {
	UserID    string    `json:"userId"`
	DeviceID  string    `json:"deviceId"`
	Platform  string    `json:"platform"`
	PushToken string    `json:"pushToken,omitempty"`
	VoIPToken string    `json:"voipToken,omitempty"`
	UpdatedAt time.Time `json:"updatedAt"`
}
type PushJob struct {
	ID            string    `json:"id"`
	UserID        string    `json:"userId"`
	DeviceID      string    `json:"deviceId"`
	Platform      string    `json:"platform"`
	Event         string    `json:"event"`
	CallID        string    `json:"callId"`
	RequestID     string    `json:"requestId,omitempty"`
	ExpiresAt     time.Time `json:"expiresAt"`
	NextAttemptAt time.Time `json:"nextAttemptAt"`
	Attempts      int       `json:"attempts"`
	LeaseOwner    string    `json:"leaseOwner,omitempty"`
	LeaseUntil    time.Time `json:"leaseUntil,omitempty"`
}
type AdminAuditEvent struct {
	ActorID    string    `json:"actorId"`
	TargetID   string    `json:"targetId"`
	Action     string    `json:"action"`
	OccurredAt time.Time `json:"occurredAt"`
}
type State struct {
	Users        map[string]User               `json:"users"`
	Sessions     map[string]Session            `json:"sessions"`
	Rooms        map[string]Room               `json:"rooms"`
	Presence     map[string]time.Time          `json:"presence"`
	Calls        map[string]CallInvitation     `json:"calls"`
	JoinRequests map[string]CallJoinRequest    `json:"joinRequests,omitempty"`
	Devices      map[string]DeviceRegistration `json:"devices,omitempty"`
	PushJobs     map[string]PushJob            `json:"pushJobs,omitempty"`
	AdminAudit   []AdminAuditEvent             `json:"adminAudit,omitempty"`
}
type Store struct {
	mu   sync.Mutex
	path string
	s    State
	db   *pgxpool.Pool
	tx   *pgx.Tx
}

func emptyState() State {
	return State{Users: map[string]User{}, Sessions: map[string]Session{}, Rooms: map[string]Room{}, Presence: map[string]time.Time{}, Calls: map[string]CallInvitation{}, JoinRequests: map[string]CallJoinRequest{}, Devices: map[string]DeviceRegistration{}, PushJobs: map[string]PushJob{}}
}

func normalizeState(s *State) {
	if s.Users == nil {
		s.Users = map[string]User{}
	}
	if s.Sessions == nil {
		s.Sessions = map[string]Session{}
	}
	if s.Rooms == nil {
		s.Rooms = map[string]Room{}
	}
	if s.Presence == nil {
		s.Presence = map[string]time.Time{}
	}
	if s.Calls == nil {
		s.Calls = map[string]CallInvitation{}
	}
	if s.JoinRequests == nil {
		s.JoinRequests = map[string]CallJoinRequest{}
	}
	if s.Devices == nil {
		s.Devices = map[string]DeviceRegistration{}
	}
	if s.PushJobs == nil {
		s.PushJobs = map[string]PushJob{}
	}
}

func OpenStore(path string) (*Store, error) {
	st := &Store{path: path, s: emptyState()}
	b, e := os.ReadFile(path)
	if e == nil {
		if e = json.Unmarshal(b, &st.s); e != nil {
			return nil, e
		}
		normalizeState(&st.s)
	} else if !errors.Is(e, os.ErrNotExist) {
		return nil, e
	}
	return st, nil
}

// OpenPostgresStore enables a shared, transactionally serialized store. Each
// state transaction locks the singleton row, preserving the existing atomic
// call-plus-outbox semantics across API replicas while keeping the JSON schema
// portable for import/export during migration.
func OpenPostgresStore(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("configure postgres: %w", err)
	}
	if err = pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect postgres: %w", err)
	}
	_, err = pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS pairdesk_state (id SMALLINT PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL DEFAULT 1, payload JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now())`)
	if err == nil {
		_, err = pool.Exec(ctx, `INSERT INTO pairdesk_state (id, payload) VALUES (1, '{}'::jsonb) ON CONFLICT (id) DO NOTHING`)
	}
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("initialize pairdesk schema: %w", err)
	}
	return &Store{db: pool, s: emptyState()}, nil
}

func OpenStoreFromEnv(ctx context.Context, path string) (*Store, error) {
	if dsn := os.Getenv("PAIRDESK_DATABASE_URL"); dsn != "" {
		return OpenPostgresStore(ctx, dsn)
	}
	return OpenStore(path)
}

func (st *Store) Check(ctx context.Context) error {
	if st.db == nil {
		return nil
	}
	return st.db.Ping(ctx)
}

func (st *Store) Close() {
	if st.db != nil {
		st.db.Close()
	}
}

func (st *Store) ExportJSON(path string) error {
	st.lock()
	defer st.unlock()
	b, err := json.MarshalIndent(st.s, "", "  ")
	if err != nil {
		return err
	}
	return writeStateFile(path, b)
}

func (st *Store) ImportJSON(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var incoming State
	if err = json.Unmarshal(b, &incoming); err != nil {
		return err
	}
	normalizeState(&incoming)
	st.lock()
	defer st.unlock()
	previous := st.s
	st.s = incoming
	if err = st.save(); err != nil {
		st.s = previous
		return err
	}
	return nil
}

func (st *Store) lock() {
	st.mu.Lock()
	if st.db == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := st.db.BeginTx(ctx, pgx.TxOptions{})
	if err == nil {
		st.tx = &tx
		var payload []byte
		err = tx.QueryRow(ctx, `SELECT payload FROM pairdesk_state WHERE id = 1 FOR UPDATE`).Scan(&payload)
		if err == nil {
			st.s = emptyState()
			err = json.Unmarshal(payload, &st.s)
			normalizeState(&st.s)
		}
	}
	if err != nil {
		if tx != nil {
			_ = tx.Rollback(context.Background())
		}
		st.tx = nil
		st.mu.Unlock()
		panic(storageError{err})
	}
}

type storageError struct{ err error }

func (e storageError) Error() string { return "shared storage unavailable: " + e.err.Error() }

func (st *Store) unlock() {
	if st.tx != nil {
		_ = (*st.tx).Rollback(context.Background())
		st.tx = nil
	}
	st.mu.Unlock()
}
func (st *Store) save() error {
	b, e := json.MarshalIndent(st.s, "", "  ")
	if e != nil {
		return e
	}
	if st.tx != nil {
		if _, e = (*st.tx).Exec(context.Background(), `UPDATE pairdesk_state SET payload = $1::jsonb, updated_at = now() WHERE id = 1`, b); e != nil {
			return e
		}
		e = (*st.tx).Commit(context.Background())
		st.tx = nil
		return e
	}
	if st.db != nil {
		return errors.New("shared storage transaction is not active")
	}
	return writeStateFile(st.path, b)
}

func writeStateFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".pairdesk-*.tmp")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	if e = os.Chmod(name, 0600); e != nil {
		return e
	}
	return os.Rename(name, path)
}

func appendAdminAudit(state *State, actorID, targetID, action string) {
	state.AdminAudit = append(state.AdminAudit, AdminAuditEvent{
		ActorID: actorID, TargetID: targetID, Action: action, OccurredAt: time.Now().UTC(),
	})
	const maxAdminAuditEvents = 500
	if len(state.AdminAudit) > maxAdminAuditEvents {
		state.AdminAudit = append([]AdminAuditEvent(nil), state.AdminAudit[len(state.AdminAudit)-maxAdminAuditEvents:]...)
	}
}

func (st *Store) ListAdminAudit() []AdminAuditEvent {
	st.lock()
	defer st.unlock()
	return append([]AdminAuditEvent(nil), st.s.AdminAudit...)
}

func (st *Store) RoomsForUser(userID string) []string {
	st.lock()
	defer st.unlock()
	rooms := make([]string, 0)
	for roomID, room := range st.s.Rooms {
		if _, exists := room.Members[userID]; exists {
			rooms = append(rooms, roomID)
		}
	}
	sort.Strings(rooms)
	return rooms
}
