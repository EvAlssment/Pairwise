package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type countedBlockingSender struct {
	calls   atomic.Int32
	entered chan struct{}
	release chan struct{}
}

func (s *countedBlockingSender) Send(ctx context.Context, _ DeviceRegistration, _, _ string, _ time.Time) error {
	s.calls.Add(1)
	select {
	case s.entered <- struct{}{}:
	default:
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.release:
		return nil
	}
}

// This test uses a dedicated disposable PostgreSQL database. It is skipped in
// normal unit-test runs; CI should set PAIRDESK_TEST_DATABASE_URL to exercise
// two independent API stores and workers against the same database.
func TestPostgresConcurrentWorkersLeasePushOnce(t *testing.T) {
	dsn := os.Getenv("PAIRDESK_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PAIRDESK_TEST_DATABASE_URL to a disposable PostgreSQL database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	first, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()

	now := time.Now().UTC()
	state := emptyState()
	state.Users["target"] = User{ID: "target", Enabled: true}
	state.Devices[deviceKey("target", "phone")] = DeviceRegistration{UserID: "target", DeviceID: "phone", Platform: "android", PushToken: "test-token"}
	state.Calls["call"] = CallInvitation{ID: "call", CallerID: "caller", TargetID: "target", RoomID: "room", Status: callPending, ExpiresAt: now.Add(time.Minute)}
	state.PushJobs["job"] = PushJob{ID: "job", UserID: "target", DeviceID: "phone", Platform: "android", Event: "direct_call", CallID: "call", ExpiresAt: now.Add(time.Minute), NextAttemptAt: now}
	fixturePath := t.TempDir() + "/state.json"
	b, _ := json.Marshal(state)
	if err = os.WriteFile(fixturePath, b, 0600); err != nil {
		t.Fatal(err)
	}
	if err = first.ImportJSON(fixturePath); err != nil {
		t.Fatal(err)
	}

	startWrites := make(chan struct{})
	writeErrors := make(chan error, 2)
	for _, write := range []struct {
		store *Store
		id    string
	}{{first, "replica-a"}, {second, "replica-b"}} {
		write := write
		go func() {
			<-startWrites
			write.store.lock()
			write.store.s.Users[write.id] = User{ID: write.id, Enabled: true}
			err := write.store.save()
			if err != nil {
				delete(write.store.s.Users, write.id)
			}
			write.store.unlock()
			writeErrors <- err
		}()
	}
	close(startWrites)
	for range 2 {
		if err = <-writeErrors; err != nil {
			t.Fatal(err)
		}
	}
	first.lock()
	_, replicaAExists := first.s.Users["replica-a"]
	_, replicaBExists := first.s.Users["replica-b"]
	first.unlock()
	if !replicaAExists || !replicaBExists {
		t.Fatalf("concurrent replica writes were lost: replica-a=%v replica-b=%v", replicaAExists, replicaBExists)
	}

	sender := &countedBlockingSender{entered: make(chan struct{}, 2), release: make(chan struct{})}
	worker1 := &Server{store: first}
	worker2 := &Server{store: second}
	done1 := make(chan struct{})
	go func() { defer close(done1); worker1.deliverPushJobsWithSender(ctx, sender) }()
	select {
	case <-sender.entered:
	case <-ctx.Done():
		t.Fatal("first worker did not claim the job")
	}
	done2 := make(chan struct{})
	go func() { defer close(done2); worker2.deliverPushJobsWithSender(ctx, sender) }()
	select {
	case <-done2:
	case <-ctx.Done():
		t.Fatal("second worker did not finish")
	}
	close(sender.release)
	select {
	case <-done1:
	case <-ctx.Done():
		t.Fatal("first worker did not finish")
	}
	if got := sender.calls.Load(); got != 1 {
		t.Fatalf("provider called %d times; want exactly once while lease is active", got)
	}
	first.lock()
	remaining := len(first.s.PushJobs)
	first.unlock()
	if remaining != 0 {
		t.Fatalf("completed outbox job remains: %d", remaining)
	}
}

func TestPostgresTwoAPIsShareAuthPresenceCallsAndReplayOutbox(t *testing.T) {
	dsn := os.Getenv("PAIRDESK_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PAIRDESK_TEST_DATABASE_URL to a disposable PostgreSQL database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	firstStore, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer firstStore.Close()
	secondStore, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer secondStore.Close()

	livekit := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/twirp/livekit.RoomService/") || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/ListRooms") {
			_, _ = w.Write([]byte(`{"rooms":[]}`))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer livekit.Close()

	apiFor := func(store *Store) *Server {
		api := New(store)
		// Provide an enabled no-op sender so call creation enqueues a durable job
		// without requiring APNs or FCM credentials in the integration suite.
		api.push = &configuredPushSender{}
		api.liveURL = "wss://media.example.test"
		api.liveKey = "test-key"
		api.liveSecret = "test-secret"
		api.liveAPIURL = livekit.URL
		return api
	}
	firstAPI := apiFor(firstStore)
	secondAPI := apiFor(secondStore)

	resetPath := t.TempDir() + "/empty.json"
	if err = os.WriteFile(resetPath, []byte(`{"users":{},"sessions":{},"rooms":{},"presence":{},"calls":{}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err = firstStore.ImportJSON(resetPath); err != nil {
		t.Fatal(err)
	}
	caller, err := firstStore.CreateUser("Caller", "caller@integration.test", "long-integration-password", false)
	if err != nil {
		t.Fatal(err)
	}
	target, err := firstStore.CreateUser("Target", "target@integration.test", "another-integration-password", false)
	if err != nil {
		t.Fatal(err)
	}
	callerTwo, err := firstStore.CreateUser("Second Caller", "caller-two@integration.test", "second-integration-password", false)
	if err != nil {
		t.Fatal(err)
	}
	loginToken := func(api *Server, email, password string) string {
		t.Helper()
		response := request(api.Handler(), http.MethodPost, "/v1/login", "", `{"email":"`+email+`","password":"`+password+`"}`)
		if response.Code != http.StatusOK {
			t.Fatalf("login through API instance failed: status=%d body=%s", response.Code, response.Body)
		}
		var result struct {
			Token string `json:"token"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || result.Token == "" {
			t.Fatalf("login response did not contain a session token: %v", err)
		}
		return result.Token
	}
	callerToken := loginToken(firstAPI, caller.Email, "long-integration-password")
	callerTwoToken := loginToken(secondAPI, callerTwo.Email, "second-integration-password")
	targetToken := loginToken(secondAPI, target.Email, "another-integration-password")
	if response := request(secondAPI.Handler(), http.MethodPost, "/v1/devices", targetToken,
		`{"deviceId":"test-phone","platform":"android","pushToken":"fake-token"}`); response.Code != http.StatusOK {
		t.Fatalf("register push device through second API: %d %s", response.Code, response.Body)
	}
	if response := request(secondAPI.Handler(), http.MethodPost, "/v1/heartbeat", targetToken, ""); response.Code != http.StatusOK {
		t.Fatalf("update presence through second API: %d %s", response.Code, response.Body)
	}
	if response := request(firstAPI.Handler(), http.MethodGet, "/v1/me", targetToken, ""); response.Code != http.StatusOK {
		t.Fatalf("session created on one API was not accepted by the other: %d %s", response.Code, response.Body)
	}
	if response := request(firstAPI.Handler(), http.MethodGet, "/v1/users", callerToken, ""); response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"online":true`) {
		t.Fatalf("presence written through second API was not visible through first: %d %s", response.Code, response.Body)
	}
	callResponses := make(chan *httptest.ResponseRecorder, 2)
	for _, attempt := range []struct {
		api   *Server
		token string
	}{{firstAPI, callerToken}, {secondAPI, callerTwoToken}} {
		attempt := attempt
		go func() {
			callResponses <- request(attempt.api.Handler(), http.MethodPost, "/v1/calls", attempt.token, `{"userId":"`+target.ID+`"}`)
		}()
	}
	var created *httptest.ResponseRecorder
	createdCount, conflictCount := 0, 0
	for range 2 {
		response := <-callResponses
		switch response.Code {
		case http.StatusCreated:
			createdCount++
			created = response
		case http.StatusConflict:
			conflictCount++
		default:
			t.Fatalf("concurrent call request returned %d: %s", response.Code, response.Body)
		}
	}
	if createdCount != 1 || conflictCount != 1 {
		t.Fatalf("concurrent replicas created %d calls and rejected %d; want one call and one busy response", createdCount, conflictCount)
	}
	var createdResult struct {
		Call apiCall `json:"call"`
	}
	if err = json.Unmarshal(created.Body.Bytes(), &createdResult); err != nil || createdResult.Call.ID == "" {
		t.Fatalf("call creation returned no call: %v", err)
	}
	seen := request(secondAPI.Handler(), http.MethodGet, "/v1/calls", targetToken, "")
	var seenResult struct {
		Calls []apiCall `json:"calls"`
	}
	if err = json.Unmarshal(seen.Body.Bytes(), &seenResult); err != nil || seen.Code != http.StatusOK ||
		len(seenResult.Calls) != 1 || seenResult.Calls[0].ID != createdResult.Call.ID {
		t.Fatalf("call written through first API was not visible through second: %d %s", seen.Code, seen.Body)
	}

	firstStore.lock()
	duplicates := firstAPI.enqueuePushJobsLocked([]string{target.ID}, "direct_call", createdResult.Call.ID, "", time.Now().Add(time.Minute))
	firstStore.unlock()
	if len(duplicates) != 0 {
		t.Fatalf("duplicate outbox enqueue created %d additional jobs", len(duplicates))
	}

	// A fresh API/store pair simulates a process restart before outbox delivery.
	restartedStore, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer restartedStore.Close()
	restartedAPI := apiFor(restartedStore)
	if response := request(restartedAPI.Handler(), http.MethodGet, "/v1/calls", targetToken, ""); response.Code != http.StatusOK || !strings.Contains(response.Body.String(), createdResult.Call.ID) {
		t.Fatalf("restarted API could not read the persisted call/session: %d %s", response.Code, response.Body)
	}
	attempts := 0
	restartedAPI.deliverPushJobsWithSender(ctx, retryPushSender{attempts: &attempts, failUntil: 1})
	if attempts != 1 {
		t.Fatalf("first outbox attempt count = %d, want 1", attempts)
	}
	restartedStore.lock()
	var retryAt time.Time
	for _, job := range restartedStore.s.PushJobs {
		if job.CallID == createdResult.Call.ID {
			if job.Attempts != 1 || !job.NextAttemptAt.After(time.Now()) {
				restartedStore.unlock()
				t.Fatalf("retry state was not persisted: attempts=%d nextAttemptAt=%s", job.Attempts, job.NextAttemptAt)
			}
			retryAt = job.NextAttemptAt
		}
	}
	restartedStore.unlock()
	if retryAt.IsZero() {
		t.Fatal("failed delivery removed the durable outbox job")
	}

	// A new API/store instance after the failed attempt must replay the job
	// when its persisted retry time becomes due.
	retryStore, err := OpenPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer retryStore.Close()
	retryAPI := apiFor(retryStore)
	if wait := time.Until(retryAt); wait > 0 {
		timer := time.NewTimer(wait + 10*time.Millisecond)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			t.Fatal("timed out waiting for persisted outbox retry")
		}
	}
	retryAPI.deliverPushJobsWithSender(ctx, retryPushSender{attempts: &attempts, failUntil: 1})
	if attempts != 2 {
		t.Fatalf("replayed outbox attempt count = %d, want 2", attempts)
	}
	retryAPI.deliverPushJobsWithSender(ctx, retryPushSender{attempts: &attempts, failUntil: 1})
	if attempts != 2 {
		t.Fatalf("completed outbox job replayed again: attempts=%d", attempts)
	}
}
