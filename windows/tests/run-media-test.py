"""Exercise native media against isolated loopback LiveKit and Pairwise servers.

Only generated test accounts, tokens and synthetic media are used. No physical
microphone, camera, screen capture or production service is accessed.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import pathlib
import re
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile


def token(identity):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    now = int(time.time())
    unsigned = f'{encode({"alg": "HS256", "typ": "JWT"})}.{encode({"iss": "devkey", "sub": identity, "nbf": now - 5, "exp": now + 300, "video": {"roomJoin": True, "room": "pairwise-windows-ci", "canPublish": True, "canSubscribe": True, "canPublishData": True}})}'
    signature = base64.urlsafe_b64encode(hmac.new(b"secret", unsigned.encode(), hashlib.sha256).digest()).decode().rstrip("=")
    return f"{unsigned}.{signature}"


def ready(process, port):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Local test service exited before startup")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Local test service did not become ready")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def run(executable, server, api_executable):
    with tempfile.TemporaryDirectory(prefix="pairwise-media-") as temporary:
        directory = pathlib.Path(temporary)
        if server is None:
            archive = directory / "livekit.zip"
            urllib.request.urlretrieve("https://github.com/livekit/livekit/releases/download/v1.8.4/livekit_1.8.4_windows_amd64.zip", archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != "e694983155bf6c01c94f73bfd189ec214210ed400e489af721d6abfe1835278e":
                raise RuntimeError("Media server checksum mismatch")
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(directory)
            server = directory / "livekit-server.exe"
        processes, logs = [], []
        heartbeat_stop = threading.Event()
        heartbeat_thread = None
        heartbeat_errors = []
        failed = False
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        api_url = "http://127.0.0.1:18089"

        def request(path, session=None, body=None):
            headers = {"Content-Type": "application/json"}
            if session:
                headers["Authorization"] = "Bearer " + session["token"]
            # urllib closes each HTTP/1.1 connection. Go intentionally skips
            # draining unused bodies on Connection: close, which can race a
            # separately sent '{}' and reset the socket on Windows. Bodyless
            # API actions still use POST (b''), without sending unused bytes.
            data = None if body is None else (b"" if not body else json.dumps(body).encode())
            req = urllib.request.Request(api_url + path, data=data, headers=headers)
            with opener.open(req, timeout=10) as response:
                content = response.read()
                return json.loads(content) if content else {}

        try:
            log = (directory / "livekit.log").open("wb"); logs.append(log)
            media = subprocess.Popen([str(server), "--dev", "--bind", "127.0.0.1", "--node-ip", "127.0.0.1", "--port", "17890"], stdout=log, stderr=subprocess.STDOUT)
            processes.append(media); ready(media, 17890)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("PAIRWISE_API_", "PAIRWISE_MEDIA_"))}
            env.update(PAIRWISE_MEDIA_TEST_URL="ws://127.0.0.1:17890", PAIRWISE_MEDIA_SENDER_TOKEN=token("sender"), PAIRWISE_MEDIA_RECEIVER_TOKEN=token("receiver"))
            sessions = []
            room_id = None
            call_id = None
            if api_executable:
                api_env = {key: value for key, value in os.environ.items() if not key.startswith(("PAIRDESK_", "LIVEKIT_"))}
                api_env.update(PAIRDESK_DATA=str(directory / "accounts.json"), PAIRDESK_ADDR="127.0.0.1:18089", PAIRDESK_SIGNUP_ENABLED="true", PAIRDESK_SIGNUP_VERIFY_EMAIL="false", LIVEKIT_URL="ws://127.0.0.1:17890", LIVEKIT_API_URL="http://127.0.0.1:17890", LIVEKIT_API_KEY="devkey", LIVEKIT_API_SECRET="secret")
                log = (directory / "api.log").open("wb"); logs.append(log)
                api_process = subprocess.Popen([str(api_executable.resolve())], env=api_env, stdout=log, stderr=subprocess.STDOUT)
                processes.append(api_process); ready(api_process, 18089)
                for identity in ("sender", "receiver"):
                    session = request("/v1/signup", body={"name": identity, "email": identity + "@pairwise.invalid", "password": "SyntheticWindowsPassword123!"})
                    sessions.append(session)
                    request("/v1/heartbeat", session, {})
                invitation = request("/v1/calls", sessions[0], {"userId": sessions[1]["user"]["id"]})["call"]
                call_id = invitation["id"]
                accepted = request("/v1/calls/" + call_id + "/accept", sessions[1], {})["call"]
                if accepted["status"] != "accepted":
                    raise RuntimeError("API did not accept the direct call")
                room_id = accepted["room"]["id"]
                admissions = [request("/v1/rooms/" + room_id + "/join", session, {}) for session in sessions]
                for admission, session in zip(admissions, sessions):
                    if admission["participantIdentity"] != session["user"]["id"]:
                        raise RuntimeError("API admission identity mismatch")
                env.update(PAIRWISE_MEDIA_TEST_URL=admissions[0]["url"], PAIRWISE_MEDIA_SENDER_TOKEN=admissions[0]["token"], PAIRWISE_MEDIA_RECEIVER_TOKEN=admissions[1]["token"], PAIRWISE_MEDIA_SENDER_ID=sessions[0]["user"]["id"], PAIRWISE_MEDIA_RECEIVER_ID=sessions[1]["user"]["id"], PAIRWISE_API_URL=api_url, PAIRWISE_API_SENDER_TOKEN=sessions[0]["token"], PAIRWISE_API_ROOM_ID=room_id)

                def heartbeat():
                    while not heartbeat_stop.wait(5):
                        try:
                            for session in sessions:
                                if heartbeat_stop.is_set():
                                    return
                                request("/v1/heartbeat", session, {})
                                if heartbeat_stop.is_set():
                                    return
                                request("/v1/rooms/" + room_id + "/heartbeat", session, {})
                        except Exception as error:
                            heartbeat_errors.append(type(error).__name__)
                            return
                heartbeat_thread = threading.Thread(target=heartbeat, daemon=True)
                heartbeat_thread.start()
                print("Real API direct-call acceptance and room admission verified.")
            subprocess.run([str(executable.resolve())], env=env, check=True, timeout=60)
            heartbeat_stop.set()
            if heartbeat_thread:
                heartbeat_thread.join(timeout=12)
                if heartbeat_thread.is_alive():
                    raise RuntimeError("API heartbeat did not stop before call cleanup")
            if heartbeat_errors:
                raise RuntimeError("API admission heartbeat failed during native media test")
            if sessions:
                for session in sessions:
                    request("/v1/rooms/" + room_id + "/leave", session, {})
                history = request("/v1/calls", sessions[0])["calls"]
                completed = next(call for call in history if call["id"] == call_id)
                if completed["status"] != "cancelled" or not completed.get("startedAt") or not completed.get("endedAt"):
                    raise RuntimeError("API call did not finish with a recorded duration")
                for session in sessions:
                    request("/v1/logout", session, {})
                    try:
                        request("/v1/me", session)
                    except urllib.error.HTTPError as error:
                        if error.code != 401:
                            raise
                    else:
                        raise RuntimeError("API logout did not revoke its session")
                print("Real API sharing, call completion/history and session revocation verified.")
        except Exception:
            failed = True
            raise
        finally:
            heartbeat_stop.set()
            if heartbeat_thread:
                heartbeat_thread.join(timeout=12)
            for process in reversed(processes):
                stop(process)
            for log in logs:
                log.close()
            if failed:
                # Only disposable synthetic services run here. Preserve failure
                # evidence before TemporaryDirectory deletes the server logs.
                destination = os.environ.get("PAIRWISE_TEST_LOG_DIR")
                if destination:
                    destination = pathlib.Path(destination)
                    destination.mkdir(parents=True, exist_ok=True)
                for name in ("api.log", "livekit.log"):
                    path = directory / name
                    if not path.exists():
                        continue
                    content = path.read_text(encoding="utf-8", errors="replace")
                    content = re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", "[redacted JWT]", content)
                    content = re.sub(r"(?i)Bearer\s+\S+", "Bearer [redacted]", content)
                    if destination:
                        (destination / name).write_text(content, encoding="utf-8")
                    print("Synthetic service failure log:", name, flush=True)
                    print("\n".join(content.splitlines()[-60:]), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=pathlib.Path)
    parser.add_argument("--server", type=pathlib.Path)
    parser.add_argument("--api", type=pathlib.Path, help="Pairwise API executable for real account/call/admission coverage")
    args = parser.parse_args()
    run(args.executable, args.server, args.api)
