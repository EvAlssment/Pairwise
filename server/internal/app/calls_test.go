package app

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func addCallUser(t *testing.T, s *Server, name string) (User, string) {
	t.Helper()
	email := fmt.Sprintf("%s@example.com", name)
	u, err := s.store.CreateUser(name, email, "long-enough-password", false)
	if err != nil {
		t.Fatal(err)
	}
	token, err := randomID(32)
	if err != nil {
		t.Fatal(err)
	}
	s.store.lock()
	s.store.s.Sessions[token] = Session{UserID: u.ID, ExpiresAt: time.Now().Add(time.Hour)}
	s.store.s.Presence[u.ID] = time.Now().UTC()
	if err := s.store.save(); err != nil {
		t.Fatal(err)
	}
	s.store.unlock()
	return u, token
}

func TestDirectCallLifecycleAndPrivateRoomAuthorization(t *testing.T) {
	s, caller := fixture(t)
	h := s.Handler()
	callerToken := login(t, s)
	target, targetToken := addCallUser(t, s, "target")
	_, outsiderToken := addCallUser(t, s, "outsider")

	w := request(h, "POST", "/v1/calls", callerToken, fmt.Sprintf(`{"userId":%q}`, target.ID))
	if w.Code != http.StatusCreated {
		t.Fatalf("create call: %d %s", w.Code, w.Body)
	}
	var created struct {
		Call apiCall `json:"call"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Call.Caller.ID != caller.ID || created.Call.Target.ID != target.ID || created.Call.Room.Name == "" || created.Call.Room.Participants == nil || created.Call.ExpiresAt == "" {
		t.Fatalf("incomplete call contract: %+v", created.Call)
	}
	roomID, callID := created.Call.Room.ID, created.Call.ID
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/join", outsiderToken, ""); w.Code != 403 {
		t.Fatalf("outsider direct join: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/calls/"+callID+"/accept", outsiderToken, ""); w.Code != 403 {
		t.Fatalf("outsider accept: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/join", callerToken, ""); w.Code != 200 {
		t.Fatalf("caller join while ringing: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/join", targetToken, ""); w.Code != 403 {
		t.Fatalf("target joined before accept: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/calls/"+callID+"/accept", targetToken, ""); w.Code != 200 {
		t.Fatalf("target accept: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/join", targetToken, ""); w.Code != 200 {
		t.Fatalf("target join after accept: %d %s", w.Code, w.Body)
	}
	if w = request(h, "GET", "/v1/rooms", callerToken, ""); w.Code != 200 || containsJSONRoom(w.Body.String(), roomID) {
		t.Fatalf("direct room leaked from room list: %d %s", w.Code, w.Body)
	}
}

func TestDirectCallPendingExpiryAndLeaveCancellation(t *testing.T) {
	s, _ := fixture(t)
	h := s.Handler()
	callerToken := login(t, s)
	target, targetToken := addCallUser(t, s, "target")
	w := request(h, "POST", "/v1/calls", callerToken, fmt.Sprintf(`{"userId":%q}`, target.ID))
	var created struct {
		Call apiCall `json:"call"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)
	callID := created.Call.ID
	if w = request(h, "POST", "/v1/rooms/"+created.Call.Room.ID+"/leave", callerToken, ""); w.Code != 200 {
		t.Fatalf("caller leave: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/calls/"+callID+"/accept", targetToken, ""); w.Code != 409 {
		t.Fatalf("accept after caller leave: %d %s", w.Code, w.Body)
	}
	// A new invite is cancelled automatically after its server-side expiry.
	// This also verifies target reservations do not persist beyond the call TTL.
	target2, target2Token := addCallUser(t, s, "target2")
	w = request(h, "POST", "/v1/calls", callerToken, fmt.Sprintf(`{"userId":%q}`, target2.ID))
	if w.Code != http.StatusCreated {
		t.Fatalf("create second call: %d %s", w.Code, w.Body)
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)
	s.store.lock()
	expired := s.store.s.Calls[created.Call.ID]
	expired.ExpiresAt = time.Now().UTC().Add(-time.Second)
	s.store.s.Calls[expired.ID] = expired
	_ = s.store.save()
	s.store.unlock()
	if w = request(h, "GET", "/v1/calls", callerToken, ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"status":"expired"`) || !strings.Contains(w.Body.String(), `"createdAt":`) {
		t.Fatalf("expired call missing from history: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/calls/"+expired.ID+"/accept", target2Token, ""); w.Code != 409 {
		t.Fatalf("expired call accepted: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	old := s.store.s.Calls[expired.ID]
	old.UpdatedAt = time.Now().UTC().Add(-25 * time.Hour)
	s.store.s.Calls[old.ID] = old
	_ = s.store.save()
	s.store.unlock()
	if w = request(h, "GET", "/v1/calls", callerToken, ""); w.Code != 200 || !strings.Contains(w.Body.String(), expired.ID) {
		t.Fatalf("call history should retain unanswered calls for 30 days: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	old = s.store.s.Calls[expired.ID]
	old.UpdatedAt = time.Now().UTC().Add(-31 * 24 * time.Hour)
	s.store.s.Calls[old.ID] = old
	_ = s.store.save()
	s.store.unlock()
	if w = request(h, "GET", "/v1/calls", callerToken, ""); w.Code != 200 || strings.Contains(w.Body.String(), expired.ID) {
		t.Fatalf("old call history was not pruned after 30 days: %d %s", w.Code, w.Body)
	}
}

func TestAcceptedCallUsesLiveMembershipAfterReservationDeadline(t *testing.T) {
	s, caller := fixture(t)
	target, _ := addCallUser(t, s, "target")
	now := time.Now().UTC()
	rm := Room{ID: "direct-room", Name: "Direct call", DirectOnly: true, Members: map[string]Member{
		caller.ID: {UserID: caller.ID, LastSeen: now}, target.ID: {UserID: target.ID, LastSeen: now},
	}}
	s.store.lock()
	s.store.s.Rooms[rm.ID] = rm
	inv := CallInvitation{ID: "call", CallerID: caller.ID, TargetID: target.ID, RoomID: rm.ID, Status: callAccepted, CreatedAt: now.Add(-time.Minute), UpdatedAt: now.Add(-time.Minute), ExpiresAt: now.Add(-time.Minute)}
	s.store.s.Calls[inv.ID] = inv
	if changed := s.pruneCallsLocked(now); changed {
		t.Fatal("active accepted call expired at its original reservation deadline")
	}
	delete(rm.Members, caller.ID)
	s.store.s.Rooms[rm.ID] = rm
	if s.userBusyInOtherRoomLocked(caller.ID, "another-room", now) {
		t.Fatal("departed caller remained busy while target stayed connected")
	}
	// Put the caller back to exercise target expiry with caller still connected.
	rm.Members[caller.ID] = Member{UserID: caller.ID, LastSeen: now}
	// The target leaves while the caller stays connected; the accepted call must
	// stop reserving that target or making them busy in a different room.
	rm.Members[target.ID] = Member{UserID: target.ID, LastSeen: now.Add(-reservationTTL - time.Second)}
	s.store.s.Rooms[rm.ID] = rm
	if !s.pruneCallsLocked(now) {
		t.Fatal("accepted call remained active after target reservation expired")
	}
	if s.userBusyInOtherRoomLocked(target.ID, "another-room", now) {
		t.Fatal("stale accepted call kept target busy")
	}
	s.store.unlock()
}

func TestPrivateCallLeavesEndPairAndReleaseBothUsers(t *testing.T) {
	s, caller := fixture(t)
	h := s.Handler()
	callerToken := login(t, s)
	target, targetToken := addCallUser(t, s, "target")
	roomID, callID := startAcceptedDirectCall(t, s, callerToken, target, targetToken)
	if w := request(h, "POST", "/v1/rooms/"+roomID+"/leave", callerToken, ""); w.Code != 200 {
		t.Fatalf("leave direct call: %d %s", w.Code, w.Body)
	}
	for _, tc := range []struct{ id, token string }{{caller.ID, callerToken}, {target.ID, targetToken}} {
		w := request(h, "GET", "/v1/calls", tc.token, "")
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"id":"`+callID+`"`) || !strings.Contains(w.Body.String(), `"status":"cancelled"`) {
			t.Fatalf("call status for %s after teardown: %d %s", tc.id, w.Code, w.Body)
		}
		s.store.lock()
		busy := s.userBusyLocked(tc.id, time.Now().UTC())
		s.store.unlock()
		if busy {
			t.Fatalf("user %s still busy after pair teardown", tc.id)
		}
	}
	s.store.lock()
	if got := len(s.store.s.Rooms[roomID].Members); got != 0 {
		t.Fatalf("two-person room retained %d members after leave", got)
	}
	s.store.unlock()
}

