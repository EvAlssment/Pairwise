package app

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/mail"
	"net/smtp"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func parseAllowedValues(value string) map[string]struct{} {
	result := map[string]struct{}{}
	for _, item := range strings.Split(value, ",") {
		if item = strings.ToLower(strings.TrimSpace(item)); item != "" {
			result[item] = struct{}{}
		}
	}
	return result
}

func (s *Server) emailAllowed(email string) bool {
	if len(s.accessAllowedDomains) == 0 && len(s.accessAllowedEmails) == 0 {
		return true
	}
	email = strings.ToLower(strings.TrimSpace(email))
	if _, ok := s.accessAllowedEmails[email]; ok {
		return true
	}
	parts := strings.Split(email, "@")
	if len(parts) != 2 {
		return false
	}
	_, ok := s.accessAllowedDomains[parts[1]]
	return ok
}

func configuredSignupMailer() func(context.Context, string, string) error {
	key := strings.TrimSpace(os.Getenv("PAIRDESK_RESEND_API_KEY"))
	if path := os.Getenv("PAIRDESK_RESEND_API_KEY_FILE"); path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		key = strings.TrimSpace(string(data))
	}
	from := strings.TrimSpace(os.Getenv("PAIRDESK_RESEND_FROM"))
	if key == "" || from == "" {
		return nil
	}
	if strings.EqualFold(strings.TrimSpace(os.Getenv("PAIRDESK_RESEND_TRANSPORT")), "smtp") {
		return resendSMTPSignupMailer(key, from)
	}
	client := &http.Client{Timeout: 10 * time.Second}
	return resendSignupMailer(client, "https://api.resend.com/emails", key, from)
}

const resendSMTPHost = "smtp.resend.com"

type signupSMTPClient interface {
	Auth(smtp.Auth) error
	Mail(string) error
	Rcpt(string) error
	Data() (io.WriteCloser, error)
	Quit() error
}

type deadlineSMTPClient struct {
	signupSMTPClient
	stopCancel func() bool
}

func (c *deadlineSMTPClient) Quit() error {
	if c.stopCancel != nil {
		defer c.stopCancel()
	}
	return c.signupSMTPClient.Quit()
}

func resendSMTPSignupMailer(key, from string) func(context.Context, string, string) error {
	return resendSMTPSignupMailerWithDial(func(ctx context.Context) (signupSMTPClient, error) {
		dialer := &tls.Dialer{
			NetDialer: &net.Dialer{Timeout: 10 * time.Second},
			Config:    &tls.Config{MinVersion: tls.VersionTLS12, ServerName: resendSMTPHost},
		}
		conn, err := dialer.DialContext(ctx, "tcp", resendSMTPHost+":465")
		if err != nil {
			return nil, err
		}
		deadline := time.Now().Add(10 * time.Second)
		if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
			deadline = ctxDeadline
		}
		_ = conn.SetDeadline(deadline)
		stopCancel := context.AfterFunc(ctx, func() { _ = conn.SetDeadline(time.Now()) })
		client, err := smtp.NewClient(conn, resendSMTPHost)
		if err != nil {
			stopCancel()
			_ = conn.Close()
			return nil, err
		}
		return &deadlineSMTPClient{signupSMTPClient: client, stopCancel: stopCancel}, nil
	}, key, from)
}

