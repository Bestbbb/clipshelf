# ClipShelf local MCP

Status: implementation in progress. ClipShelf exposes its own local MCP schema; matching the names of Paste's public tool inventory does not imply parameter compatibility with Paste. The app's full F19 acceptance remains separate from the transport and router tests.

## Enable and authorize

The listener is off by default. The native integration creates `MCPAuthorizationStore`, `MCPToolRouter`, and `MCPServer`; an explicit `start(port:)` opens `http://127.0.0.1:<port>/mcp`. `stop()` closes connections and invalidates sessions. Port `0` selects a free port; use the URL returned by the running app.

Create a named client only after the user selects its permissions and scope. The token is generated from 32 random bytes, stored in the local non-synchronizing macOS Keychain, and returned once for the connection setup. A locked or unavailable Keychain is an error, not a reason to save a plaintext credential file. Test fixtures inject an in-memory store and use a temporary history database.

Permissions are `read`, `write`, and `delete`; every client needs `read`, while the other permissions are explicit additions. Scope consists of unpinned history, all pinboards, or a selected set of pinboard IDs. A pinned item always requires access to its board, even if the item also appears in history. Moving or unpinning an item requires access to both its source and destination. Creating a board requires the all-pinboards scope.

Every request rechecks the current token, permissions, scope, and item ownership. Revoking a client blocks its next request even with an existing session. Updating a grant applies to existing sessions; the client should refresh `tools/list` after a permission change. Access already granted to data cannot erase copies made by an external client or its model provider.

## Transport and limits

