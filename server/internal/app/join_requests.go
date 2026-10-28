package app

import (
	"net/http"
	"sort"
	"strings"
	"time"
)

const joinRequestHistoryTTL = 24 * time.Hour
const joinRequestTTL = 45 * time.Second

type apiJoinRequest struct {
	ID        string    `json:"id"`
	Status    string    `json:"status"`
	Requester apiUser   `json:"requester"`
	Room      apiRoom   `json:"room"`
	ExpiresAt string    `json:"expiresAt"`
	CreatedAt time.Time `json:"createdAt"`
}

func (s *Server) activeCalls(w http.ResponseWriter, r *http.Request, _ User) {
	if r.Method != http.MethodGet {
		fail(w, 405, "method not allowed")
		return
	}
	s.store.lock()
	now := time.Now().UTC()
	rooms := []apiRoom{}
	for _, room := range s.store.s.Rooms {
		if room.DirectOnly && liveMemberCountLocked(s.store.s, room.ID, now) >= 2 {
			rooms = append(rooms, s.roomSnapshotLocked(room, now))
		}
	}
	s.store.unlock()
	sort.Slice(rooms, func(i, j int) bool { return rooms[i].Name < rooms[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"calls": rooms})
}

func (s *Server) joinRequests(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != http.MethodGet {
		fail(w, 405, "method not allowed")
		return
	}
	s.store.lock()
	now := time.Now().UTC()
	changed := s.pruneJoinRequestsLocked(now)
	result := []apiJoinRequest{}
	for _, request := range s.store.s.JoinRequests {
		if request.Status != "pending" && now.Sub(request.UpdatedAt) > joinRequestHistoryTTL {
			continue
		}
		room, exists := s.store.s.Rooms[request.RoomID]
		if !exists {
			continue
		}
		if request.RequesterID != u.ID && !activeMemberInRoomLocked(s.store.s, u.ID, room.ID, now) {
			continue
		}
		requester, exists := s.store.s.Users[request.RequesterID]
		if !exists {
			continue
		}
		result = append(result, s.joinRequestSnapshotLocked(request, requester, room, now))
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
	writeJSON(w, http.StatusOK, map[string]any{"requests": result})
}

func (s *Server) createJoinRequest(w http.ResponseWriter, r *http.Request, u User, roomID string) {
	if r.Method != http.MethodPost {
		fail(w, 405, "method not allowed")
		return
	}
	roomID = strings.TrimSpace(roomID)
	if roomID == "" {
		fail(w, 400, "room id is required")
		return
	}
	id, err := randomID(16)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	s.store.lock()
	defer s.store.unlock()
	now := time.Now().UTC()
	s.pruneJoinRequestsLocked(now)
	room, exists := s.store.s.Rooms[roomID]
	if !exists || !room.DirectOnly {
		fail(w, 404, "active call not found")
		return
	}
	if _, alreadyMember := room.Members[u.ID]; alreadyMember && activeMemberInRoomLocked(s.store.s, u.ID, roomID, now) {
		fail(w, 409, "you are already in this call")
		return
	}
	if !s.userOnlineLocked(u.ID, now) {
		fail(w, 409, "you are offline")
		return
	}
	if s.userBusyLocked(u.ID, now) {
		fail(w, 409, "you are already in a call")
		return
	}
	for _, existing := range s.store.s.JoinRequests {
		if existing.RequesterID != u.ID || existing.Status != "pending" || !now.Before(existing.ExpiresAt) {
			continue
		}
		if existing.RoomID == roomID {
			writeJSON(w, http.StatusOK, map[string]any{"request": s.joinRequestSnapshotLocked(existing, s.store.s.Users[u.ID], room, now)})
		} else {
			fail(w, 409, "you already have a pending join request")
		}
		return
	}
	if liveMemberCountLocked(s.store.s, roomID, now) < 2 {
		fail(w, 409, "this call has ended")
		return
	}
	if roomSeatCountLocked(s.store.s, roomID, now) >= maxRoom {
		fail(w, 409, "call is full")
		return
	}
	request := CallJoinRequest{ID: id, RequesterID: u.ID, RoomID: roomID, Status: "pending", CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(joinRequestTTL)}
	s.store.s.JoinRequests[id] = request
	participants := make([]string, 0, len(room.Members))
	for userID := range room.Members {
		if userID != u.ID && activeMemberInRoomLocked(s.store.s, userID, roomID, now) {
			participants = append(participants, userID)
		}
	}
	pushJobs := s.enqueuePushJobsLocked(participants, "join_request", roomID, request.ID, request.ExpiresAt)
	if err := s.store.save(); err != nil {
		delete(s.store.s.JoinRequests, id)
		for _, jobID := range pushJobs {
			delete(s.store.s.PushJobs, jobID)
		}
		fail(w, 500, "internal error")
		return
	}
	s.notify(participants, "join_request", roomID, request.ExpiresAt)
	writeJSON(w, http.StatusCreated, map[string]any{"request": s.joinRequestSnapshotLocked(request, s.store.s.Users[u.ID], room, now)})
}

func (s *Server) joinRequestAction(w http.ResponseWriter, r *http.Request, u User) {
	if r.Method != http.MethodPost {
		fail(w, 405, "method not allowed")
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/join-requests/"), "/")
	if len(parts) != 2 || parts[0] == "" {
		fail(w, 404, "not found")
		return
	}
	id, action := parts[0], parts[1]
	s.store.lock()
	defer s.store.unlock()
	now := time.Now().UTC()
	s.pruneJoinRequestsLocked(now)
	request, exists := s.store.s.JoinRequests[id]
	if !exists {
		fail(w, 404, "join request not found")
		return
	}
	room, roomExists := s.store.s.Rooms[request.RoomID]
	if !roomExists || !room.DirectOnly {
		fail(w, 404, "active call not found")
		return
	}
	if request.Status != "pending" || !now.Before(request.ExpiresAt) {
		fail(w, 409, "join request is no longer active")
		return
	}
	switch action {
	case "accept", "decline":
		if !activeMemberInRoomLocked(s.store.s, u.ID, request.RoomID, now) {
			fail(w, 403, "only a participant in the call can respond")
			return
		}
		if action == "accept" {
			requester, enabled := s.store.s.Users[request.RequesterID]
			if !enabled || !requester.Enabled || !s.userOnlineLocked(request.RequesterID, now) {
				fail(w, 409, "requester is no longer available")
				return
			}
			if s.userBusyLocked(request.RequesterID, now) || roomSeatCountLocked(s.store.s, request.RoomID, now) > maxRoom {
				fail(w, 409, "requester is busy or the call is full")
				return
			}
			if liveMemberCountLocked(s.store.s, request.RoomID, now) < 2 {
				fail(w, 409, "this call has ended")
				return
			}
			room.Members[request.RequesterID] = Member{UserID: request.RequesterID, LastSeen: now}
			s.store.s.Rooms[room.ID] = room
			request.Status = "accepted"
		} else {
			request.Status = "declined"
		}
	case "cancel":
		if u.ID != request.RequesterID {
			fail(w, 403, "only the requester can cancel")
			return
		}
		request.Status = "cancelled"
	default:
		fail(w, 404, "not found")
		return
	}
	request.UpdatedAt = now
	s.store.s.JoinRequests[id] = request
	if err := s.store.save(); err != nil {
		fail(w, 500, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"request": s.joinRequestSnapshotLocked(request, s.store.s.Users[request.RequesterID], room, now)})
}

func (s *Server) joinRequestSnapshotLocked(request CallJoinRequest, requester User, room Room, now time.Time) apiJoinRequest {
	return apiJoinRequest{ID: request.ID, Status: request.Status, Requester: pub(requester), Room: s.roomSnapshotLocked(room, now), ExpiresAt: request.ExpiresAt.UTC().Format(time.RFC3339), CreatedAt: request.CreatedAt}
}

func (s *Server) pruneJoinRequestsLocked(now time.Time) bool {
	changed := false
	for id, request := range s.store.s.JoinRequests {
		_, roomExists := s.store.s.Rooms[request.RoomID]
		if request.Status == "pending" && (!now.Before(request.ExpiresAt) || !roomExists || liveMemberCountLocked(s.store.s, request.RoomID, now) < 2) {
			request.Status = "expired"
			request.UpdatedAt = now
			s.store.s.JoinRequests[id] = request
			changed = true
		} else if request.Status != "pending" && now.Sub(request.UpdatedAt) > joinRequestHistoryTTL &&
			!(request.Status == "accepted" && activeMemberInRoomLocked(s.store.s, request.RequesterID, request.RoomID, now)) {
			// An accepted request remains the admission record for a live member,
			// including groups that outlive the original direct invitation.
			delete(s.store.s.JoinRequests, id)
			changed = true
		}
	}
	return changed
}
