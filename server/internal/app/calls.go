package app

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

const callTTL = 45 * time.Second
const callHistoryTTL = 30 * 24 * time.Hour
const missedCallPushTTL = 24 * time.Hour
const (
	callPending   = "pending"
	callAccepted  = "accepted"
	callDeclined  = "declined"
	callCancelled = "cancelled"
	callExpired   = "expired"
)

type apiRoom struct {
	ID               string        `json:"id"`
	Name             string        `json:"name"`
	ParticipantCount int           `json:"participantCount"`
	Participants     []participant `json:"participants"`
}
type apiCall struct {
	ID        string    `json:"id"`
	Status    string    `json:"status"`
	Caller    apiUser   `json:"caller"`
	Target    apiUser   `json:"target"`
	Room      apiRoom   `json:"room"`
	CreatedAt time.Time `json:"createdAt"`
	ExpiresAt string    `json:"expiresAt"`
}

func (s *Server) calls(w http.ResponseWriter, r *http.Request, u User) {
	switch r.Method {
	case http.MethodGet:
		s.store.lock()
		now := time.Now().UTC()
		changed := s.pruneCallsLocked(now)
		result := []apiCall{}
		for _, invite := range s.store.s.Calls {
			if invite.CallerID == u.ID || invite.TargetID == u.ID {
				if time.Since(invite.UpdatedAt) <= callHistoryTTL {
					if invite.Status == callAccepted {
						rm := s.store.s.Rooms[invite.RoomID]
						if rm.DirectOnly && !activeMemberInRoomLocked(s.store.s, u.ID, invite.RoomID, now) {
							continue
						}
					}
					result = append(result, s.callSnapshotLocked(invite, now))
				}
			}
		}
		if changed {
			if err := s.store.save(); err != nil {
				s.store.unlock()
				fail(w, 500, "internal error")
				return
			}
		}
		s.store.unlock()
		sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.After(result[j].CreatedAt) })
		if len(result) > 100 {
			result = result[:100]
		}
		writeJSON(w, 200, map[string]any{"calls": result})
	case http.MethodPost:
		s.createCall(w, r, u)
	default:
		fail(w, 405, "method not allowed")
	}
}
func (s *Server) createCall(w http.ResponseWriter, r *http.Request, u User) {
	var q struct {
		UserID string `json:"userId"`
		RoomID string `json:"roomId"`
	}
	if decode(r, &q) != nil || strings.TrimSpace(q.UserID) == "" {
		fail(w, 400, "userId is required")
		return
	}
	q.UserID = strings.TrimSpace(q.UserID)
	q.RoomID = strings.TrimSpace(q.RoomID)
	if q.UserID == u.ID {
		fail(w, 400, "cannot call yourself")
		return
	}
	callID, err := randomID(16)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	roomID := q.RoomID
	if roomID == "" {
		roomID, err = randomID(12)
		if err != nil {
			fail(w, 500, "internal error")
			return
		}
	}
	s.store.lock()
	defer s.store.unlock()
	now := time.Now().UTC()
	s.pruneCallsLocked(now)
	target, ok := s.store.s.Users[q.UserID]
	if !ok || !target.Enabled {
		fail(w, 404, "user not found")
		return
	}
	if time.Since(s.store.s.Presence[target.ID]) >= reservationTTL {
		fail(w, 409, "user is offline")
		return
	}
	if s.userBusyLocked(target.ID, now) {
		fail(w, 409, "user is busy")
		return
	}
	rm, roomExists := s.store.s.Rooms[roomID]
	if q.RoomID != "" {
		if !roomExists {
			fail(w, 404, "room not found")
			return
		}
		member, joined := rm.Members[u.ID]
		if !joined || now.Sub(member.LastSeen) >= reservationTTL {
			fail(w, 403, "join the room before inviting someone")
			return
		}
		if s.userBusyInOtherRoomLocked(u.ID, roomID, now) {
			fail(w, 409, "caller is busy in another call")
			return
		}
	} else {
		if s.userBusyLocked(u.ID, now) {
			fail(w, 409, "caller is busy")
			return
		}
		if s.liveURL == "" || s.liveKey == "" || s.liveSecret == "" {
			fail(w, 503, "media service is not configured")
			return
		}
		rm = Room{ID: roomID, Name: "Direct call", Members: map[string]Member{}, DirectOnly: true, CreatedAt: now}
		if err = s.createMediaRoom(roomID); err != nil {
			fail(w, 503, "media service is unavailable")
			return
		}
		rm.Members[u.ID] = Member{UserID: u.ID, LastSeen: now}
	}
	if roomSeatCountLocked(s.store.s, roomID, now) >= maxRoom {
		fail(w, 409, "room is full")
		return
	}
	invite := CallInvitation{ID: callID, CallerID: u.ID, TargetID: target.ID, RoomID: roomID, Status: callPending, CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(callTTL)}
	s.store.s.Rooms[roomID] = rm
	s.store.s.Calls[callID] = invite
	pushJobs := s.enqueuePushJobsLocked([]string{target.ID}, "direct_call", invite.ID, "", invite.ExpiresAt)
	if err = s.store.save(); err != nil {
		delete(s.store.s.Calls, callID)
		for _, id := range pushJobs {
			delete(s.store.s.PushJobs, id)
		}
		if q.RoomID == "" {
			delete(s.store.s.Rooms, roomID)
		}
		fail(w, 500, "internal error")
		return
	}
	s.notify([]string{target.ID}, "direct_call", invite.ID, invite.ExpiresAt)
	writeJSON(w, http.StatusCreated, map[string]any{"call": s.callSnapshotLocked(invite, now)})
}
func (s *Server) callAction(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != http.MethodPost {
		fail(w, 405, "method not allowed")
		return
	}
	tail := strings.TrimPrefix(r.URL.Path, "/v1/calls/")
	parts := strings.Split(tail, "/")
	if len(parts) != 2 || parts[0] == "" {
		fail(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	s.store.lock()
	defer s.store.unlock()
	now := time.Now().UTC()
	changed := s.pruneCallsLocked(now)
	invite, ok := s.store.s.Calls[id]
	if !ok {
		if changed {
			_ = s.store.save()
		}
		fail(w, 404, "call not found")
		return
	}
	if invite.Status == callPending && !now.Before(invite.ExpiresAt) {
		invite.Status = callExpired
		invite.UpdatedAt = now
		s.store.s.Calls[id] = invite
		changed = true
	}
	if invite.Status == callExpired || invite.Status == callDeclined || invite.Status == callCancelled {
		if changed {
			_ = s.store.save()
		}
		fail(w, 409, "call is no longer active")
		return
	}
	rm, roomExists := s.store.s.Rooms[invite.RoomID]
	if !roomExists {
		fail(w, 404, "room not found")
		return
	}
	switch action {
	case "accept":
		if u.ID != invite.TargetID {
			fail(w, 403, "only the invited user can accept")
			return
		}
		if invite.Status != callPending {
			fail(w, 409, "call is not waiting for an answer")
			return
		}
		caller, exists := s.store.s.Users[invite.CallerID]
		if !exists || !caller.Enabled || (!s.userOnlineLocked(caller.ID, now) && !activeMemberInRoomLocked(s.store.s, caller.ID, invite.RoomID, now)) {
			invite.Status = callCancelled
			invite.UpdatedAt = now
			s.store.s.Calls[id] = invite
			_ = s.store.save()
			fail(w, 409, "caller is no longer available")
			return
		}
		if s.userBusyInOtherRoomLocked(u.ID, invite.RoomID, now) {
			fail(w, 409, "user is busy in another call")
			return
		}
		if roomSeatCountLocked(s.store.s, invite.RoomID, now) > maxRoom {
			fail(w, 409, "room is full")
			return
		}
		invite.Status = callAccepted
		invite.UpdatedAt = now
		invite.ExpiresAt = now.Add(reservationTTL)
		rm.Members[u.ID] = Member{UserID: u.ID, LastSeen: now}
		s.store.s.Rooms[rm.ID] = rm
		s.store.s.Calls[id] = invite
	case "decline":
		if u.ID != invite.TargetID {
			fail(w, 403, "only the invited user can decline")
			return
		}
		if invite.Status != callPending {
			fail(w, 409, "call is not waiting for an answer")
			return
		}
		invite.Status = callDeclined
		invite.UpdatedAt = now
		s.store.s.Calls[id] = invite
	case "cancel":
		if u.ID != invite.CallerID && u.ID != invite.TargetID {
			fail(w, 403, "not a participant in this call")
			return
		}
		if invite.Status == callPending && u.ID != invite.CallerID {
			fail(w, 403, "only the caller can cancel a pending call")
			return
		}
		if invite.Status != callPending && invite.Status != callAccepted {
			fail(w, 409, "call is not active")
			return
		}
		if invite.Status == callAccepted {
			target := s.store.s.Users[invite.TargetID]
			if rm.SharingUserID == target.ID {
				if err := s.updateSharePermission(invite.RoomID, target, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
					fail(w, 503, "media service is unavailable")
					return
				}
				rm.SharingUserID = ""
			}
			if err := s.removeLivekitParticipant(invite.RoomID, target.ID); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
				fail(w, 503, "media service is unavailable")
				return
			}
			delete(rm.Members, target.ID)
			s.store.s.Rooms[rm.ID] = rm
		}
		invite.Status = callCancelled
		invite.UpdatedAt = now
		s.store.s.Calls[id] = invite
	default:
		fail(w, 404, "not found")
		return
	}
	if rm.DirectOnly && !hasActiveCallInRoomLocked(s.store.s, rm.ID, now) {
		rm.Members = map[string]Member{}
		s.store.s.Rooms[rm.ID] = rm
	}
	if err := s.store.save(); err != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, 200, map[string]any{"call": s.callSnapshotLocked(invite, now)})
}
func (s *Server) callSnapshotLocked(invite CallInvitation, now time.Time) apiCall {
	room := s.store.s.Rooms[invite.RoomID]
	return apiCall{ID: invite.ID, Status: invite.Status, Caller: pub(s.store.s.Users[invite.CallerID]), Target: pub(s.store.s.Users[invite.TargetID]), Room: s.roomSnapshotLocked(room, now), ExpiresAt: invite.ExpiresAt.UTC().Format(time.RFC3339), CreatedAt: invite.CreatedAt}
}
func (s *Server) roomSnapshotLocked(rm Room, now time.Time) apiRoom {
	ps := []participant{}
	for _, m := range rm.Members {
		if now.Sub(m.LastSeen) < reservationTTL {
			if x, ok := s.store.s.Users[m.UserID]; ok && x.Enabled {
				ps = append(ps, participant{x.ID, x.Name, x.Email})
			}
		}
	}
	return apiRoom{ID: rm.ID, Name: rm.Name, ParticipantCount: roomSeatCountLocked(s.store.s, rm.ID, now), Participants: ps}
}
func (s *Server) pruneCallsLocked(now time.Time) bool {
	changed := false
	for id, invite := range s.store.s.Calls {
		if invite.Status == callPending && !now.Before(invite.ExpiresAt) {
			invite.Status = callExpired
			invite.UpdatedAt = now
			s.store.s.Calls[id] = invite
			// A missed-call alert is a separate, durable event from the short
			// ringing notification. It is addressed only to the invited user and
			// expires after the same retention window as the call history.
			s.enqueuePushJobsLocked([]string{invite.TargetID}, "missed_call", invite.ID, "", now.Add(missedCallPushTTL))
			changed = true
		}
		if invite.Status == callAccepted && !acceptedCallActiveLocked(s.store.s, invite, now) {
			invite.Status = callCancelled
			invite.UpdatedAt = now
			s.store.s.Calls[id] = invite
			changed = true
		}
		if (invite.Status == callDeclined || invite.Status == callCancelled || invite.Status == callExpired) && now.Sub(invite.UpdatedAt) > callHistoryTTL {
			delete(s.store.s.Calls, id)
			changed = true
		}
	}
	for id, rm := range s.store.s.Rooms {
		if rm.DirectOnly && !hasActiveCallInRoomLocked(s.store.s, id, now) && len(rm.Members) > 0 {
			rm.Members = map[string]Member{}
			s.store.s.Rooms[id] = rm
			changed = true
		}
	}
	return changed
}
func pendingCallSeatsLocked(state State, roomID string, now time.Time) int {
	count := 0
	for _, invite := range state.Calls {
		if invite.RoomID == roomID && invite.Status == callPending && now.Before(invite.ExpiresAt) {
			count++
		}
	}
	for _, request := range state.JoinRequests {
		if request.RoomID == roomID && request.Status == "pending" && now.Before(request.ExpiresAt) {
			count++
		}
	}
	return count
}
func callParticipantActiveLocked(state State, invite CallInvitation, now time.Time) bool {
	rm, ok := state.Rooms[invite.RoomID]
	if !ok {
		return false
	}
	for _, id := range []string{invite.CallerID, invite.TargetID} {
		if m, exists := rm.Members[id]; exists && now.Sub(m.LastSeen) < reservationTTL {
			if u, enabled := state.Users[id]; enabled && u.Enabled {
				return true
			}
		}
	}
	return false
}
func hasActiveCallInRoomLocked(state State, roomID string, now time.Time) bool {
	for _, invite := range state.Calls {
		if invite.RoomID == roomID && (invite.Status == callPending && now.Before(invite.ExpiresAt) || invite.Status == callAccepted && acceptedCallActiveLocked(state, invite, now)) {
			return true
		}
	}
	// Approved joiners can keep an established group alive after the original
	// caller/target leave. A lone member still needs a pending seat to wait for.
	if liveMemberCountLocked(state, roomID, now) >= 2 || pendingCallSeatsLocked(state, roomID, now) > 0 {
		for _, request := range state.JoinRequests {
			if request.RoomID == roomID && request.Status == "accepted" && activeMemberInRoomLocked(state, request.RequesterID, roomID, now) {
				return true
			}
		}
	}
	return false
}

