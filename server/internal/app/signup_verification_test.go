package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestResendMailerSendsCodeAndReportsProviderFailure(t *testing.T) {
	status := http.StatusOK
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("provider request authorization or method incorrect")
		}
		var body struct {
			From string   `json:"from"`
			To   []string `json:"to"`
			Text string   `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.From != "pair@example.com" || len(body.To) != 1 || body.To[0] != "new@example.com" || !strings.Contains(body.Text, "01234567") {
			t.Error("provider request payload incorrect")
		}
		w.WriteHeader(status)
	}))
	defer provider.Close()
	send := resendSignupMailer(provider.Client(), provider.URL, "test-key", "pair@example.com")
	if err := send(context.Background(), "new@example.com", "01234567"); err != nil {
		t.Fatal(err)
	}
	status = http.StatusForbidden
	if err := send(context.Background(), "new@example.com", "01234567"); err == nil {
		t.Fatal("provider failure was ignored")
	}
}

func TestVerificationConfigurationFailsClosedOnTypos(t *testing.T) {
	t.Setenv("PAIRDESK_SIGNUP_VERIFY_EMAIL", "treu")
	s, _ := fixture(t)
	if !s.signupVerifyEmail {
		t.Fatal("misspelled verification flag disabled verification")
	}
	if w := request(s.Handler(), "POST", "/v1/signup", "", `{"name":"New","email":"new@example.com","password":"a-strong-password"}`); w.Code != http.StatusBadRequest {
		t.Fatalf("unverified signup with misspelled flag: %d", w.Code)
	}
}

func TestVerifiedSignupCodeIsConsumedAtomically(t *testing.T) {
	s, _ := fixture(t)
	s.signupVerifyEmail = true
	var code string
	s.sendSignupCode = func(_ context.Context, _, c string) error { code = c; return nil }
	h := s.Handler()
	w := request(h, "POST", "/v1/signup-code", "", `{"email":"new@example.com"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("start: %d %s", w.Code, w.Body)
	}
	var response struct {
		ID string `json:"challengeId"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"name": "New", "email": "new@example.com", "password": "a-strong-password", "challengeId": response.ID, "code": code})
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); codes <- request(h, "POST", "/v1/signup", "", string(body)).Code }()
	}
	wg.Wait()
	close(codes)
	created := 0
	for status := range codes {
		if status == http.StatusCreated {
			created++
		}
	}
	if created != 1 {
		t.Fatalf("expected exactly one account creation, got %d", created)
	}
}

func TestVerifiedSignupRequiresCorrectSingleUseCode(t *testing.T) {
	s, _ := fixture(t)
	s.signupVerifyEmail = true
	s.signupAllowedDomains = parseAllowedValues("futurepath.ai")
	s.accessAllowedDomains = parseAllowedValues("futurepath.ai")
	s.accessAllowedEmails = parseAllowedValues("akshatsahu1@gmail.com")
	var sentEmail, sentCode string
	s.sendSignupCode = func(_ context.Context, email, code string) error { sentEmail, sentCode = email, code; return nil }
	h := s.Handler()
	if w := request(h, "POST", "/v1/signup", "", `{"name":"New","email":"new@futurepath.ai","password":"a-strong-password"}`); w.Code != http.StatusBadRequest {
		t.Fatalf("unverified signup: %d %s", w.Code, w.Body)
	}
	if w := request(h, "POST", "/v1/signup-code", "", `{"email":"other@gmail.com"}`); w.Code != http.StatusForbidden {
		t.Fatalf("disallowed domain: %d", w.Code)
	}
	w := request(h, "POST", "/v1/signup-code", "", `{"email":"New@futurepath.ai"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("request code: %d %s", w.Code, w.Body)
	}
	var response struct {
		ChallengeID string `json:"challengeId"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if sentEmail != "new@futurepath.ai" || len(sentCode) != 8 || response.ChallengeID == "" || strings.Contains(w.Body.String(), sentCode) {
		t.Fatal("code delivery or response incorrect")
	}
	submit := func(email, code string) int {
		body, _ := json.Marshal(map[string]string{"name": "New", "email": email, "password": "a-strong-password", "challengeId": response.ChallengeID, "code": code})
		return request(h, "POST", "/v1/signup", "", string(body)).Code
	}
	if got := submit("new@futurepath.ai", "xxxxxxxx"); got != http.StatusBadRequest {
		t.Fatalf("wrong code: %d", got)
	}
	if got := submit("new@futurepath.ai", sentCode); got != http.StatusCreated {
		t.Fatalf("correct code: %d", got)
	}
	if got := submit("new@futurepath.ai", sentCode); got == http.StatusCreated {
		t.Fatal("code replay created account")
	}
	if w := request(h, "POST", "/v1/signup-code", "", `{"email":"akshatsahu1@gmail.com"}`); w.Code != http.StatusAccepted {
		t.Fatalf("explicit Gmail exception: %d %s", w.Code, w.Body)
	}
}

func TestVerificationExpiryAttemptsAndProviderFailure(t *testing.T) {
	s, _ := fixture(t)
	s.signupVerifyEmail = true
	var code string
	s.sendSignupCode = func(_ context.Context, _, c string) error { code = c; return nil }
	h := s.Handler()
	start := func(email string) string {
		body, _ := json.Marshal(map[string]string{"email": email})
		w := request(h, "POST", "/v1/signup-code", "", string(body))
		if w.Code != http.StatusAccepted {
			t.Fatalf("start: %d %s", w.Code, w.Body)
		}
		var res struct {
			ID string `json:"challengeId"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &res)
		return res.ID
	}
	id := start("new@example.com")
	body := func(id, c string) string {
		b, _ := json.Marshal(map[string]string{"name": "New", "email": "new@example.com", "password": "a-strong-password", "challengeId": id, "code": c})
		return string(b)
	}
	for i := 0; i < 5; i++ {
		if w := request(h, "POST", "/v1/signup", "", body(id, "xxxxxxxx")); w.Code != http.StatusBadRequest {
			t.Fatalf("attempt %d: %d", i, w.Code)
		}
	}
	if w := request(h, "POST", "/v1/signup", "", body(id, code)); w.Code != http.StatusBadRequest {
		t.Fatalf("locked code: %d", w.Code)
	}
	id = start("new@example.com")
	s.store.lock()
	c := s.store.s.SignupChallenges[id]
	c.ExpiresAt = time.Now().Add(-time.Second)
	s.store.s.SignupChallenges[id] = c
	_ = s.store.save()
	s.store.unlock()
	if w := request(h, "POST", "/v1/signup", "", body(id, code)); w.Code != http.StatusBadRequest {
		t.Fatalf("expired code: %d", w.Code)
	}
	s.sendSignupCode = func(context.Context, string, string) error { return errors.New("private provider detail") }
	if w := request(h, "POST", "/v1/signup-code", "", `{"email":"another@example.com"}`); w.Code != http.StatusServiceUnavailable || strings.Contains(w.Body.String(), "private provider detail") {
		t.Fatalf("provider failure: %d %s", w.Code, w.Body)
	}
}

