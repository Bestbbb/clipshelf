#!/usr/bin/env node
import http from 'node:http';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';

const MAX_REQUEST_BYTES = 65_536;
const MAX_RESPONSE_BYTES = 524_288;
const VERSIONS = new Set(['2025-11-25', '2025-06-18']);

export function validateEndpoint(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Set a valid CLIPSHELF_MCP_URL.'); }
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' ||
      !url.port || Number(url.port) < 1 || Number(url.port) > 65535 ||
      url.pathname !== '/mcp' || url.search || url.hash || url.username || url.password) {
    throw new Error('CLIPSHELF_MCP_URL must be http://127.0.0.1:<port>/mcp.');
  }
  return url;
}

function validateToken(value) {
  if (typeof value !== 'string' || !/^cs_[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new Error('Set the client token in CLIPSHELF_MCP_TOKEN.');
  }
  return value;
}

export function createBridge({ url, token, getToken }) {
  const endpoint = validateEndpoint(url);
  const fixedCredential = getToken ? undefined : validateToken(token);
  let sessionID;
  let protocolVersion;

  async function sendHTTP(body, method = 'POST') {
    const credential = getToken ? validateToken(await getToken()) : fixedCredential;
    const bytes = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body), 'utf8');
    if (bytes.length > MAX_REQUEST_BYTES) return Promise.reject(new Error('MCP request is too large.'));
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'Content-Length': String(bytes.length),
      'Authorization': `Bearer ${credential}`,
    };
    if (sessionID) headers['MCP-Session-Id'] = sessionID;
    if (protocolVersion) headers['MCP-Protocol-Version'] = protocolVersion;
    return new Promise((resolve, reject) => {
      const request = http.request(endpoint, { method, headers, agent: false }, (response) => {
        const chunks = [];
        let total = 0;
        response.on('data', (chunk) => {
          total += chunk.length;
          if (total > MAX_RESPONSE_BYTES) {
            response.destroy();
            request.destroy();
            reject(new Error('MCP response is too large.'));
            return;
          }
          chunks.push(chunk);
        });
        response.on('error', () => reject(new Error('Local MCP response failed.')));
        response.on('end', () => {
          const status = response.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            reject(new Error(`Local MCP request failed (HTTP ${status}).`));
            return;
          }
          if (status === 202 || status === 204) { resolve(undefined); return; }
          if (!String(response.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) {
            reject(new Error('Local MCP server did not return JSON.'));
            return;
          }
          let json;
          try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
          catch { reject(new Error('Local MCP server returned invalid JSON.')); return; }
          if (!json || Array.isArray(json) || json.jsonrpc !== '2.0') {
            reject(new Error('Local MCP server returned an invalid message.'));
            return;
          }
          if (body?.method === 'initialize' && json.result) {
            const version = json.result.protocolVersion;
            const assigned = response.headers['mcp-session-id'];
            if (!VERSIONS.has(version) || typeof assigned !== 'string' || !/^[\x21-\x7E]{1,128}$/.test(assigned)) {
              reject(new Error('Unsupported MCP session or protocol version.'));
              return;
            }
            sessionID = assigned;
            protocolVersion = version;
          }
          resolve(json);
        });
      });
      request.setTimeout(10_000, () => request.destroy(new Error('Local MCP request timed out.')));
      request.on('error', () => reject(new Error('Cannot reach the local ClipShelf MCP server.')));
      request.end(bytes);
    });
  }

  return {
    async forward(message) {
      if (!message || typeof message !== 'object' || Array.isArray(message) || message.jsonrpc !== '2.0') {
        throw new Error('Expected one JSON-RPC 2.0 message.');
      }
      const response = await sendHTTP(message);
      if (Object.hasOwn(message, 'id') && response?.id !== message.id) {
        throw new Error('Local MCP response id did not match the request.');
      }
      return response;
    },
    async close() {
      if (!sessionID) return;
      try { await sendHTTP(undefined, 'DELETE'); } catch { /* Local app may already be closed. */ }
      sessionID = undefined;
      protocolVersion = undefined;
    },
  };
}

