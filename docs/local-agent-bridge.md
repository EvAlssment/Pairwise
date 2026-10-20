# Local coding-agent bridge

PairDesk can expose read-only context from the active call to an MCP client running on the same Mac. Nothing listens until the person opens the local transcript panel and chooses **Enable local agent access** with at least one capability selected.

The current prototype supports participant names and transcript text as separate grants. It creates a Unix-domain socket in the current user's Application Support directory, a call-scoped random credential, and a content-free JSONL audit log. The socket is restricted to the current user. Access ends when the person revokes it or the call ends; re-enabling creates a new credential. The bridge has no TCP listener, cloud endpoint, persistence of transcript text, microphone/audio access, screen stream, screenshot access, or remote-control operation. The MCP helper uses stdio and forwards only the two granted read operations to the local socket.

In a call, select **Participant names** and/or **Transcript text**, then enable access. Use **Copy MCP configuration** and add that JSON to the configured MCP client's server list. The copied credential applies only to the current call; after the call ends, enable access again and replace the token in that client's configuration. Revoking access invalidates the copied credential immediately.

MCP tools are `pairdesk_call_participants` and `pairdesk_call_transcript`. They accept no arguments. The helper lists only the tools granted for the current call; without a valid current-call credential, its tool list is empty. The helper is bundled at `PairDesk.app/Contents/MacOS/pairdesk-agent-mcp`. It supports MCP stdio using protocol revisions `2026-07-28` and the legacy `2025-11-25` initialize handshake. It never opens a network port.

Granting context to a local agent can cause that agent to send the granted names or transcript to its configured model provider, save it in its own history, or otherwise process it. PairDesk cannot control those downstream actions. Share only what is appropriate for that agent and revoke access when it is no longer needed.

The screenshot capability remains unimplemented. This prototype has not been validated against every MCP client, hardened against other processes running as the same macOS user, or tested under a notarized release. Treat it as an opt-in development feature until those checks are complete.
