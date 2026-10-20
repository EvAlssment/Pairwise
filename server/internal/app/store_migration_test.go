package app

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestStoreImportExportPreservesIdentityAndPendingState(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "legacy.json")
	output := filepath.Join(dir, "export", "pairdesk.json")
	want := emptyState()
	want.Users["u1"] = User{ID: "u1", Name: "Existing User", Email: "existing@example.test", PasswordHash: "bcrypt-hash", Enabled: true}
	want.Sessions["session"] = Session{UserID: "u1", ExpiresAt: time.Now().UTC().Add(time.Hour)}
	want.Devices[deviceKey("u1", "phone")] = DeviceRegistration{UserID: "u1", DeviceID: "phone", Platform: "ios", PushToken: "opaque-token"}
	want.AdminAudit = []AdminAuditEvent{{ActorID: "admin", TargetID: "u1", Action: "created", OccurredAt: time.Now().UTC()}}
	want.PushJobs["pending"] = PushJob{ID: "pending", UserID: "u1", DeviceID: "phone", Platform: "ios", Event: "direct_call", CallID: "call", ExpiresAt: time.Now().UTC().Add(time.Minute), NextAttemptAt: time.Now().UTC()}
	b, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(input, b, 0600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(filepath.Join(dir, "source", "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = store.ImportJSON(input); err != nil {
		t.Fatal(err)
	}
	if err = store.ExportJSON(output); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(output)
	if err != nil {
		t.Fatal(err)
	}
	reopened.lock()
	got := reopened.s
	reopened.unlock()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("import/export changed identity or pending state\n got: %#v\nwant: %#v", got, want)
	}
	if info, err := os.Stat(output); err != nil {
		t.Fatal(err)
	} else if info.Mode().Perm() != 0600 {
		t.Fatalf("export permissions = %o, want 600", info.Mode().Perm())
	}
}