func TestAccessPolicyEnforcesExistingSessionsAndExactException(t *testing.T) {
	s, _ := fixture(t)
	token := login(t, s)
	s.accessAllowedDomains = parseAllowedValues("futurepath.ai")
	s.accessAllowedEmails = parseAllowedValues("akshatsahu1@gmail.com")
	if w := request(s.Handler(), "GET", "/v1/me", token, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("old disallowed session: %d", w.Code)
	}
	if w := request(s.Handler(), "POST", "/v1/login", "", `{"email":"a@example.com","password":"correct-horse-battery"}`); w.Code != http.StatusUnauthorized {
		t.Fatalf("disallowed login: %d", w.Code)
	}
	if _, err := s.store.CreateUser("Akshat", "akshatsahu1@gmail.com", "correct-horse-battery", false); err != nil {
		t.Fatal(err)
	}
	if w := request(s.Handler(), "POST", "/v1/login", "", `{"email":"akshatsahu1@gmail.com","password":"correct-horse-battery"}`); w.Code != http.StatusOK {
		t.Fatalf("allowed exception login: %d %s", w.Code, w.Body)
	}
	for _, email := range []string{"akshatsahu1@gmail.com", "person@futurepath.ai"} {
		if !s.emailAllowed(email) {
			t.Fatalf("expected allowed: %s", email)
		}
	}
	for _, email := range []string{"akshatsahu1+other@gmail.com", "person@sub.futurepath.ai", "person@futurepath.ai.attacker.test"} {
		if s.emailAllowed(email) {
			t.Fatalf("unexpected allowed: %s", email)
		}
	}
}
