package app

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSharedStorageFailureReturnsSanitizedServiceUnavailable(t *testing.T) {
	handler := recoverStorage(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic(storageError{errors.New("postgres connection string contains private details")})
	}))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/me", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", response.Code)
	}
	if strings.Contains(response.Body.String(), "private details") || strings.Contains(response.Body.String(), "postgres") {
		t.Fatalf("storage error leaked to client: %s", response.Body.String())
	}
}

func fixture(t *testing.T) (*Server, User) {
	t.Helper()
	lk := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/twirp/livekit.RoomService/") || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			http.Error(w, "unauthorized", 401)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/CreateRoom") {
			var q map[string]any
			_ = json.NewDecoder(r.Body).Decode(&q)
			if q["maxParticipants"] != float64(4) {
				http.Error(w, "missing room cap", 400)
				return
			}
		}
		if strings.HasSuffix(r.URL.Path, "/ListRooms") {
			var q struct {
				Names []string `json:"names"`
			}
			_ = json.NewDecoder(r.Body).Decode(&q)
			rooms := []map[string]string{}
			for _, name := range q.Names {
				rooms = append(rooms, map[string]string{"name": name})
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"rooms": rooms})
			return
		}
		if strings.HasSuffix(r.URL.Path, "/UpdateParticipant") {
			var q struct {
				Permission struct {
					CanPublishData    bool  `json:"canPublishData"`
					CanPublishSources []int `json:"canPublishSources"`
				} `json:"permission"`
			}
			if err := json.NewDecoder(r.Body).Decode(&q); err != nil || !q.Permission.CanPublishData {
				http.Error(w, "data permission missing", 400)
				return
			}
			for _, source := range q.Permission.CanPublishSources {
				if source != 1 && source != 2 && source != 3 {
					http.Error(w, "forbidden media source", 400)
					return
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(lk.Close)
	st, e := OpenStore(t.TempDir() + "/state.json")
	if e != nil {
		t.Fatal(e)
	}
	u, e := st.CreateUser("A User", "a@example.com", "correct-horse-battery", false)
	if e != nil {
		t.Fatal(e)
	}
	s := New(st)
	s.liveURL = "ws://localhost:7880"
	s.liveKey = "devkey"
	s.liveSecret = "devsecret"
	s.liveAPIURL = lk.URL
	return s, u
}
func request(h http.Handler, method, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func login(t *testing.T, s *Server) string {
	t.Helper()
	w := request(s.Handler(), "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`)
	if w.Code != 200 {
		t.Fatalf("login status %d: %s", w.Code, w.Body)
	}
	var x struct {
		Token string `json:"token"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &x); e != nil {
		t.Fatal(e)
	}
	return x.Token
}

func TestHealthAndReadinessDistinguishLivenessFromMediaDependency(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	if w := request(h, "GET", "/healthz", "", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"ok":true`) {
		t.Fatalf("liveness failed: %d %s", w.Code, w.Body)
	}
	if w := request(h, "GET", "/readyz", "", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"media":true`) {
		t.Fatalf("readiness failed: %d %s", w.Code, w.Body)
	}
	s.liveSecret = ""
	if w := request(h, "GET", "/readyz", "", ""); w.Code != 503 || strings.Contains(w.Body.String(), "secret") {
		t.Fatalf("unavailable media dependency was not reported safely: %d %s", w.Code, w.Body)
	}
}

func TestVersionEndpointExposesOnlySafeBuildMetadata(t *testing.T) {
	s, _ := fixture(t)
	w := request(s.Handler(), http.MethodGet, "/version", "", "")
	if w.Code != http.StatusOK {
		t.Fatalf("version endpoint: %d %s", w.Code, w.Body)
	}
	var got map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["service"] != "pairdesk-api" || got["apiProtocol"] != "v1" || got["buildCommit"] != buildCommit {
		t.Fatalf("incomplete build metadata: %#v", got)
	}
	if len(got) != 3 || strings.Contains(w.Body.String(), "secret") || strings.Contains(w.Body.String(), "token") {
		t.Fatalf("version endpoint exposed unexpected data: %s", w.Body)
	}
	for _, invalid := range []string{"contains-separators", "deadbeef\nsecret", strings.Repeat("a", 41)} {
		if safeBuildCommit(invalid) != "unknown" {
			t.Fatalf("unsafe build identifier %q was not removed", invalid)
		}
	}
	if safeBuildCommit("0123456789abcdef") != "0123456789abcdef" || safeBuildCommit("unknown") != "unknown" {
		t.Fatal("valid build identifier was not preserved")
	}
	if w := request(s.Handler(), http.MethodPost, "/version", "", ""); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("version endpoint accepted a write: %d", w.Code)
	}
}

func TestAuthLoginAndDisabledOffboarding(t *testing.T) {
	s, u := fixture(t)
	h := s.Handler()
	if w := request(h, "POST", "/v1/login", "", `{"email":"missing@example.com","password":"anything"}`); w.Code != 401 {
		t.Fatalf("unknown login: %d", w.Code)
	}
	tok := login(t, s)
	if w := request(h, "GET", "/v1/me", tok, ""); w.Code != 200 {
		t.Fatalf("me: %d", w.Code)
	}
	if w := request(h, "GET", "/v1/me", "", " "); w.Code != 401 {
		t.Fatalf("anonymous: %d", w.Code)
	}
	if e := s.store.SetUserEnabled(u.Email, false); e != nil {
		t.Fatal(e)
	}
	if w := request(h, "GET", "/v1/me", tok, ""); w.Code != 401 {
		t.Fatalf("disabled session: %d", w.Code)
	}
	if w := request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`); w.Code != 401 {
		t.Fatalf("disabled login: %d", w.Code)
	}
}
func TestPasswordChangeAndLogout(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	old := login(t, s)
	if w := request(h, "POST", "/v1/password", old, `{"currentPassword":"wrong-password","newPassword":"a-new-long-password"}`); w.Code != 401 {
		t.Fatalf("bad current password: %d", w.Code)
	}
	if w := request(h, "POST", "/v1/password", old, `{"currentPassword":"correct-horse-battery","newPassword":"a-new-long-password"}`); w.Code != 200 {
		t.Fatalf("change password: %d %s", w.Code, w.Body)
	}
	if w := request(h, "GET", "/v1/me", old, ""); w.Code != 200 {
		t.Fatalf("current session should survive: %d", w.Code)
	}
	if w := request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`); w.Code != 401 {
		t.Fatalf("old password accepted: %d", w.Code)
	}
	if w := request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"a-new-long-password"}`); w.Code != 200 {
		t.Fatalf("new password rejected: %d", w.Code)
	}
	if w := request(h, "POST", "/v1/logout", old, ""); w.Code != 200 {
		t.Fatalf("logout: %d", w.Code)
	}
	if w := request(h, "GET", "/v1/me", old, ""); w.Code != 401 {
		t.Fatalf("logged out session accepted: %d", w.Code)
	}
}

func TestLogoutRemovesMobilePushRegistration(t *testing.T) {
	s, u := fixture(t)
	h := s.Handler()
	token := login(t, s)
	if w := request(h, "POST", "/v1/devices", token, `{"deviceId":"phone","platform":"android","pushToken":"push-secret"}`); w.Code != http.StatusOK {
		t.Fatalf("register device: %d %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/logout", token, `{"deviceId":"phone"}`); w.Code != http.StatusOK {
		t.Fatalf("logout: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	_, deviceExists := s.store.s.Devices[deviceKey(u.ID, "phone")]
	s.store.unlock()
	if deviceExists {
		t.Fatal("logout left a push registration for the signed-out installation")
	}
	if w := request(h, "GET", "/v1/me", token, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("logged-out session accepted: %d", w.Code)
	}
}

func TestAdminCreatesInvitedUserAndPublicPayloadOmitsSecrets(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	regularToken := login(t, s)
	if w := request(h, "POST", "/v1/admin/users", regularToken, `{"name":"New Member","email":"new@example.com","password":"long-enough-password"}`); w.Code != 403 {
		t.Fatalf("non-admin create status %d: %s", w.Code, w.Body)
	}
	admin, err := s.store.CreateUser("Admin", "admin@example.com", "correct-horse-battery", true)
	if err != nil {
		t.Fatal(err)
	}
	adminToken, _ := randomID(32)
	s.store.lock()
	s.store.s.Sessions[adminToken] = Session{admin.ID, time.Now().Add(time.Hour)}
	_ = s.store.save()
	s.store.unlock()
	w := request(h, "POST", "/v1/admin/users", adminToken, `{"name":"New Member","email":"new@example.com","password":"long-enough-password"}`)
	if w.Code != 201 {
		t.Fatalf("admin create status %d: %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "passwordHash") || strings.Contains(w.Body.String(), "long-enough-password") {
		t.Fatalf("sensitive user data exposed: %s", w.Body)
	}
	if w = request(h, "POST", "/v1/login", "", `{"email":"new@example.com","password":"long-enough-password"}`); w.Code != 200 {
		t.Fatalf("new member cannot sign in: %d %s", w.Code, w.Body)
	}
	if w = request(h, "GET", "/v1/me", adminToken, ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"admin":true`) {
		t.Fatalf("admin role not exposed on me: %d %s", w.Code, w.Body)
	}
}

func TestSelfServiceSignupCreatesNormalAccountAndSession(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	s.signupEnabled = true
	s.signupAllowedDomains = nil
	w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"New.Person@example.com","password":"a-strong-password"}`)
	if w.Code != http.StatusCreated {
		t.Fatalf("signup status %d: %s", w.Code, w.Body)
	}
	var response struct {
		Token string  `json:"token"`
		User  apiUser `json:"user"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Token == "" || response.User.Email != "new.person@example.com" || response.User.Admin || !response.User.Enabled {
		t.Fatalf("unexpected signup response: %+v", response)
	}
	if w := request(h, "GET", "/v1/me", response.Token, ""); w.Code != http.StatusOK {
		t.Fatalf("signup session not authenticated: %d %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/login", "", `{"email":"new.person@example.com","password":"a-strong-password"}`); w.Code != http.StatusOK {
		t.Fatalf("new account cannot sign in: %d %s", w.Code, w.Body)
	}
}

func TestSignupPolicyAndValidation(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	s.signupEnabled = false
	if w := request(h, "GET", "/v1/signup-policy", "", ""); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Fatalf("signup policy response: %d %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"new@example.com","password":"a-strong-password"}`); w.Code != http.StatusForbidden {
		t.Fatalf("disabled signup status %d", w.Code)
	}
	s.signupEnabled = true
	s.signupAllowedDomains = map[string]struct{}{"example.com": {}}
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"new@other.com","password":"a-strong-password"}`); w.Code != http.StatusForbidden {
		t.Fatalf("disallowed email domain status %d: %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"new@example.com","password":"short"}`); w.Code != http.StatusBadRequest {
		t.Fatalf("short password status %d: %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"new@example.com","password":"a-strong-password"}`); w.Code != http.StatusCreated {
		t.Fatalf("allowed email signup status %d: %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New Teammate","email":"new@example.com","password":"a-strong-password"}`); w.Code != http.StatusConflict {
		t.Fatalf("duplicate signup status %d: %s", w.Code, w.Body)
	}
}

func TestAdminCanListResetAndDisableUsersWithoutExposingCredentialData(t *testing.T) {
	s, member := fixture(t)
	h := s.Handler()
	memberToken := login(t, s)
	if w := request(h, "GET", "/v1/admin/users", memberToken, ""); w.Code != 403 {
		t.Fatalf("non-admin list status %d", w.Code)
	}
	admin, err := s.store.CreateUser("Admin", "admin@example.com", "correct-horse-battery", true)
	if err != nil {
		t.Fatal(err)
	}
	adminToken, _ := randomID(32)
	s.store.lock()
	s.store.s.Sessions[adminToken] = Session{admin.ID, time.Now().Add(time.Hour)}
	_ = s.store.save()
	s.store.unlock()
	w := request(h, "GET", "/v1/admin/users", adminToken, "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "passwordHash") || strings.Contains(w.Body.String(), "correct-horse-battery") {
		t.Fatalf("admin list leaked credentials or failed: %d %s", w.Code, w.Body)
	}
	if w = request(h, "GET", "/v1/admin/audit", memberToken, ""); w.Code != 403 {
		t.Fatalf("non-admin audit status %d", w.Code)
	}
	if w = request(h, "POST", "/v1/admin/users/"+member.ID+"/password", adminToken, `{"newPassword":"new-member-password"}`); w.Code != 200 {
		t.Fatalf("admin reset password: %d %s", w.Code, w.Body)
	}
	w = request(h, "GET", "/v1/admin/audit", adminToken, "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"action":"account.password_reset"`) ||
		!strings.Contains(w.Body.String(), `"actorId":"`+admin.ID+`"`) ||
		!strings.Contains(w.Body.String(), `"targetId":"`+member.ID+`"`) ||
		strings.Contains(w.Body.String(), "new-member-password") || strings.Contains(w.Body.String(), "passwordHash") {
		t.Fatalf("admin audit missing safe password-reset event: %d %s", w.Code, w.Body)
	}
	reopened, err := OpenStore(s.store.path)
	if err != nil || len(reopened.ListAdminAudit()) != 1 || reopened.ListAdminAudit()[0].Action != "account.password_reset" {
		t.Fatalf("admin audit did not persist safely: %v %+v", err, reopened.ListAdminAudit())
	}
	if w = request(h, "GET", "/v1/me", memberToken, ""); w.Code != 401 {
		t.Fatalf("reset should revoke prior member sessions: %d", w.Code)
	}
	if w = request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"new-member-password"}`); w.Code != 200 {
		t.Fatalf("new member password rejected: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/admin/users/"+member.ID+"/enabled", adminToken, `{"enabled":false}`); w.Code != 200 {
		t.Fatalf("disable member: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"new-member-password"}`); w.Code != 401 {
		t.Fatalf("disabled member signed in: %d", w.Code)
	}
	if err := s.store.SetUserEnabled(admin.Email, false); err == nil {
		t.Fatal("last enabled administrator was disabled")
	}
}

func TestAdminDisableImmediatelyRemovesExistingLiveKitParticipant(t *testing.T) {
	s, member := fixture(t)
	memberToken := login(t, s)
	admin, err := s.store.CreateUser("Admin", "admin@example.com", "correct-horse-battery", true)
	if err != nil {
		t.Fatal(err)
	}
	adminToken, _ := randomID(32)
	s.store.lock()
	s.store.s.Sessions[adminToken] = Session{admin.ID, time.Now().Add(time.Hour)}
	s.store.s.Rooms["active-room"] = Room{
		ID: "active-room", Members: map[string]Member{
			member.ID: {UserID: member.ID, LastSeen: time.Now().UTC()},
		},
	}
	if err := s.store.save(); err != nil {
		s.store.unlock()
		t.Fatal(err)
	}
	s.store.unlock()

	var removedRoom, removedIdentity string
	mediaStatus := http.StatusServiceUnavailable
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/RemoveParticipant") || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			http.Error(w, "unexpected media request", http.StatusBadRequest)
			return
		}
		var request struct {
			Room     string `json:"room"`
			Identity string `json:"identity"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		removedRoom, removedIdentity = request.Room, request.Identity
		w.WriteHeader(mediaStatus)
	}))
	defer media.Close()
	s.liveAPIURL = media.URL

	w := request(s.Handler(), "POST", "/v1/admin/users/"+member.ID+"/enabled", adminToken, `{"enabled":false}`)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("media outage should report incomplete revocation: %d %s", w.Code, w.Body)
	}
	if removedRoom != "active-room" || removedIdentity != member.ID {
		t.Fatalf("failed revocation did not target active participant: room=%q identity=%q", removedRoom, removedIdentity)
	}
	mediaStatus = http.StatusOK
	w = request(s.Handler(), "POST", "/v1/admin/users/"+member.ID+"/enabled", adminToken, `{"enabled":false}`)
	if w.Code != http.StatusOK {
		t.Fatalf("disable status %d: %s", w.Code, w.Body)
	}
	if removedRoom != "active-room" || removedIdentity != member.ID {
		t.Fatalf("live media participant not removed: room=%q identity=%q", removedRoom, removedIdentity)
	}
	if w = request(s.Handler(), "GET", "/v1/me", memberToken, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("disabled account retained API access: %d", w.Code)
	}
}

func TestLoginRateLimitCountsOnlyFailures(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	for i := 0; i < 15; i++ {
		if w := request(h, "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`); w.Code != 200 {
			t.Fatalf("successful shared-IP login %d: %d %s", i, w.Code, w.Body)
		}
	}
	s2, _ := fixture(t)
	h2 := s2.Handler()
	for i := 0; i < 10; i++ {
		if w := request(h2, "POST", "/v1/login", "", `{"email":"a@example.com","password":"wrong-password"}`); w.Code != 401 {
			t.Fatalf("failed login %d: %d", i, w.Code)
		}
	}
	if w := request(h2, "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`); w.Code != 429 {
		t.Fatalf("rate limit after failures: %d", w.Code)
	}
}
func TestRoomReservationCapAndMediaToken(t *testing.T) {
	s, owner := fixture(t)
	h := s.Handler()
	tokens := []string{login(t, s)}
	users := []User{owner}
	for i := 1; i < 5; i++ {
		u, e := s.store.CreateUser("Other", "other"+string(rune('0'+i))+"@example.com", "correct-horse-battery", false)
		if e != nil {
			t.Fatal(e)
		}
		users = append(users, u)
		tokens = append(tokens, "")
	}
	for i := range users {
		if i > 0 {
			tokens[i], _ = randomID(32)
			s.store.lock()
			s.store.s.Sessions[tokens[i]] = Session{users[i].ID, time.Now().Add(time.Hour)}
			_ = s.store.save()
			s.store.unlock()
		}
	}
	w := request(h, "POST", "/v1/rooms", tokens[0], `{"name":"Design"}`)
	if w.Code != 201 {
		t.Fatalf("create room %d %s", w.Code, w.Body)
	}
	var x struct {
		Room struct {
			ID string `json:"id"`
		} `json:"room"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &x)
	for i := 0; i < 4; i++ {
		w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", tokens[i], "")
		if w.Code != 200 {
			t.Fatalf("join %d: %d %s", i, w.Code, w.Body)
		}
		var resp struct {
			Token string `json:"token"`
			Room  struct {
				ParticipantCount int           `json:"participantCount"`
				Participants     []participant `json:"participants"`
			} `json:"room"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &resp)
		if resp.Room.ParticipantCount != i+1 || len(resp.Room.Participants) != i+1 {
			t.Fatalf("join response must include a consistent participant list for the native client: %#v", resp.Room)
		}
		claims := strings.Split(resp.Token, ".")
		b, _ := base64.RawURLEncoding.DecodeString(claims[1])
		var c map[string]any
		if e := json.Unmarshal(b, &c); e != nil {
			t.Fatal(e)
		}
		video := c["video"].(map[string]any)
		if video["canPublishSources"] == nil {
			t.Fatal("missing allowed media sources")
		}
		sources, ok := video["canPublishSources"].([]any)
		if !ok {
			t.Fatal("invalid source claim")
		}
		if len(sources) != 2 || sources[0] != "camera" || sources[1] != "microphone" {
			t.Fatalf("join sources must allow camera and microphone only: %#v", sources)
		}
		if video["canPublishData"] != true {
			t.Fatal("authenticated participant must be allowed to publish remote-control data")
		}
		if c["roomConfig"].(map[string]any)["maxParticipants"] != float64(4) {
			t.Fatal("token lacks hard media room cap")
		}
	}
	w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", tokens[0], "")
	var rejoin struct {
		Room struct {
			ParticipantCount int `json:"participantCount"`
		} `json:"room"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &rejoin) != nil || rejoin.Room.ParticipantCount != 4 {
		t.Fatalf("same user rejoin should preserve count 4: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", tokens[4], ""); w.Code != 409 {
		t.Fatalf("fifth join status %d: %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/leave", tokens[0], ""); w.Code != 200 {
		t.Fatalf("leave: %d", w.Code)
	}
	if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", tokens[4], ""); w.Code != 200 {
		t.Fatalf("join after leave: %d %s", w.Code, w.Body)
	}
}
func TestHeartbeatAndSignupEndpoint(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	s.signupEnabled = true
	if w := request(h, "POST", "/v1/signup", "", `{"email":"new@example.com"}`); w.Code != http.StatusBadRequest {
		t.Fatalf("invalid signup should be rejected: %d", w.Code)
	}
	tok := login(t, s)
	if w := request(h, "POST", "/v1/heartbeat", tok, `{}`); w.Code != 200 {
		t.Fatalf("heartbeat: %d", w.Code)
	}
	w := request(h, "GET", "/v1/users", tok, "")
	if !strings.Contains(w.Body.String(), `"online":true`) {
		t.Fatalf("presence missing: %s", w.Body)
	}
}

func TestScreenShareClaimExclusiveAndReleasable(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	ownerToken := login(t, s)
	other, e := s.store.CreateUser("Other", "other@example.com", "correct-horse-battery", false)
	if e != nil {
		t.Fatal(e)
	}
	otherToken, _ := randomID(32)
	s.store.lock()
	s.store.s.Sessions[otherToken] = Session{other.ID, time.Now().Add(time.Hour)}
	_ = s.store.save()
	s.store.unlock()
	w := request(h, "POST", "/v1/rooms", ownerToken, `{"name":"Pair"}`)
	if w.Code != 201 {
		t.Fatalf("create room: %d %s", w.Code, w.Body)
	}
	var res struct {
		Room struct {
			ID string `json:"id"`
		} `json:"room"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &res)
	for _, tok := range []string{ownerToken, otherToken} {
		if w = request(h, "POST", "/v1/rooms/"+res.Room.ID+"/join", tok, ""); w.Code != 200 {
			t.Fatalf("join: %d %s", w.Code, w.Body)
		}
	}
	if w = request(h, "POST", "/v1/rooms/"+res.Room.ID+"/share", ownerToken, `{"enabled":true}`); w.Code != 204 {
		t.Fatalf("claim: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+res.Room.ID+"/share", otherToken, `{"enabled":true}`); w.Code != 409 {
		t.Fatalf("second claim: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+res.Room.ID+"/leave", ownerToken, ""); w.Code != 200 {
		t.Fatalf("leave: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+res.Room.ID+"/share", otherToken, `{"enabled":true}`); w.Code != 204 {
		t.Fatalf("claim after leave: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	holder := s.store.s.Rooms[res.Room.ID].SharingUserID
	s.store.unlock()
	if holder != other.ID {
		t.Fatalf("unexpected holder %q", holder)
	}
}

func TestConcurrentShareClaimOnlyOneWins(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	ownerToken := login(t, s)
	other, e := s.store.CreateUser("Other", "other@example.com", "correct-horse-battery", false)
	if e != nil {
		t.Fatal(e)
	}
	otherToken, _ := randomID(32)
	s.store.lock()
	s.store.s.Sessions[otherToken] = Session{other.ID, time.Now().Add(time.Hour)}
	_ = s.store.save()
	s.store.unlock()
	w := request(h, "POST", "/v1/rooms", ownerToken, `{"name":"Pair"}`)
	if w.Code != 201 {
		t.Fatal(w.Code)
	}
	var x struct {
		Room struct {
			ID string `json:"id"`
		} `json:"room"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &x)
	for _, tok := range []string{ownerToken, otherToken} {
		if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", tok, ""); w.Code != 200 {
			t.Fatal(w.Code)
		}
	}
	results := make(chan int, 2)
	var wg sync.WaitGroup
	for _, tok := range []string{ownerToken, otherToken} {
		wg.Add(1)
		go func(tok string) {
			defer wg.Done()
			results <- request(h, "POST", "/v1/rooms/"+x.Room.ID+"/share", tok, `{"enabled":true}`).Code
		}(tok)
	}
	wg.Wait()
	close(results)
	wins := 0
	for status := range results {
		if status == 204 {
			wins++
		} else if status != 409 {
			t.Fatalf("unexpected concurrent claim status %d", status)
		}
	}
	if wins != 1 {
		t.Fatalf("expected one sharer, got %d winners", wins)
	}
}

func TestShareClaimRollsBackWhenLiveKitUnavailable(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	token := login(t, s)
	w := request(h, "POST", "/v1/rooms", token, `{"name":"Pair"}`)
	if w.Code != 201 {
		t.Fatalf("create room: %d %s", w.Code, w.Body)
	}
	var x struct {
		Room struct {
			ID string `json:"id"`
		} `json:"room"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &x)
	if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/join", token, ""); w.Code != 200 {
		t.Fatalf("join: %d %s", w.Code, w.Body)
	}
	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "unavailable", 503) }))
	defer failing.Close()
	s.liveAPIURL = failing.URL
	if w = request(h, "POST", "/v1/rooms/"+x.Room.ID+"/share", token, `{"enabled":true}`); w.Code != 503 {
		t.Fatalf("expected media failure 503, got %d %s", w.Code, w.Body)
	}
	s.store.lock()
	holder := s.store.s.Rooms[x.Room.ID].SharingUserID
	s.store.unlock()
	if holder != "" {
		t.Fatalf("claim persisted while media service failed: %q", holder)
	}
}

func TestLiveKitRoomCreationIntegration(t *testing.T) {
	if os.Getenv("PAIRDESK_LIVEKIT_INTEGRATION") != "1" {
		t.Skip("set PAIRDESK_LIVEKIT_INTEGRATION=1 to test against a local LiveKit server")
	}
	st, err := OpenStore(t.TempDir() + "/state.json")
	if err != nil {
		t.Fatal(err)
	}
	s := New(st)
	s.liveAPIURL = os.Getenv("LIVEKIT_API_URL")
	s.liveKey = os.Getenv("LIVEKIT_API_KEY")
	s.liveSecret = os.Getenv("LIVEKIT_API_SECRET")
	if s.liveAPIURL == "" || s.liveKey == "" || s.liveSecret == "" {
		t.Fatal("LiveKit integration env is incomplete")
	}
	id := "pairdesk-integration-" + strings.ToLower(strings.ReplaceAll(time.Now().Format("150405.000000000"), ".", ""))
	if err = s.createMediaRoom(id); err != nil {
		t.Fatalf("CreateRoom: %v", err)
	}
	if err = s.ensureMediaRoom(id); err != nil {
		t.Fatalf("ListRooms recheck: %v", err)
	}
	defer func() { _, _ = s.livekitCall("DeleteRoom", map[string]any{"room": id}) }()
	status, body, err := s.livekitCallResult("ListRooms", map[string]any{"names": []string{id}})
	if err != nil || status < 200 || status >= 300 {
		t.Fatalf("ListRooms status %d err %v", status, err)
	}
	var result struct {
		Rooms []struct {
			Name            string `json:"name"`
			MaxParticipants uint32 `json:"max_participants"`
		} `json:"rooms"`
	}
	if err = json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Rooms) != 1 || result.Rooms[0].Name != id || result.Rooms[0].MaxParticipants != maxRoom {
		actual := uint32(0)
		if len(result.Rooms) > 0 {
			actual = result.Rooms[0].MaxParticipants
		}
		t.Fatalf("LiveKit returned unexpected room cap (want %d, got %d)", maxRoom, actual)
	}
}