function localOAuthRequest(endpoint, path, body, json = false) {
  const bytes = body === undefined ? Buffer.alloc(0) : Buffer.from(json ? JSON.stringify(body) : new URLSearchParams(body).toString());
  if (bytes.length > MAX_REQUEST_BYTES) throw new Error('OAuth request exceeds the local limit.');
  return new Promise((resolve, reject) => {
    const request = http.request(new URL(path, endpoint), { method: body === undefined ? 'GET' : 'POST', agent: false, headers: {
      'Content-Type': json ? 'application/json' : 'application/x-www-form-urlencoded',
      'Content-Length': String(bytes.length), 'Accept': 'application/json',
    } }, (response) => {
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) { response.destroy(); request.destroy(); reject(new Error('OAuth response exceeds the local limit.')); }
        else chunks.push(chunk);
      });
      response.on('error', () => reject(new Error('Local OAuth response failed.')));
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) { reject(new Error('Local OAuth authorization failed.')); return; }
        try {
          const result = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error();
          resolve(result);
        } catch { reject(new Error('Local OAuth response was invalid.')); }
      });
    });
    request.setTimeout(10_000, () => request.destroy());
    request.on('error', () => reject(new Error('Cannot reach local OAuth endpoint.')));
    request.end(bytes);
  });
}

function openSystemBrowser(url) {
  return new Promise((resolve, reject) => {
    // Fixed executable and separate argument: no shell and no token in this URL.
    const child = spawn('/usr/bin/open', [url], { stdio: 'ignore' });
    child.on('error', () => reject(new Error('Cannot open the authorization browser.')));
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error('Cannot open the authorization browser.')));
  });
}

/** Explicit opt-in local OAuth client. Credentials stay in process memory only. */
export async function createOAuthCredentials({ url, scope = 'read', openAuthorizationURL = openSystemBrowser }) {
  const endpoint = validateEndpoint(url);
  const requested = scope.split(' ').filter(Boolean);
  if (!requested.includes('read') || requested.some((value) => !['read', 'write', 'delete'].includes(value))) {
    throw new Error('OAuth scope must include read and only read, write, delete.');
  }
  const resource = await localOAuthRequest(endpoint, '/.well-known/oauth-protected-resource/mcp');
  const metadata = await localOAuthRequest(endpoint, '/.well-known/oauth-authorization-server');
  if (resource.resource !== endpoint.href || !resource.authorization_servers?.includes(endpoint.origin) ||
      metadata.issuer !== endpoint.origin || !metadata.code_challenge_methods_supported?.includes('S256') ||
      metadata.authorization_endpoint !== `${endpoint.origin}/oauth/authorize` ||
      metadata.token_endpoint !== `${endpoint.origin}/oauth/token` ||
      metadata.registration_endpoint !== `${endpoint.origin}/oauth/register`) {
    throw new Error('Local OAuth discovery or S256 support did not match the configured endpoint.');
  }
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const state = randomBytes(32).toString('base64url');
  let redirectURI;
  let finish;
  let settled = false;
  const callbackResult = new Promise((resolve, reject) => { finish = (error, code) => {
    if (settled) return;
    settled = true;
    error ? reject(error) : resolve(code);
  }; });
  // Prevent a rejected browser/timeout promise becoming unhandled during registration.
  callbackResult.catch(() => {});
  const callback = http.createServer({ maxHeaderSize: 8_192 }, (request, response) => {
    const port = callback.address()?.port;
    if (request.method !== 'GET' || request.headers.host !== `127.0.0.1:${port}` ||
        request.headers.origin || request.headers['transfer-encoding'] || Number(request.headers['content-length'] ?? 0) !== 0 ||
        !request.url?.startsWith('/callback?') || request.url.length > 8_192) {
      response.writeHead(400); response.end(); return;
    }
    let incoming;
    try { incoming = new URL(request.url, redirectURI); } catch { response.writeHead(400); response.end(); return; }
    const parameters = incoming.searchParams;
    const returnedState = parameters.get('state') ?? '';
    if (incoming.pathname !== '/callback' || [...new Set(parameters.keys())].some((key) => parameters.getAll(key).length !== 1) ||
        !/^[A-Za-z0-9_-]{43}$/.test(returnedState) || !timingSafeEqual(Buffer.from(returnedState), Buffer.from(state)) ||
        (parameters.has('iss') && parameters.get('iss') !== endpoint.origin)) {
      response.writeHead(400); response.end(); return;
    }
    response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'", 'Connection': 'close' });
    response.end('ClipShelf authorization response received. You can close this tab.');
    const code = parameters.get('code');
    if (parameters.has('error') || !code || !/^csa_[A-Za-z0-9_-]{43}$/.test(code)) finish(new Error('ClipShelf authorization was denied.'));
    else finish(undefined, code);
  });
  callback.requestTimeout = 5_000;
  callback.headersTimeout = 5_000;
  callback.maxConnections = 4;
  await new Promise((resolve, reject) => { callback.once('error', reject); callback.listen(0, '127.0.0.1', resolve); });
  redirectURI = `http://127.0.0.1:${callback.address().port}/callback`;
  const timeout = setTimeout(() => finish(new Error('ClipShelf authorization timed out.')), 180_000);
  let clientID;
  let tokens;
  try {
    const registered = await localOAuthRequest(endpoint, '/oauth/register', { client_name: 'ClipShelf stdio bridge',
      redirect_uris: [redirectURI], token_endpoint_auth_method: 'none', response_types: ['code'],
      grant_types: ['authorization_code', 'refresh_token'] }, true);
    clientID = registered.client_id;
    if (typeof clientID !== 'string' || !/^csc_[A-Za-z0-9_-]{43}$/.test(clientID)) throw new Error('Local OAuth client registration failed.');
    const authorization = new URL('/oauth/authorize', endpoint);
    authorization.search = new URLSearchParams({ response_type: 'code', client_id: clientID, redirect_uri: redirectURI,
      resource: endpoint.href, scope: requested.join(' '), state, code_challenge: challenge, code_challenge_method: 'S256' });
    await openAuthorizationURL(authorization.href);
    const code = await callbackResult;
    tokens = await localOAuthRequest(endpoint, '/oauth/token', { grant_type: 'authorization_code', client_id: clientID,
      redirect_uri: redirectURI, resource: endpoint.href, code, code_verifier: verifier });
  } finally {
    clearTimeout(timeout);
    callback.close();
    callback.closeAllConnections?.();
  }
  function validateTokens(value) {
    validateToken(value.access_token);
    if (!/^csr_[A-Za-z0-9_-]{43}$/.test(value.refresh_token ?? '') || value.token_type !== 'Bearer' ||
        !Number.isInteger(value.expires_in) || value.expires_in < 60 || value.expires_in > 3_600) {
      throw new Error('Invalid local OAuth credentials.');
    }
    return Date.now() + (value.expires_in - 30) * 1000;
  }
  let refreshAt = validateTokens(tokens);
  let refreshing;
  return async () => {
    if (Date.now() >= refreshAt) {
      // Serialize rotation; never retry a refresh or a mutation after an ambiguous failure.
      refreshing ??= localOAuthRequest(endpoint, '/oauth/token', { grant_type: 'refresh_token', client_id: clientID,
        resource: endpoint.href, refresh_token: tokens.refresh_token }).then((next) => {
          refreshAt = validateTokens(next); tokens = next;
        });
      await refreshing;
      refreshing = undefined;
    }
    return tokens.access_token;
  };
}

