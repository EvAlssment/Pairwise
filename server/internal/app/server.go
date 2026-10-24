package app

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/mail"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const sessionTTL = 7 * 24 * time.Hour
const reservationTTL = 30 * time.Second
const mediaTTL = 60 * time.Second
const maxRoom = 4

type Server struct {
	store                        *Store
	push                         PushSender
	pushWake                     chan struct{}
	pushMu                       sync.Mutex
	pushWorkerID                 string
	liveURL, liveKey, liveSecret string
	liveAPIURL                   string
	dummyHash                    []byte
	hits                         map[string][]time.Time
	hitMu                        sync.Mutex
	signupEnabled                bool
	signupAllowedDomains         map[string]struct{}
}

func New(st *Store) *Server {
	h, _ := bcrypt.GenerateFromPassword([]byte("invalid-password-placeholder"), bcrypt.DefaultCost)
	apiURL := os.Getenv("LIVEKIT_API_URL")
	if apiURL == "" {
		apiURL = "http://127.0.0.1:7880"
	}
	domains := map[string]struct{}{}
	for _, domain := range strings.Split(os.Getenv("PAIRDESK_SIGNUP_ALLOWED_DOMAINS"), ",") {
		if domain = strings.ToLower(strings.TrimSpace(domain)); domain != "" {
			domains[domain] = struct{}{}
		}
	}
	enabled := true
	if value := strings.TrimSpace(os.Getenv("PAIRDESK_SIGNUP_ENABLED")); value != "" {
		enabled = strings.EqualFold(value, "true") || value == "1"
	}
	return &Server{store: st, push: configuredPushFromEnv(), pushWake: make(chan struct{}, 1), liveURL: os.Getenv("LIVEKIT_URL"), liveAPIURL: apiURL, liveKey: os.Getenv("LIVEKIT_API_KEY"), liveSecret: os.Getenv("LIVEKIT_API_SECRET"), dummyHash: h, hits: map[string][]time.Time{}, signupEnabled: enabled, signupAllowedDomains: domains}
}
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			fail(w, 405, "method not allowed")
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	mux.HandleFunc("/version", s.version)
	mux.HandleFunc("/readyz", s.ready)
	mux.HandleFunc("/v1/login", s.login)
	mux.HandleFunc("/v1/signup", s.signup)
	mux.HandleFunc("/v1/signup-policy", s.signupPolicy)
	mux.HandleFunc("/v1/me", s.auth(s.me))
	mux.HandleFunc("/v1/users", s.auth(s.users))
	mux.HandleFunc("/v1/heartbeat", s.auth(s.heartbeat))
	mux.HandleFunc("/v1/devices", s.auth(s.devices))
	mux.HandleFunc("/v1/devices/", s.auth(s.devices))
	mux.HandleFunc("/v1/logout", s.auth(s.logout))
	mux.HandleFunc("/v1/password", s.auth(s.changePassword))
	mux.HandleFunc("/v1/admin/users", s.auth(s.adminCreateUser))
	mux.HandleFunc("/v1/admin/users/", s.auth(s.adminUserAction))
	mux.HandleFunc("/v1/admin/audit", s.auth(s.adminAudit))
	mux.HandleFunc("/v1/rooms", s.auth(s.rooms))
	mux.HandleFunc("/v1/rooms/", s.auth(s.roomAction))
	mux.HandleFunc("/v1/calls", s.auth(s.calls))
	mux.HandleFunc("/v1/calls/", s.auth(s.callAction))
	mux.HandleFunc("/v1/active-calls", s.auth(s.activeCalls))
	mux.HandleFunc("/v1/join-requests", s.auth(s.joinRequests))
	mux.HandleFunc("/v1/join-requests/", s.auth(s.joinRequestAction))
	return securityHeaders(recoverStorage(mux))
}

func (s *Server) version(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		fail(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"service":     "pairdesk-api",
		"apiProtocol": "v1",
		"buildCommit": safeBuildCommit(buildCommit),
	})
}

