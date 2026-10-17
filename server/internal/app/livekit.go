package app

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

var livekitHTTP = &http.Client{Timeout: 3 * time.Second}
var errLivekitParticipantMissing = errors.New("livekit participant missing")

func (s *Server) livekitCall(method string, body any) (int, error) {
	status, _, err := s.livekitCallResult(method, body)
	return status, err
}
func (s *Server) livekitCallResult(method string, body any) (int, []byte, error) {
	if s.liveAPIURL == "" || s.liveKey == "" || s.liveSecret == "" {
		return 0, nil, fmt.Errorf("livekit admin is not configured")
	}
	b, err := json.Marshal(body)
	if err != nil {
		return 0, nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(s.liveAPIURL, "/")+"/twirp/livekit.RoomService/"+method, bytes.NewReader(b))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.adminToken(method, body))
	resp, err := livekitHTTP.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	result, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, result, err
}
func (s *Server) createMediaRoom(id string) error {
	status, err := s.livekitCall("CreateRoom", map[string]any{"name": id, "emptyTimeout": 300, "maxParticipants": maxRoom})
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("livekit room create returned %d", status)
	}
	return nil
}
func (s *Server) ensureMediaRoom(id string) error {
	status, body, err := s.livekitCallResult("ListRooms", map[string]any{"names": []string{id}})
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("livekit room list returned %d", status)
	}
	var result struct {
		Rooms []struct {
			Name string `json:"name"`
		} `json:"rooms"`
	}
	if err = json.Unmarshal(body, &result); err != nil {
		return err
	}
	for _, room := range result.Rooms {
		if room.Name == id {
			return nil
		}
	}
	return s.createMediaRoom(id)
}
func (s *Server) updateSharePermission(room string, user User, enabled bool) error {
	sources := []int{1, 2} // camera and microphone remain available while screen sharing changes.
	if enabled {
		sources = []int{1, 2, 3} // camera, microphone and screen share; never screen-share audio
	}
	status, err := s.livekitCall("UpdateParticipant", map[string]any{"room": room, "identity": user.ID, "permission": map[string]any{"canPublish": true, "canSubscribe": true, "canPublishData": true, "canPublishSources": sources}})
	if err != nil {
		return err
	}
	if status == http.StatusNotFound {
		return errLivekitParticipantMissing
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("livekit permission update returned %d", status)
	}
	return nil
}
func (s *Server) removeLivekitParticipant(room, identity string) error {
	status,err:=s.livekitCall("RemoveParticipant",map[string]any{"room":room,"identity":identity})
	if err!=nil{return err}
	if status==http.StatusNotFound{return errLivekitParticipantMissing}
	if status<200||status>=300{return fmt.Errorf("livekit participant removal returned %d",status)}
	return nil
}
func (s *Server) adminToken(method string, body any) string {
	now := time.Now()
	video := map[string]any{}
	if method == "CreateRoom" {
		video["roomCreate"] = true
	}
	if method == "DeleteRoom" {
		video["roomCreate"] = true
	}
	if method == "ListRooms" {
		video["roomList"] = true
	}
	if method == "UpdateParticipant" {
		if request, ok := body.(map[string]any); ok {
			video["room"] = request["room"]
		}
		video["roomAdmin"] = true
	}
	if method == "RemoveParticipant" {
		if request,ok:=body.(map[string]any);ok{video["room"]=request["room"]}
		video["roomAdmin"]=true
	}
	claims := map[string]any{"iss": s.liveKey, "sub": "pairdesk-server", "iat": now.Unix(), "nbf": now.Unix() - 5, "exp": now.Add(time.Minute).Unix(), "video": video}
	b, _ := json.Marshal(claims)
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	jwtBody := head + "." + enc.EncodeToString(b)
	mac := hmac.New(sha256.New, []byte(s.liveSecret))
	_, _ = mac.Write([]byte(jwtBody))
	return jwtBody + "." + enc.EncodeToString(mac.Sum(nil))
}