func TestPrivateGroupContinuesUntilOneMemberRemains(t *testing.T) {
	s, caller := fixture(t)
	h := s.Handler()
	callerToken := login(t, s)
	b, bToken := addCallUser(t, s, "memberb")
	c, cToken := addCallUser(t, s, "memberc")
	roomID, _ := startAcceptedDirectCall(t, s, callerToken, b, bToken)
	w := request(h, "POST", "/v1/calls", bToken, fmt.Sprintf(`{"userId":%q,"roomId":%q}`, c.ID, roomID))
	if w.Code != 201 {
		t.Fatalf("invite third member: %d %s", w.Code, w.Body)
	}
	var third struct {
		Call apiCall `json:"call"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &third); err != nil {
		t.Fatal(err)
	}
	if w = request(h, "POST", "/v1/calls/"+third.Call.ID+"/accept", cToken, ""); w.Code != 200 {
		t.Fatalf("accept third invite: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/join", cToken, ""); w.Code != 200 {
		t.Fatalf("join group: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/leave", callerToken, ""); w.Code != 200 {
		t.Fatalf("first group leave: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	busy := s.userBusyLocked(caller.ID, time.Now().UTC())
	s.store.unlock()
	if busy {
		t.Fatal("departed member remained busy while group continued")
	}
	if w = request(h, "GET", "/v1/calls", bToken, ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"status":"accepted"`) {
		t.Fatalf("group did not retain active call state: %d %s", w.Code, w.Body)
	}
	removeCount := 0
	lk := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/RemoveParticipant") {
			removeCount++
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer lk.Close()
	s.liveAPIURL = lk.URL
	if w = request(h, "POST", "/v1/rooms/"+roomID+"/leave", bToken, ""); w.Code != 200 {
		t.Fatalf("second group leave: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	busy = s.userBusyLocked(c.ID, time.Now().UTC())
	if got := len(s.store.s.Rooms[roomID].Members); got != 0 {
		t.Fatalf("group retained %d members after reaching one", got)
	}
	s.store.unlock()
	if busy {
		t.Fatal("final remaining member stayed busy after teardown")
	}
	if removeCount != 1 {
		t.Fatalf("final peer was not removed from LiveKit: RemoveParticipant count=%d", removeCount)
	}
	if w = request(h, "GET", "/v1/calls", cToken, ""); w.Code != 200 || strings.Contains(w.Body.String(), `"status":"accepted"`) {
		t.Fatalf("final peer still sees active call: %d %s", w.Code, w.Body)
	}
}

func TestLoneMemberCannotKeepDirectCallBusyAfterPeerVanishes(t *testing.T) {
	s, caller := fixture(t)
	h := s.Handler()
	callerToken := login(t, s)
	target, targetToken := addCallUser(t, s, "target")
	_, observerToken := addCallUser(t, s, "observer")
	roomID, callID := startAcceptedDirectCall(t, s, callerToken, target, targetToken)

	// The caller's process dies without calling /leave; only its reservation expires.
	s.store.lock()
	rm := s.store.s.Rooms[roomID]
	rm.Members[caller.ID] = Member{UserID: caller.ID, LastSeen: time.Now().UTC().Add(-reservationTTL - time.Second)}
	s.store.s.Rooms[roomID] = rm
	s.store.unlock()
	// The target's client keeps heartbeating, as a client that missed the
	// LiveKit departure would.
	if w := request(h, "POST", "/v1/rooms/"+roomID+"/heartbeat", targetToken, ""); w.Code != 200 {
		t.Fatalf("target heartbeat before pruning: %d %s", w.Code, w.Body)
	}
	if w := request(h, "GET", "/v1/calls", observerToken, ""); w.Code != 200 {
		t.Fatalf("observer poll: %d %s", w.Code, w.Body)
	}
	s.store.lock()
	status := s.store.s.Calls[callID].Status
	busy := s.userBusyLocked(target.ID, time.Now().UTC())
	s.store.unlock()
	if status != callCancelled {
		t.Fatalf("lone-member call status = %q, want %q", status, callCancelled)
	}
	if busy {
		t.Fatal("target stayed busy alone in a call whose peer vanished")
	}
	// The lone client learns the call ended on its next heartbeat.
	if w := request(h, "POST", "/v1/rooms/"+roomID+"/heartbeat", targetToken, ""); w.Code != 403 {
		t.Fatalf("heartbeat after teardown: %d %s", w.Code, w.Body)
	}
	w := request(h, "GET", "/v1/users", observerToken, "")
	if w.Code != 200 || strings.Contains(w.Body.String(), `"busy":true`) {
		t.Fatalf("roster still reports a busy user: %d %s", w.Code, w.Body)
	}
}

func startAcceptedDirectCall(t *testing.T, s *Server, callerToken string, target User, targetToken string) (string, string) {
	t.Helper()
	h := s.Handler()
	w := request(h, "POST", "/v1/calls", callerToken, fmt.Sprintf(`{"userId":%q}`, target.ID))
	if w.Code != 201 {
		t.Fatalf("create direct call: %d %s", w.Code, w.Body)
	}
	var created struct {
		Call apiCall `json:"call"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if w = request(h, "POST", "/v1/rooms/"+created.Call.Room.ID+"/join", callerToken, ""); w.Code != 200 {
		t.Fatalf("caller join: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/calls/"+created.Call.ID+"/accept", targetToken, ""); w.Code != 200 {
		t.Fatalf("accept direct call: %d %s", w.Code, w.Body)
	}
	if w = request(h, "POST", "/v1/rooms/"+created.Call.Room.ID+"/join", targetToken, ""); w.Code != 200 {
		t.Fatalf("target join: %d %s", w.Code, w.Body)
	}
	return created.Call.Room.ID, created.Call.ID
}

func containsJSONRoom(body, id string) bool {
	var result struct {
		Rooms []struct {
			ID string `json:"id"`
		} `json:"rooms"`
	}
	if json.Unmarshal([]byte(body), &result) != nil {
		return false
	}
	for _, room := range result.Rooms {
		if room.ID == id {
			return true
		}
	}
	return false
}