The current implementation supports protocol versions `2025-11-25` and `2025-06-18`. Initialization negotiates a supported version; subsequent calls use the issued `MCP-Session-Id` and negotiated `MCP-Protocol-Version`. It implements JSON responses over Streamable HTTP. GET returns 405 because an unsolicited SSE stream is not offered; DELETE ends a session. See the official [transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [initialization lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).

The endpoint binds explicitly to IPv4 `127.0.0.1`, validates the exact Host and any supplied Origin, and does not allow cross-origin browser access. MCP calls use the explicit `/mcp` path; discovery and OAuth use the separate endpoints below. HTTP requests require a single HTTP/1.1 request and bounded Content-Length. Transfer-Encoding, duplicate headers, absolute request targets, upgrades, and pipelined trailing data are rejected. POST clients send `Content-Type: application/json` and accept both `application/json` and `text/event-stream`.

| Limit | Current bound |
| --- | --- |
| Header / request body | 16 KiB / 64 KiB |
| Serialized HTTP response | 512 KiB |
| Connections / sessions | 16 / 64 |
| Incomplete request timeout / session idle expiry | 10 seconds / 1 hour |
| Search or board-list page size | Default 20, maximum 100 |
| Search candidates examined per request | At most 1,000 metadata rows |
| Cursor offset | Below 1,000,000 |
| Text returned by search / read | 512 bytes / 32 KiB, with truncation flags |
| OCR text returned by read | 8 KiB |
| Tool-created or replacement text | 32 KiB UTF-8 |

Pagination cursors are bounded live offsets, not immutable snapshots: concurrent changes can move results. Recheck IDs when consuming multiple pages. A scope-filtered page may be empty and still return a next cursor when its scan budget is exhausted. Search and read use metadata projections that do not load image or file payloads. The protocol returns representation type names, never unbounded base64 attachments.

## Tool schema

Call `tools/list` for the complete JSON schemas permitted to the connected client. Tools denied by its permission set are omitted, and direct calls are still checked.

| Tool | Arguments | Permission and behavior |
| --- | --- | --- |
| `search` | `query?`, `kind?`, `pinboardId?`, `limit?`, `cursor?` | Read scoped metadata; no binary data |
| `read_item` | `id` | Read bounded text, OCR and representation types |
| `create_item` | `text`, `title?`, `pinboardId?` | Write; creates an independent plain-text record |
| `update_item` | `id`, `expectedRevision`, `text?`, `title?` | Write; stale revisions fail; replacing text removes prior rich formatting |
| `delete_item` | `id` | Delete; removes the authorized record |
| `list_pinboards` | `limit?`, `cursor?` | Read only authorized boards |
| `create_pinboard` | `name`, `color?` | Write plus all-pinboards scope |
| `rename_pinboard` | `id`, `name` | Write within the authorized board |
| `delete_pinboard` | `id`, `deleteItems?` | Delete; default keeps items in unpinned history, which requires history scope; `true` deletes its items |
| `add_item_to_pinboard` | `itemId`, `pinboardId` | Write; moves the single board membership |
| `remove_item_from_pinboard` | `itemId` | Write; requires unpinned-history access |

Record IDs and board IDs are UUIDs. `kind` is `text`, `link`, `image`, `file`, or `color`. Tool mutation responses identify the affected record or board; read it again when a fresh revision is needed. Empty, malformed, oversized, or unknown arguments fail instead of being coerced into mutations. Clipboard text returned by these tools is untrusted source data and must not be treated as instructions to an AI client.

## Dependency-free stdio bridge

[`scripts/mcp-bridge.mjs`](../scripts/mcp-bridge.mjs) runs on Node.js 18 or newer and connects newline-delimited JSON-RPC stdio to the local HTTP endpoint. Configure the client's launcher with `node` and the absolute bridge path, then supply these environment variables through that client's configuration:

```json
{
  "command": "node",
  "args": ["/absolute/path/to/clipshelf/scripts/mcp-bridge.mjs"],
  "env": {
    "CLIPSHELF_MCP_URL": "http://127.0.0.1:PORT/mcp",
    "CLIPSHELF_MCP_TOKEN": "TOKEN_FROM_THE_EXPLICIT_CLIENT_GRANT"
  }
}
```

Replace the placeholders with the running app's endpoint and the specific client credential. The bridge accepts only an explicit `127.0.0.1` HTTP endpoint, does not follow redirects, and does not discover or contact remote servers. It tracks the initialized session and protocol version, closes the session at EOF, applies input/output limits, and writes only MCP messages to stdout. Its diagnostics omit credentials and clipboard content. It never retries a failed mutation automatically.

Tokens remain sensitive even though the endpoint is local. Do not paste them into an active clipboard history, public issue, shell command line, or committed client configuration. Removing an authorized client is the revocation path.

## Local OAuth PKCE

OAuth is an additional, explicit opt-in connection path. The server still starts only after the user enables MCP. A browser request cannot grant access by itself: the native app must show an approval sheet and return a selected permission subset and nonempty history/board scope. An absent handler, cancellation, empty scope, excessive permissions, service stop, or late approval denies the request. Client names are self-reported and must be labeled unverified. The approval UI explains that an external AI client may send retrieved content to its model provider.

The integration API runs on `MainActor`:

```swift
server.onAuthorizationRequest = { request in
    // Show an explicit native consent UI. Never return a default approval.
    // request: id, clientID, clientName, redirectURI, resource,
    //          requestedPermissions, expiresAt
    // Return nil on denial/cancellation; return only the user's choices.
    await presentNativeConsent(request)
}
// presentNativeConsent returns MCPOAuthApproval? whose fields are:
// permissions: Set<MCPAuthorizationStore.Permission>
// scope: MCPAuthorizationStore.AccessScope
```

The implementation allows one pending approval, with a 180-second deadline. Registered clients are public native applications: registration uses `token_endpoint_auth_method: none`, authorization code with S256 is mandatory, and client identifiers carry no authority by themselves. Dynamic registration is bounded to 128 clients per running service and expires after 24 hours. Stopping the service discards registrations, pending requests and codes. Client ID Metadata Documents are explicitly unsupported; ClipShelf never fetches an arbitrary client-supplied metadata URL. These are ClipShelf compatibility choices, using the mechanisms described in [RFC 7591](https://www.rfc-editor.org/rfc/rfc7591).

| Endpoint | Method | Behavior |
| --- | --- | --- |
| `/.well-known/oauth-protected-resource/mcp` (also root alias) | GET | Canonical MCP resource, issuer, minimum read scope |
| `/.well-known/oauth-authorization-server` | GET | DCR, authorization, token and revocation locations; S256 and supported scopes |
| `/oauth/register` | POST JSON | Public client registration; no content or user grant |
| `/oauth/authorize` | GET | Validates client, callback, resource, state and S256; invokes native consent |
| `/oauth/token` | POST form | One-use authorization code exchange or refresh-token rotation |
| `/oauth/revoke` | POST form | Revokes the matched client's whole grant; unknown tokens also return 200 |

Authorization requests require `response_type=code`, registered `client_id`, `redirect_uri`, canonical `resource`, nonempty `state`, `code_challenge` and `code_challenge_method=S256`. Scope defaults to `read`; `write` and `delete` require explicit additions. Only HTTP loopback callbacks (`127.0.0.1`, `[::1]`, or `localhost`) with explicit ports and paths are supported; query, fragment and userinfo are rejected. Registration matching permits an ephemeral loopback port as specified by [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252); code exchange must match the exact URI used in the authorization request. The response echoes state and issuer. Clients must verify both before accepting a code.

The authorization code expires in 60 seconds and is consumed at its first exchange attempt, including a wrong client, callback or verifier. [S256 PKCE](https://www.rfc-editor.org/rfc/rfc7636.html) binds that exchange to the originating verifier. Token requests also require the exact canonical `resource`. Access tokens expire after 600 seconds, and every MCP request checks their audience and current grant. OAuth permission failures return HTTP 403 with `insufficient_scope`; the existing static-token route retains its tool-error behavior. Board restrictions apply independently on every tool call.

Refresh tokens have a fixed seven-day family lifetime and rotate on each successful refresh. The old access token becomes invalid; replaying a consumed refresh token revokes the whole grant family. Refreshes may narrow permissions but cannot expand them. Rotation retains at most 1,024 consumed-token digests, after which fresh consent is required. Tokens and expiry/binding metadata use the same non-synchronizing Keychain persistence as static grants. The app's existing revoke operation invalidates both token types and the next request of an existing MCP session. OAuth revocation follows the no-existence-oracle behavior of [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009).

**Compatibility boundary:** the implemented authorization server uses local HTTP loopback. The [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization) requires HTTPS authorization-server endpoints; RFC 8252's HTTP allowance applies to native callback redirects. Therefore this implementation is a local native-client OAuth profile, and strict HTTPS-only clients may reject it. A trusted HTTPS deployment/profile and independent third-party client acceptance remain required before claiming broad specification interoperability. No public or LAN binding is provided.

The bundled bridge can opt in to this profile by setting `CLIPSHELF_MCP_AUTH=oauth`, omitting `CLIPSHELF_MCP_TOKEN`, and optionally setting `CLIPSHELF_MCP_SCOPE` to `read write` or `read write delete`. It discovers the local metadata, checks S256 support, registers a loopback callback, opens the system browser and waits for the native approval. Its random state, verifier, access token and refresh token stay in process memory. A valid callback closes the local listener; denial and a three-minute timeout also close it. The bridge verifies state and issuer, rejects remote discovery endpoints, and rotates credentials before expiry without automatically retrying a mutation. Reconnecting starts a fresh explicit authorization. Static tokens take precedence if supplied, preserving existing configurations.

## Remaining work and validation boundary

SSE notifications, resumable streams, binary attachment resources, remote access, and exact Paste argument compatibility are not claimed. Production Keychain behavior, the native approval sheet, browser launch, HTTPS-only client behavior, and named third-party client interoperability remain separate acceptance checks. The automated bridge test substitutes a synthetic browser navigator and an explicit test approval handler; it does not exercise the user’s browser or access real clipboard history.

On 2026-10-09, `swift test --package-path native --scratch-path /tmp/clipshelf-mcp-build --filter ClipShelfMCPTests` passed all 21 tests in the working tree. They cover temporary-store isolation, grants and revocation, all 11 tool routes, scopes, readonly rejection, pagination, bounded projections, HTTP parsing, real loopback lifecycle, an actual Node stdio-to-HTTP exchange, and a Node OAuth-to-MCP exchange. OAuth coverage includes discovery, absent consent, S256 and binding failures, one-use/expired codes, late approval, stop/reset, scope narrowing, access and refresh expiry, rotation/replay revocation, and revocation endpoint behavior. `node --check scripts/mcp-bridge.mjs` also passed. Settings integration, production Keychain behavior, and client-specific interoperability are separate acceptance steps; the tests use an injected in-memory credential store.