func (s *Server) signupPolicy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		fail(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	domains := make([]string, 0, len(s.signupAllowedDomains))
	for domain := range s.signupAllowedDomains {
		domains = append(domains, domain)
	}
	sort.Strings(domains)
	writeJSON(w, http.StatusOK, map[string]any{"enabled": s.signupEnabled, "allowedDomains": domains})
}

func (s *Server) signup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !s.signupEnabled {
		fail(w, http.StatusForbidden, "self-service signup is disabled for this team")
		return
	}
	type req struct {
		Name     string `json:"name"`
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	var q req
	if decode(r, &q) != nil || len(q.Name) > 100 || len(q.Email) > 254 || len(q.Password) > 1024 {
		fail(w, http.StatusBadRequest, "invalid request")
		return
	}
	name := strings.TrimSpace(q.Name)
	email := strings.ToLower(strings.TrimSpace(q.Email))
	parsed, err := mail.ParseAddress(email)
	if name == "" || parsed == nil || parsed.Address != email || len(q.Password) < 12 {
		fail(w, http.StatusBadRequest, "enter a name, valid email, and password of at least 12 characters")
		return
	}
	if len(s.signupAllowedDomains) > 0 {
		parts := strings.Split(email, "@")
		if len(parts) != 2 {
			fail(w, http.StatusBadRequest, "email domain is not allowed for this team")
			return
		}
		if _, ok := s.signupAllowedDomains[parts[1]]; !ok {
			fail(w, http.StatusForbidden, "email domain is not allowed for this team")
			return
		}
	}
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip == "" {
		ip = r.RemoteAddr
	}
	if !s.allowed(ip) {
		fail(w, http.StatusTooManyRequests, "too many signup attempts; try again later")
		return
	}
	// Count all attempts, including successful registrations, against the same
	// per-IP 15-minute budget used by login failures.
	s.recordLoginFailure(ip)
	u, err := s.store.CreateUser(name, email, q.Password, false)
	if err != nil {
		if strings.Contains(err.Error(), "email already exists") {
			fail(w, http.StatusConflict, "an account with this email already exists; sign in instead")
			return
		}
		fail(w, http.StatusInternalServerError, "could not create account")
		return
	}
	token, err := randomID(32)
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal error")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(sessionTTL)
	s.store.lock()
	s.store.s.Sessions[token] = Session{u.ID, expires}
	err = s.store.save()
	if err != nil {
		delete(s.store.s.Sessions, token)
	}
	s.store.unlock()
	if err != nil {
		fail(w, http.StatusInternalServerError, "could not start session")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "user": pub(u), "expiresAt": expires.Format(time.RFC3339)})
}

func recoverStorage(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				if _, ok := recovered.(storageError); !ok {
					panic(recovered)
				}
				log.Printf("shared storage unavailable path=%s", r.URL.Path)
				fail(w, http.StatusServiceUnavailable, "shared storage is unavailable")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		fail(w, 405, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Check(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "dependency": "storage"})
		return
	}
	status, _, err := s.livekitCallResult("ListRooms", map[string]any{"names": []string{}})
	if err != nil || status < 200 || status >= 300 {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "dependency": "media"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "media": true})
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

type apiUser struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Email   string `json:"email"`
	Admin   bool   `json:"admin,omitempty"`
	Enabled bool   `json:"enabled"`
}