// acceptedCallActiveLocked keeps an accepted call alive while the caller waits
// for the target to join, then only while the target shares the room with
// another live member or a pending invitation. A lone client that keeps
// heartbeating after every peer vanished without /leave (crash, sleep, lost
// network) must not keep the call, and its busy state, alive indefinitely.
func acceptedCallActiveLocked(state State, invite CallInvitation, now time.Time) bool {
	if activeMemberInRoomLocked(state, invite.TargetID, invite.RoomID, now) {
		return liveMemberCountLocked(state, invite.RoomID, now) >= 2 || pendingCallSeatsLocked(state, invite.RoomID, now) > 0
	}
	return now.Before(invite.ExpiresAt) && activeMemberInRoomLocked(state, invite.CallerID, invite.RoomID, now)
}
func liveMemberCountLocked(state State, roomID string, now time.Time) int {
	count := 0
	for id := range state.Rooms[roomID].Members {
		if activeMemberInRoomLocked(state, id, roomID, now) {
			count++
		}
	}
	return count
}
func roomSeatCountLocked(state State, roomID string, now time.Time) int {
	count := 0
	if rm, ok := state.Rooms[roomID]; ok {
		for id, m := range rm.Members {
			if now.Sub(m.LastSeen) < reservationTTL {
				if u, exists := state.Users[id]; exists && u.Enabled {
					count++
				}
			}
		}
	}
	for _, invite := range state.Calls {
		if invite.RoomID == roomID && invite.Status == callPending && now.Before(invite.ExpiresAt) {
			count++
		}
	}
	// Pending join requests reserve call capacity just like pending direct-call
	// invitations. Without counting these seats, several simultaneous requests
	// can all be accepted after the room has already reached its four-person cap.
	for _, request := range state.JoinRequests {
		if request.RoomID == roomID && request.Status == "pending" && now.Before(request.ExpiresAt) {
			count++
		}
	}
	return count
}
func (s *Server) userOnlineLocked(id string, now time.Time) bool {
	return now.Sub(s.store.s.Presence[id]) < reservationTTL
}
func (s *Server) activeRoomMemberLocked(userID, exceptRoom string, now time.Time) bool {
	for id, rm := range s.store.s.Rooms {
		if exceptRoom != "" && id == exceptRoom {
			continue
		}
		if m, ok := rm.Members[userID]; ok && now.Sub(m.LastSeen) < reservationTTL {
			if u, exists := s.store.s.Users[userID]; exists && u.Enabled {
				return true
			}
		}
	}
	return false
}
func activeMemberInRoomLocked(state State, userID, roomID string, now time.Time) bool {
	rm, ok := state.Rooms[roomID]
	if !ok {
		return false
	}
	m, ok := rm.Members[userID]
	if !ok || now.Sub(m.LastSeen) >= reservationTTL {
		return false
	}
	u, ok := state.Users[userID]
	return ok && u.Enabled
}
func (s *Server) userBusyInOtherRoomLocked(userID, roomID string, now time.Time) bool {
	if s.activeRoomMemberLocked(userID, roomID, now) {
		return true
	}
	for _, invite := range s.store.s.Calls {
		// Pending invitations reserve both parties. Once accepted, busy state is
		// represented by the live room membership reservation above, so a caller
		// who leaves is immediately free even if the target stays connected.
		if invite.RoomID != roomID && invite.Status == callPending && now.Before(invite.ExpiresAt) && (invite.CallerID == userID || invite.TargetID == userID) {
			return true
		}
	}
	return false
}
func (s *Server) userBusyLocked(userID string, now time.Time) bool {
	if s.activeRoomMemberLocked(userID, "", now) {
		return true
	}
	for _, invite := range s.store.s.Calls {
		if (invite.CallerID == userID || invite.TargetID == userID) && invite.Status == callPending && now.Before(invite.ExpiresAt) {
			return true
		}
	}
	return false
}
func (s *Server) canJoinDirectRoomLocked(roomID, userID string, now time.Time) bool {
	for _, invite := range s.store.s.Calls {
		if invite.RoomID != roomID {
			continue
		}
		if invite.Status == callPending && invite.CallerID == userID && now.Before(invite.ExpiresAt) && activeMemberInRoomLocked(s.store.s, userID, roomID, now) {
			return true
		}
		if invite.Status == callAccepted && (invite.CallerID == userID || invite.TargetID == userID) && activeMemberInRoomLocked(s.store.s, userID, roomID, now) {
			return true
		}
	}
	for _, request := range s.store.s.JoinRequests {
		if request.RoomID == roomID && request.RequesterID == userID && request.Status == "accepted" && activeMemberInRoomLocked(s.store.s, userID, roomID, now) {
			return true
		}
	}
	return false
}
func cancelPendingCallsForCallerLocked(state *State, userID, roomID string, now time.Time) bool {
	changed := false
	for id, invite := range state.Calls {
		if invite.RoomID == roomID && invite.CallerID == userID && invite.Status == callPending {
			invite.Status = callCancelled
			invite.UpdatedAt = now
			state.Calls[id] = invite
			changed = true
		}
	}
	return changed
}
func cancelAcceptedCallForTargetLocked(state *State, userID, roomID string, now time.Time) bool {
	changed := false
	for id, invite := range state.Calls {
		if invite.RoomID == roomID && invite.TargetID == userID && invite.Status == callAccepted {
			invite.Status = callCancelled
			invite.UpdatedAt = now
			state.Calls[id] = invite
			changed = true
		}
	}
	return changed
}

