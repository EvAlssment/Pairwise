package app

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func TestCallHistoryRecordsAnswerAndEndTimes(t *testing.T) {
	s, _ := fixture(t)
	callerToken := login(t, s)
	target, targetToken := addCallUser(t, s, "history-target")
	roomID, callID := startAcceptedDirectCall(t, s, callerToken, target, targetToken)
	h := s.Handler()
	readCall := func() (started, ended *time.Time) {
		t.Helper()
		w := request(h, "GET", "/v1/calls", callerToken, "")
		if w.Code != http.StatusOK {
			t.Fatalf("history: %d %s", w.Code, w.Body)
		}
		var result struct {
			Calls []struct {
				ID        string     `json:"id"`
				StartedAt *time.Time `json:"startedAt"`
				EndedAt   *time.Time `json:"endedAt"`
			} `json:"calls"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		for _, call := range result.Calls {
			if call.ID == callID {
				return call.StartedAt, call.EndedAt
			}
		}
		t.Fatal("call missing from history")
		return nil, nil
	}
	started, ended := readCall()
	if started == nil || ended != nil {
		t.Fatalf("accepted call timestamps: started=%v ended=%v", started, ended)
	}
	if w := request(h, "POST", "/v1/rooms/"+roomID+"/leave", callerToken, ""); w.Code != http.StatusOK {
		t.Fatalf("leave: %d %s", w.Code, w.Body)
	}
	finishedStart, finishedEnd := readCall()
	if finishedStart == nil || !finishedStart.Equal(*started) || finishedEnd == nil || finishedEnd.Before(*started) {
		t.Fatalf("finished call timestamps: started=%v ended=%v", finishedStart, finishedEnd)
	}
	_, repeatedEnd := readCall()
	if repeatedEnd == nil || !repeatedEnd.Equal(*finishedEnd) {
		t.Fatal("history polling changed the completed duration")
	}
	reloaded, err := OpenStore(s.store.path)
	if err != nil {
		t.Fatal(err)
	}
	persisted := reloaded.s.Calls[callID]
	if persisted.StartedAt == nil || !persisted.StartedAt.Equal(*started) || persisted.EndedAt == nil || !persisted.EndedAt.Equal(*finishedEnd) {
		t.Fatal("call duration timestamps did not survive storage reload")
	}
}

func TestCallHistoryTerminalPaths(t *testing.T) {
	for _, action := range []string{"caller-cancel", "target-cancel", "target-leave", "timeout", "legacy-accepted"} {
		t.Run(action, func(t *testing.T) {
			s, _ := fixture(t)
			callerToken := login(t, s)
			target, targetToken := addCallUser(t, s, "history-peer")
			roomID, callID := startAcceptedDirectCall(t, s, callerToken, target, targetToken)
			s.store.lock()
			invite := s.store.s.Calls[callID]
			answer := invite.UpdatedAt
			if action == "legacy-accepted" {
				invite.StartedAt = nil
				s.store.s.Calls[callID] = invite
			}
			if action == "timeout" {
				rm := s.store.s.Rooms[roomID]
				rm.Members[target.ID] = Member{UserID: target.ID, LastSeen: time.Now().Add(-2 * reservationTTL)}
				s.store.s.Rooms[roomID] = rm
				invite.ExpiresAt = time.Now().Add(-time.Second)
				s.store.s.Calls[callID] = invite
				s.pruneCallsLocked(time.Now().UTC())
			}
			s.store.unlock()
			if action != "timeout" {
				path, token := "/v1/calls/"+callID+"/cancel", callerToken
				if action == "target-cancel" {
					token = targetToken
				}
				if action == "target-leave" {
					path, token = "/v1/rooms/"+roomID+"/leave", targetToken
				}
				if w := request(s.Handler(), "POST", path, token, ""); w.Code != http.StatusOK {
					t.Fatalf("end call: %d %s", w.Code, w.Body)
				}
			}
			s.store.lock()
			defer s.store.unlock()
			ended := s.store.s.Calls[callID]
			if ended.StartedAt == nil || !ended.StartedAt.Equal(answer) || ended.EndedAt == nil || ended.EndedAt.Before(answer) {
				t.Fatalf("incorrect completed duration timestamps: %+v", ended)
			}
		})
	}
}

func TestUnansweredHistoryHasNoAnswerTimestamp(t *testing.T) {
	s, caller := fixture(t)
	target, _ := addCallUser(t, s, "unanswered-peer")
	now := time.Now().UTC()
	s.store.lock()
	defer s.store.unlock()
	s.store.s.Calls["expired"] = CallInvitation{ID: "expired", CallerID: caller.ID, TargetID: target.ID,
		RoomID: "room", Status: callPending, CreatedAt: now.Add(-time.Minute), UpdatedAt: now.Add(-time.Minute), ExpiresAt: now.Add(-time.Second)}
	s.pruneCallsLocked(now)
	expired := s.store.s.Calls["expired"]
	if expired.StartedAt != nil || expired.EndedAt == nil || !expired.EndedAt.Equal(expired.ExpiresAt) {
		t.Fatalf("unanswered expiry timestamps: %+v", expired)
	}
	for _, status := range []string{callCancelled, callDeclined} {
		invite := CallInvitation{Status: callPending, CreatedAt: now.Add(-time.Minute), UpdatedAt: now.Add(-time.Minute)}
		invite.finish(status, now)
		if invite.StartedAt != nil || invite.EndedAt == nil || !invite.EndedAt.Equal(now) {
			t.Fatalf("unanswered %s timestamps: %+v", status, invite)
		}
	}
}