func pub(u User) apiUser {
	return apiUser{ID: u.ID, Name: u.Name, Email: u.Email, Admin: u.Admin, Enabled: u.Enabled}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
func decode(r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(nil, r.Body, 1<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	return d.Decode(v)
}
func randomID(n int) (string, error) {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	type req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	var q req
	if decode(r, &q) != nil || len(q.Email) > 254 || len(q.Password) > 1024 {
		fail(w, 400, "invalid request")
		return
	}
	email := strings.ToLower(strings.TrimSpace(q.Email))
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip == "" {
		ip = r.RemoteAddr
	}
	if !s.allowed(ip) {
		fail(w, 429, "too many login attempts")
		return
	}
	s.store.lock()
	var u User
	found := false
	for _, x := range s.store.s.Users {
		if strings.EqualFold(x.Email, email) {
			u = x
			found = true
			break
		}
	}
	hash := s.dummyHash
	if found {
		hash = []byte(u.PasswordHash)
	}
	s.store.unlock()
	err := bcrypt.CompareHashAndPassword(hash, []byte(q.Password))
	if err != nil || !found || !u.Enabled {
		s.recordLoginFailure(ip)
		fail(w, 401, "invalid email or password")
		return
	}
	tok, e := randomID(32)
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(sessionTTL)
	s.store.lock()
	for key, session := range s.store.s.Sessions {
		if !now.Before(session.ExpiresAt) {
			delete(s.store.s.Sessions, key)
		}
	}
	s.store.s.Sessions[tok] = Session{u.ID, expires}
	e = s.store.save()
	s.store.unlock()
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	s.clearLoginFailures(ip)
	writeJSON(w, 200, map[string]any{"token": tok, "user": pub(u), "expiresAt": expires.Format(time.RFC3339)})
}
func (s *Server) pruneLoginFailures(ip string, now time.Time) []time.Time {
	a := s.hits[ip][:0]
	for _, t := range s.hits[ip] {
		if now.Sub(t) < 15*time.Minute {
			a = append(a, t)
		}
	}
	if len(a) == 0 {
		delete(s.hits, ip)
	} else {
		s.hits[ip] = a
	}
	if len(s.hits) > 4096 {
		for key, values := range s.hits {
			if len(values) == 0 || now.Sub(values[len(values)-1]) >= 15*time.Minute {
				delete(s.hits, key)
			}
		}
	}
	return a
}
func (s *Server) allowed(ip string) bool {
	s.hitMu.Lock()
	defer s.hitMu.Unlock()
	return len(s.pruneLoginFailures(ip, time.Now())) < 10
}
func (s *Server) recordLoginFailure(ip string) {
	s.hitMu.Lock()
	defer s.hitMu.Unlock()
	now := time.Now()
	a := s.pruneLoginFailures(ip, now)
	s.hits[ip] = append(a, now)
}
func (s *Server) clearLoginFailures(ip string) {
	s.hitMu.Lock()
	defer s.hitMu.Unlock()
	delete(s.hits, ip)
}

type contextKey int

const userKey contextKey = 1

func (s *Server) auth(next func(http.ResponseWriter, *http.Request, User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := strings.TrimSpace(r.Header.Get("Authorization"))
		if !strings.HasPrefix(header, "Bearer ") {
			fail(w, 401, "authentication required")
			return
		}
		h := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
		if h == "" {
			fail(w, 401, "authentication required")
			return
		}
		s.store.lock()
		sess, ok := s.store.s.Sessions[h]
		u := s.store.s.Users[sess.UserID]
		if ok && time.Now().Before(sess.ExpiresAt) && u.Enabled {
		} else {
			ok = false
		}
		s.store.unlock()
		if !ok {
			fail(w, 401, "invalid or expired session")
			return
		}
		next(w, r, u)
	}
}
func (s *Server) me(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != "GET" {
		fail(w, 405, "method not allowed")
		return
	}
	writeJSON(w, 200, map[string]any{"user": pub(u)})
}
func (s *Server) adminCreateUser(w http.ResponseWriter, r *http.Request, u User) {
	if !u.Admin {
		fail(w, 403, "admin access required")
		return
	}
	if r.Method == http.MethodGet {
		users := s.store.ListUsers()
		out := make([]apiUser, 0, len(users))
		for _, member := range users {
			out = append(out, pub(member))
		}
		writeJSON(w, 200, map[string]any{"users": out})
		return
	}
	if r.Method != http.MethodPost {
		fail(w, 405, "method not allowed")
		return
	}
	var q struct {
		Name     string `json:"name"`
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if decode(r, &q) != nil {
		fail(w, 400, "invalid request")
		return
	}
	created, err := s.store.CreateUser(q.Name, q.Email, q.Password, false)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"user": pub(created)})
}

func (s *Server) adminUserAction(w http.ResponseWriter, r *http.Request, admin User) {
	if !admin.Admin {
		fail(w, 403, "admin access required")
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/admin/users/"), "/"), "/")
	if len(parts) != 2 || parts[0] == "" {
		fail(w, 404, "user action not found")
		return
	}
	switch parts[1] {
	case "enabled":
		if r.Method != http.MethodPost {
			fail(w, 405, "method not allowed")
			return
		}
		var q struct {
			Enabled bool `json:"enabled"`
		}
		if decode(r, &q) != nil {
			fail(w, 400, "invalid request")
			return
		}
		if err := s.store.SetUserEnabledByID(parts[0], q.Enabled, admin.ID); err != nil {
			fail(w, 400, err.Error())
			return
		}
		if !q.Enabled {
			for _, roomID := range s.store.RoomsForUser(parts[0]) {
				if err := s.removeLivekitParticipant(roomID, parts[0]); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
					fail(w, 503, "account disabled, but media access revocation is incomplete; retry the disable action")
					return
				}
			}
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	case "password":
		if r.Method != http.MethodPost {
			fail(w, 405, "method not allowed")
			return
		}
		var q struct {
			NewPassword string `json:"newPassword"`
		}
		if decode(r, &q) != nil || len(q.NewPassword) < 12 || len(q.NewPassword) > 1024 {
			fail(w, 400, "new password must be between 12 and 1024 characters")
			return
		}
		if err := s.store.SetUserPasswordByID(parts[0], q.NewPassword, admin.ID); err != nil {
			fail(w, 400, err.Error())
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	default:
		fail(w, 404, "user action not found")
	}
}

func (s *Server) adminAudit(w http.ResponseWriter, r *http.Request, admin User) {
	if !admin.Admin {
		fail(w, 403, "admin access required")
		return
	}
	if r.Method != http.MethodGet {
		fail(w, 405, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": s.store.ListAdminAudit()})
}
func (s *Server) users(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != "GET" {
		fail(w, 405, "method not allowed")
		return
	}
	now := time.Now()
	s.store.lock()
	out := []any{}
	for _, x := range s.store.s.Users {
		if x.Enabled {
			last := s.store.s.Presence[x.ID]
			out = append(out, map[string]any{"id": x.ID, "name": x.Name, "email": x.Email, "online": now.Sub(last) < reservationTTL, "busy": s.userBusyLocked(x.ID, now)})
		}
	}
	s.store.unlock()
	writeJSON(w, 200, map[string]any{"users": out})
}
func (s *Server) heartbeat(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	s.store.lock()
	s.store.s.Presence[u.ID] = time.Now().UTC()
	e := s.store.save()
	s.store.unlock()
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	var q struct {
		DeviceID string `json:"deviceId"`
	}
	if err := decode(r, &q); err != nil && !errors.Is(err, io.EOF) {
		fail(w, http.StatusBadRequest, "invalid request")
		return
	}
	q.DeviceID = strings.TrimSpace(q.DeviceID)
	if len(q.DeviceID) > 128 || strings.ContainsAny(q.DeviceID, "/\\") {
		fail(w, http.StatusBadRequest, "deviceId must be at most 128 characters")
		return
	}
	h := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	s.store.lock()
	previousSession, hadSession := s.store.s.Sessions[h]
	var previousDevice DeviceRegistration
	var hadDevice bool
	deviceRegistrationKey := ""
	if q.DeviceID != "" {
		deviceRegistrationKey = deviceKey(u.ID, q.DeviceID)
		previousDevice, hadDevice = s.store.s.Devices[deviceRegistrationKey]
		delete(s.store.s.Devices, deviceRegistrationKey)
	}
	delete(s.store.s.Sessions, h)
	e := s.store.save()
	if e != nil {
		if hadSession {
			s.store.s.Sessions[h] = previousSession
		}
		if hadDevice {
			s.store.s.Devices[deviceRegistrationKey] = previousDevice
		}
	}
	s.store.unlock()
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	var q struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if decode(r, &q) != nil || len(q.CurrentPassword) > 1024 || len(q.NewPassword) < 12 || len(q.NewPassword) > 1024 {
		fail(w, 400, "new password must be 12 to 1024 characters")
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(q.CurrentPassword)) != nil {
		fail(w, 401, "current password is incorrect")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(q.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	token := strings.TrimPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ")
	s.store.lock()
	current, ok := s.store.s.Users[u.ID]
	if !ok || !current.Enabled {
		s.store.unlock()
		fail(w, 401, "account is unavailable")
		return
	}
	current.PasswordHash = string(hash)
	s.store.s.Users[u.ID] = current
	for key, session := range s.store.s.Sessions {
		if session.UserID == u.ID && key != token {
			delete(s.store.s.Sessions, key)
		}
	}
	err = s.store.save()
	s.store.unlock()
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

type participant struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

func (s *Server) rooms(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method == "GET" {
		s.store.lock()
		out := []any{}
		now := time.Now()
		for _, rm := range s.store.s.Rooms {
			if rm.DirectOnly {
				continue
			}
			snapshot := s.roomSnapshotLocked(rm, now)
			out = append(out, map[string]any{"id": snapshot.ID, "name": snapshot.Name, "participantCount": snapshot.ParticipantCount, "participants": snapshot.Participants, "sharingUserId": rm.SharingUserID})
		}
		s.store.unlock()
		writeJSON(w, 200, map[string]any{"rooms": out})
		return
	}
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	var q struct {
		Name string `json:"name"`
	}
	if decode(r, &q) != nil {
		fail(w, 400, "invalid request")
		return
	}
	q.Name = strings.TrimSpace(q.Name)
	if q.Name == "" || len(q.Name) > 80 {
		fail(w, 400, "room name must be 1 to 80 characters")
		return
	}
	id, e := randomID(12)
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	rm := Room{ID: id, Name: q.Name, Members: map[string]Member{}, CreatedAt: time.Now().UTC()}
	if e = s.createMediaRoom(id); e != nil {
		fail(w, 503, "media service is unavailable")
		return
	}
	s.store.lock()
	s.store.s.Rooms[id] = rm
	e = s.store.save()
	s.store.unlock()
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, 201, map[string]any{"room": map[string]any{"id": id, "name": q.Name, "participantCount": 0, "participants": []participant{}}})
}
func (s *Server) roomAction(w http.ResponseWriter, r *http.Request, u User) {
	tail := strings.TrimPrefix(r.URL.Path, "/v1/rooms/")
	parts := strings.Split(tail, "/")
	if len(parts) == 2 && parts[0] != "" && parts[1] == "join-requests" {
		s.createJoinRequest(w, r, u, parts[0])
		return
	}
	if len(parts) != 2 || parts[0] == "" {
		fail(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	switch action {
	case "join":
		s.join(w, r, u, id)
	case "share":
		s.share(w, r, u, id)
	case "leave", "heartbeat":
		if r.Method != "POST" {
			fail(w, 405, "method not allowed")
			return
		}
		s.store.lock()
		rm, ok := s.store.s.Rooms[id]
		if !ok {
			s.store.unlock()
			fail(w, 404, "room not found")
			return
		}
		if err := s.clearExpiredSharer(id, &rm); err != nil {
			s.store.unlock()
			fail(w, 503, "media service is unavailable")
			return
		}
		if action == "leave" {
			now := time.Now().UTC()
			if rm.SharingUserID == u.ID {
				if err := s.updateSharePermission(id, u, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
					s.store.unlock()
					fail(w, 503, "media service is unavailable")
					return
				}
				rm.SharingUserID = ""
			}
			if rm.DirectOnly {
				if err := s.leaveDirectRoomLocked(&rm, u, now); err != nil {
					s.store.unlock()
					fail(w, 503, "media service is unavailable")
					return
				}
			} else {
				cancelPendingCallsForCallerLocked(&s.store.s, u.ID, id, now)
				cancelAcceptedCallForTargetLocked(&s.store.s, u.ID, id, now)
				delete(rm.Members, u.ID)
			}
		} else {
			if _, ok = rm.Members[u.ID]; !ok {
				s.store.unlock()
				fail(w, 403, "join the room first")
				return
			}
			m := rm.Members[u.ID]
			m.LastSeen = time.Now().UTC()
			rm.Members[u.ID] = m
		}
		s.store.s.Rooms[id] = rm
		e := s.store.save()
		s.store.unlock()
		if e != nil {
			fail(w, 500, "internal error")
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	default:
		fail(w, 404, "not found")
	}
}

// clearExpiredSharer runs with the store mutex held so a new claim cannot race a stale one.
func (s *Server) clearExpiredSharer(roomID string, rm *Room) error {
	if rm.SharingUserID == "" {
		return nil
	}
	m, exists := rm.Members[rm.SharingUserID]
	if exists && time.Since(m.LastSeen) < reservationTTL {
		return nil
	}
	if old, exists := s.store.s.Users[rm.SharingUserID]; exists {
		if err := s.updateSharePermission(roomID, old, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
			return err
		}
	}
	rm.SharingUserID = ""
	return nil
}
func (s *Server) share(w http.ResponseWriter, r *http.Request, u User, id string) {
	if r.Method != http.MethodPost {
		fail(w, 405, "method not allowed")
		return
	}
	var q struct {
		Enabled *bool `json:"enabled"`
	}
	if decode(r, &q) != nil || q.Enabled == nil {
		fail(w, 400, "enabled must be true or false")
		return
	}
	s.store.lock()
	defer s.store.unlock()
	rm, ok := s.store.s.Rooms[id]
	if !ok {
		fail(w, 404, "room not found")
		return
	}
	if err := s.clearExpiredSharer(id, &rm); err != nil {
		fail(w, 503, "media service is unavailable")
		return
	}
	member, ok := rm.Members[u.ID]
	if !ok || time.Since(member.LastSeen) >= reservationTTL {
		fail(w, 403, "join the room first")
		return
	}
	previous := rm.SharingUserID
	if *q.Enabled {
		if previous != "" && previous != u.ID {
			fail(w, 409, "screen sharing is already claimed")
			return
		}
		if err := s.updateSharePermission(id, u, true); err != nil {
			// A timeout can hide a successful remote update, so actively restore mic-only permission before releasing the claim lock.
			_ = s.updateSharePermission(id, u, false)
			fail(w, 503, "media service is unavailable")
			return
		}
		rm.SharingUserID = u.ID
	} else {
		if previous != "" && previous != u.ID {
			fail(w, 409, "screen sharing is claimed by another participant")
			return
		}
		if previous == u.ID {
			if err := s.updateSharePermission(id, u, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
				fail(w, 503, "media service is unavailable")
				return
			}
		}
		rm.SharingUserID = ""
	}
	s.store.s.Rooms[id] = rm
	if err := s.store.save(); err != nil {
		if *q.Enabled {
			_ = s.updateSharePermission(id, u, false)
		} else if previous == u.ID {
			_ = s.updateSharePermission(id, u, true)
		}
		rm.SharingUserID = previous
		s.store.s.Rooms[id] = rm
		fail(w, 500, "internal error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
func (s *Server) join(w http.ResponseWriter, r *http.Request, u User, id string) {
	if r.Method != "POST" {
		fail(w, 405, "method not allowed")
		return
	}
	if s.liveURL == "" || s.liveKey == "" || s.liveSecret == "" {
		fail(w, 503, "media service is not configured")
		return
	}
	s.store.lock()
	now := time.Now().UTC()
	pruned := s.pruneCallsLocked(now)
	rm, ok := s.store.s.Rooms[id]
	if !ok {
		s.store.unlock()
		fail(w, 404, "room not found")
		return
	}
	if rm.DirectOnly && !s.canJoinDirectRoomLocked(id, u.ID, now) {
		if pruned {
			_ = s.store.save()
		}
		s.store.unlock()
		fail(w, 403, "call invitation must be accepted before joining")
		return
	}
	if err := s.ensureMediaRoom(id); err != nil {
		s.store.unlock()
		fail(w, 503, "media service is unavailable")
		return
	}
	now = time.Now().UTC()
	if rm.SharingUserID != "" {
		m, exists := rm.Members[rm.SharingUserID]
		if !exists || now.Sub(m.LastSeen) >= reservationTTL {
			if old, exists := s.store.s.Users[rm.SharingUserID]; exists {
				if err := s.updateSharePermission(id, old, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
					s.store.unlock()
					fail(w, 503, "media service is unavailable")
					return
				}
			}
			rm.SharingUserID = ""
		}
	}
	count := 0
	for uid, m := range rm.Members {
		if now.Sub(m.LastSeen) < reservationTTL {
			if x, exists := s.store.s.Users[uid]; exists && x.Enabled {
				count++
			} else {
				delete(rm.Members, uid)
			}
		} else {
			delete(rm.Members, uid)
		}
	}
	_, already := rm.Members[u.ID]
	if !already && count+pendingCallSeatsLocked(s.store.s, id, now) >= maxRoom {
		s.store.unlock()
		fail(w, 409, "room is full")
		return
	}
	rm.Members[u.ID] = Member{u.ID, now}
	participantCount := count
	if !already {
		participantCount++
	}
	s.store.s.Rooms[id] = rm
	participants := []participant{}
	for uid := range rm.Members {
		if member, ok := s.store.s.Users[uid]; ok && member.Enabled {
			participants = append(participants, participant{member.ID, member.Name, member.Email})
		}
	}
	e := s.store.save()
	s.store.unlock()
	if e != nil {
		fail(w, 500, "internal error")
		return
	}
	token, e := s.mediaToken(rm, u)
	if e != nil {
		fail(w, 500, "could not create media token")
		return
	}
	writeJSON(w, 200, map[string]any{"room": map[string]any{"id": rm.ID, "name": rm.Name, "participantCount": participantCount, "participants": participants}, "url": s.liveURL, "token": token, "participantIdentity": u.ID})
}
func (s *Server) mediaToken(rm Room, u User) (string, error) {
	now := time.Now()
	claims := map[string]any{"iss": s.liveKey, "sub": u.ID, "nbf": now.Unix() - 5, "iat": now.Unix(), "exp": now.Add(mediaTTL).Unix(), "name": u.Name, "roomConfig": map[string]any{"maxParticipants": maxRoom}, "video": map[string]any{"roomJoin": true, "room": rm.ID, "canPublish": true, "canSubscribe": true, "canPublishData": true, "canPublishSources": []string{"camera", "microphone"}}}
	b, e := json.Marshal(claims)
	if e != nil {
		return "", e
	}
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	body := head + "." + enc.EncodeToString(b)
	mac := hmac.New(sha256.New, []byte(s.liveSecret))
	_, _ = mac.Write([]byte(body))
	return body + "." + enc.EncodeToString(mac.Sum(nil)), nil
}

// Admin operation helpers are shared by the CLI and tests.
func (s *Store) CreateUser(name, email, password string, admin bool) (User, error) {
	name = strings.TrimSpace(name)
	email = strings.ToLower(strings.TrimSpace(email))
	if name == "" || len(name) > 100 || !strings.Contains(email, "@") || len(email) > 254 || len(password) < 12 {
		return User{}, errors.New("name, valid email, and password of at least 12 characters required")
	}
	hash, e := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if e != nil {
		return User{}, e
	}
	id, e := randomID(12)
	if e != nil {
		return User{}, e
	}
	u := User{id, name, email, string(hash), true, admin}
	s.lock()
	defer s.unlock()
	for _, x := range s.s.Users {
		if strings.EqualFold(x.Email, email) {
			return User{}, fmt.Errorf("email already exists")
		}
	}
	s.s.Users[id] = u
	if e = s.save(); e != nil {
		delete(s.s.Users, id)
		return User{}, e
	}
	return u, nil
}
func (s *Store) SetUserEnabled(email string, enabled bool) error {
	s.lock()
	defer s.unlock()
	for id, u := range s.s.Users {
		if strings.EqualFold(u.Email, email) {
			return s.setUserEnabledLocked(id, u, enabled, "system")
		}
	}
	return errors.New("user not found")
}

func (s *Store) ListUsers() []User {
	s.lock()
	defer s.unlock()
	users := make([]User, 0, len(s.s.Users))
	for _, user := range s.s.Users {
		users = append(users, user)
	}
	sort.Slice(users, func(i, j int) bool { return strings.ToLower(users[i].Email) < strings.ToLower(users[j].Email) })
	return users
}

func (s *Store) SetUserEnabledByID(id string, enabled bool, actorID string) error {
	s.lock()
	defer s.unlock()
	user, ok := s.s.Users[id]
	if !ok {
		return errors.New("user not found")
	}
	return s.setUserEnabledLocked(id, user, enabled, actorID)
}

func (s *Store) setUserEnabledLocked(id string, user User, enabled bool, actorID string) error {
	if user.Enabled == enabled {
		return nil
	}
	if !enabled && user.Admin {
		admins := 0
		for _, other := range s.s.Users {
			if other.Admin && other.Enabled {
				admins++
			}
		}
		if admins <= 1 {
			return errors.New("cannot disable the last enabled administrator")
		}
	}
	oldSessions := make(map[string]Session, len(s.s.Sessions))
	for token, session := range s.s.Sessions {
		oldSessions[token] = session
	}
	oldAudit := append([]AdminAuditEvent(nil), s.s.AdminAudit...)
	user.Enabled = enabled
	s.s.Users[id] = user
	if !enabled {
		for token, session := range s.s.Sessions {
			if session.UserID == id {
				delete(s.s.Sessions, token)
			}
		}
	}
	appendAdminAudit(&s.s, actorID, id, "account."+map[bool]string{true: "enabled", false: "disabled"}[enabled])
	if err := s.save(); err != nil {
		user.Enabled = !enabled
		s.s.Users[id] = user
		s.s.Sessions = oldSessions
		s.s.AdminAudit = oldAudit
		return err
	}
	return nil
}

func (s *Store) SetUserPasswordByID(id, password, actorID string) error {
	if len(password) < 12 || len(password) > 1024 {
		return errors.New("password must be between 12 and 1024 characters")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	s.lock()
	defer s.unlock()
	user, ok := s.s.Users[id]
	if !ok {
		return errors.New("user not found")
	}
	previousHash := user.PasswordHash
	previousAudit := append([]AdminAuditEvent(nil), s.s.AdminAudit...)
	previousSessions := make(map[string]Session, len(s.s.Sessions))
	for token, session := range s.s.Sessions {
		previousSessions[token] = session
	}
	user.PasswordHash = string(hash)
	s.s.Users[id] = user
	for token, session := range s.s.Sessions {
		if session.UserID == id {
			delete(s.s.Sessions, token)
		}
	}
	appendAdminAudit(&s.s, actorID, id, "account.password_reset")
	if err = s.save(); err != nil {
		user.PasswordHash = previousHash
		s.s.Users[id] = user
		s.s.Sessions = previousSessions
		s.s.AdminAudit = previousAudit
		return err
	}
	return nil
}

var _ = subtle.ConstantTimeCompare
