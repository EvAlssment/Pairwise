package app

import (
	"context"
	"encoding/json"
	"os"
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