// leaveDirectRoomLocked removes a leaver from a private call session. A group
// stays active while at least two live members remain. At one or zero members,
// it disconnects the final peer and cancels every live invitation in the room.
// The store mutex must be held by the caller.
func (s *Server) leaveDirectRoomLocked(rm *Room, user User, now time.Time) error {
	if !rm.DirectOnly {
		return nil
	}
	if rm.SharingUserID == user.ID {
		if err := s.updateSharePermission(rm.ID, user, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
			return err
		}
		rm.SharingUserID = ""
	}
	delete(rm.Members, user.ID)
	remaining := make([]string, 0, len(rm.Members))
	for memberID, member := range rm.Members {
		account, exists := s.store.s.Users[memberID]
		if exists && account.Enabled && now.Sub(member.LastSeen) < reservationTTL {
			remaining = append(remaining, memberID)
		}
	}
	if len(remaining) > 1 {
		cancelPendingCallsForCallerLocked(&s.store.s, user.ID, rm.ID, now)
		return nil
	}
	for id, request := range s.store.s.JoinRequests {
		if request.RoomID == rm.ID && request.Status == "pending" {
			request.Status = "cancelled"
			request.UpdatedAt = now
			s.store.s.JoinRequests[id] = request
		}
	}
	for _, memberID := range remaining {
		account := s.store.s.Users[memberID]
		if rm.SharingUserID == memberID {
			if err := s.updateSharePermission(rm.ID, account, false); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
				return err
			}
		}
		if err := s.removeLivekitParticipant(rm.ID, memberID); err != nil && !errors.Is(err, errLivekitParticipantMissing) {
			return err
		}
	}
	rm.SharingUserID = ""
	rm.Members = map[string]Member{}
	for id, invite := range s.store.s.Calls {
		if invite.RoomID == rm.ID && (invite.Status == callPending || invite.Status == callAccepted) {
			invite.Status = callCancelled
			invite.UpdatedAt = now
			s.store.s.Calls[id] = invite
		}
	}
	return nil
}