func resendSMTPSignupMailerWithDial(dial func(context.Context) (signupSMTPClient, error), key, from string) func(context.Context, string, string) error {
	return func(ctx context.Context, email, code string) error {
		fromHeader, fromAddress, err := pairwiseSender(from)
		if err != nil {
			return err
		}
		toAddress, err := mail.ParseAddress(email)
		if err != nil || toAddress.Address != email {
			return errors.New("invalid signup recipient address")
		}
		client, err := dial(ctx)
		if err != nil {
			return fmt.Errorf("connect to Resend SMTP: %w", err)
		}
		defer client.Quit()
		if err := client.Auth(smtp.PlainAuth("", "resend", key, resendSMTPHost)); err != nil {
			return errors.New("Resend SMTP authentication failed")
		}
		if err := client.Mail(fromAddress.Address); err != nil {
			return fmt.Errorf("Resend rejected the sender: %w", err)
		}
		if err := client.Rcpt(toAddress.Address); err != nil {
			return fmt.Errorf("Resend rejected the recipient: %w", err)
		}
		writer, err := client.Data()
		if err != nil {
			return fmt.Errorf("Resend could not start the message: %w", err)
		}
		message := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: Your Pairwise verification code\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nYour Pairwise verification code is %s. It expires in 10 minutes. If you didn't request it, ignore this email.\r\n\r\n— The Pairwise team\r\n", fromHeader, toAddress.Address, code)
		if _, err := io.WriteString(writer, message); err != nil {
			_ = writer.Close()
			return fmt.Errorf("write Resend message: %w", err)
		}
		if err := writer.Close(); err != nil {
			return fmt.Errorf("Resend rejected the message: %w", err)
		}
		return nil
	}
}

func resendSignupMailer(client *http.Client, endpoint, key, from string) func(context.Context, string, string) error {
	return func(ctx context.Context, email, code string) error {
		fromHeader, _, err := pairwiseSender(from)
		if err != nil {
			return err
		}
		body, err := json.Marshal(map[string]any{"from": fromHeader, "to": []string{email}, "subject": "Your Pairwise verification code", "text": "Your Pairwise verification code is " + code + ". It expires in 10 minutes. If you didn't request it, ignore this email.\n\n— The Pairwise team"})
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return fmt.Errorf("email provider returned HTTP %d", resp.StatusCode)
		}
		return nil
	}
}

func pairwiseSender(from string) (string, *mail.Address, error) {
	address, err := mail.ParseAddress(from)
	if err != nil {
		return "", nil, errors.New("invalid Resend sender address")
	}
	address.Name = "Pairwise"
	return address.String(), address, nil
}

func signupCodeHash(id, code string) string {
	sum := sha256.Sum256([]byte(id + "." + code))
	return hex.EncodeToString(sum[:])
}

func (s *Server) signupCode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !s.signupEnabled || !s.signupVerifyEmail {
		fail(w, http.StatusForbidden, "email verification is not enabled")
		return
	}
	if s.sendSignupCode == nil {
		fail(w, http.StatusServiceUnavailable, "email verification is temporarily unavailable")
		return
	}
	var q struct {
		Email string `json:"email"`
	}
	if decode(r, &q) != nil || len(q.Email) > 254 {
		fail(w, http.StatusBadRequest, "enter a valid email address")
		return
	}
	email := strings.ToLower(strings.TrimSpace(q.Email))
	parsed, err := mail.ParseAddress(email)
	parts := strings.Split(email, "@")
	if err != nil || parsed.Address != email || len(parts) != 2 {
		fail(w, http.StatusBadRequest, "enter a valid email address")
		return
	}
	if len(s.signupAllowedDomains) > 0 {
		_, domainAllowed := s.signupAllowedDomains[parts[1]]
		_, emailException := s.accessAllowedEmails[email]
		if !domainAllowed && !emailException {
			fail(w, http.StatusForbidden, "email domain is not allowed for this team")
			return
		}
	}
	if !s.emailAllowed(email) {
		fail(w, http.StatusForbidden, "email address is not allowed for this team")
		return
	}
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip == "" {
		ip = r.RemoteAddr
	}
	ip = "signup:" + ip
	if !s.allowed(ip) {
		fail(w, http.StatusTooManyRequests, "too many signup attempts; try again later")
		return
	}
	s.recordLoginFailure(ip)
	id, err := randomID(24)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	value, err := rand.Int(rand.Reader, big.NewInt(100000000))
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	code := fmt.Sprintf("%08d", value.Int64())
	now := time.Now().UTC()
	s.store.lock()
	for _, u := range s.store.s.Users {
		if strings.EqualFold(u.Email, email) {
			s.store.unlock()
			fail(w, http.StatusConflict, "an account with this email already exists; sign in instead")
			return
		}
	}
	for key, challenge := range s.store.s.SignupChallenges {
		if !now.Before(challenge.ExpiresAt) || challenge.Email == email {
			delete(s.store.s.SignupChallenges, key)
		}
	}
	s.store.s.SignupChallenges[id] = SignupChallenge{Email: email, CodeHash: signupCodeHash(id, code), ExpiresAt: now.Add(10 * time.Minute)}
	err = s.store.save()
	s.store.unlock()
	if err != nil {
		fail(w, 500, "could not start verification")
		return
	}
	if err = s.sendSignupCode(r.Context(), email, code); err != nil {
		s.store.lock()
		delete(s.store.s.SignupChallenges, id)
		_ = s.store.save()
		s.store.unlock()
		fail(w, http.StatusServiceUnavailable, "could not send verification email; try again later")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"challengeId": id})
}