export async function runBridge({ input = process.stdin, output = process.stdout, errorOutput = process.stderr,
                                  env = process.env } = {}) {
  const getToken = !env.CLIPSHELF_MCP_TOKEN && env.CLIPSHELF_MCP_AUTH === 'oauth'
    ? await createOAuthCredentials({ url: env.CLIPSHELF_MCP_URL, scope: env.CLIPSHELF_MCP_SCOPE ?? 'read' }) : undefined;
  const bridge = createBridge({ url: env.CLIPSHELF_MCP_URL, token: env.CLIPSHELF_MCP_TOKEN, getToken });
  let pending = Buffer.alloc(0);
  async function write(message) {
    if (!output.write(`${JSON.stringify(message)}\n`)) await once(output, 'drain');
  }
  async function handle(line) {
    if (line.length === 0) return;
    if (line.length > MAX_REQUEST_BYTES) throw new Error('MCP input line is too large.');
    let message;
    try { message = JSON.parse(line.toString('utf8')); }
    catch { await write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Invalid JSON input.' } }); return; }
    try {
      const response = await bridge.forward(message);
      if (response !== undefined) await write(response);
    } catch (error) {
      if (message && !Array.isArray(message) && Object.hasOwn(message, 'id') &&
          (typeof message.id === 'string' || typeof message.id === 'number')) {
        await write({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: error.message } });
      } else {
        errorOutput.write('ClipShelf MCP notification could not be delivered.\n');
      }
    }
  }
  try {
    for await (const chunk of input) {
      pending = Buffer.concat([pending, Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)]);
      let newline;
      while ((newline = pending.indexOf(10)) !== -1) {
        const line = pending.subarray(0, newline);
        pending = pending.subarray(newline + 1);
        await handle(line);
      }
      if (pending.length > MAX_REQUEST_BYTES) throw new Error('MCP input line is too large.');
    }
    if (pending.length) await handle(pending);
  } finally {
    await bridge.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runBridge().catch(() => {
    // Do not print request bodies, environment values, URLs, headers, or tokens.
    process.stderr.write('ClipShelf MCP bridge stopped. Check the local endpoint, client authorization, and input limits.\n');
    process.exitCode = 1;
  });
}