func (s *Server) finishVerifiedSignup(w http.ResponseWriter, r *http.Request, name, email, password, id, code string) {
	if id == "" || code == "" {
		fail(w, http.StatusBadRequest, "Email verification is required. Update PairDesk to create an account.")
		return
	}
	if len(id) > 128 || len(code) != 8 {
		fail(w, http.StatusBadRequest, "invalid or expired verification code")
		return
	}
	// Reject unknown and incorrect codes before doing expensive password hashing.
	s.store.lock()
	challenge, ok := s.store.s.SignupChallenges[id]
	if !ok || challenge.Email != email || !time.Now().Before(challenge.ExpiresAt) || challenge.Attempts >= 5 {
		s.store.unlock()
		fail(w, http.StatusBadRequest, "invalid or expired verification code")
		return
	}
	if subtle.ConstantTimeCompare([]byte(challenge.CodeHash), []byte(signupCodeHash(id, code))) != 1 {
		challenge.Attempts++
		s.store.s.SignupChallenges[id] = challenge
		err := s.store.save()
		s.store.unlock()
		if err != nil {
			fail(w, 500, "could not verify code")
			return
		}
		fail(w, http.StatusBadRequest, "invalid or expired verification code")
		return
	}
	s.store.unlock()
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		fail(w, http.StatusBadRequest, "password is too long")
		return
	}
	userID, err := randomID(12)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	token, err := randomID(32)
	if err != nil {
		fail(w, 500, "internal error")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(sessionTTL)
	s.store.lock()
	defer s.store.unlock()
	challenge, ok = s.store.s.SignupChallenges[id]
	if !ok || challenge.Email != email || !now.Before(challenge.ExpiresAt) || challenge.Attempts >= 5 || subtle.ConstantTimeCompare([]byte(challenge.CodeHash), []byte(signupCodeHash(id, code))) != 1 {
		fail(w, http.StatusBadRequest, "invalid or expired verification code")
		return
	}
	for _, u := range s.store.s.Users {
		if strings.EqualFold(u.Email, email) {
			fail(w, http.StatusConflict, "an account with this email already exists; sign in instead")
			return
		}
	}
	user := User{ID: userID, Name: name, Email: email, PasswordHash: string(hash), Enabled: true}
	s.store.s.Users[userID] = user
	s.store.s.Sessions[token] = Session{userID, expires}
	delete(s.store.s.SignupChallenges, id)
	if err = s.store.save(); err != nil {
		delete(s.store.s.Users, userID)
		delete(s.store.s.Sessions, token)
		s.store.s.SignupChallenges[id] = challenge
		fail(w, 500, "could not create account")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "user": pub(user), "expiresAt": expires.Format(time.RFC3339)})
}
