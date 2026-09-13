export type TimingGranularity = "word" | "line";

export interface ResolveIdentity {
  playerID: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  spotifyID?: string;
  isrc?: string;
  appLocale: string;
}

export interface BrokerTimeline {
  granularity: TimingGranularity;
  attribution: string;
  source: string;
  matchConfidence: number;
  cacheExpiresAt: number;
  lines: Array<{
    at: number;
    text: string;
    words?: Array<{ at: number; text: string }>;
    isCredit?: boolean;
  }>;
}

export type ProviderResult =
  | {
      kind: "available";
      canonicalIdentity: { isrc?: string; providerTrackID?: string };
      territory: "allowed";
      timeline: BrokerTimeline;
    }
  | { kind: "unavailable"; territory?: "denied" | "unknown" }
  | { kind: "failed"; errorClass: "connection" | "rate_limited" | "service"; retryable: boolean };

export interface LicensedLyricsProvider {
  name: string;
  resolve(identity: ResolveIdentity): Promise<ProviderResult>;
}

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface AggregateMetrics {
  writeDataPoint(point: {
    blobs: [string, string, string];
    doubles: [number];
  }): void;
}

export interface BrokerEnvironment {
  INSTALLATION_TOKEN_SECRET: string;
  LYRICS_PROVIDER?: LicensedLyricsProvider;
  ENROLL_RATE_LIMITER?: RateLimiter;
  RESOLVE_RATE_LIMITER?: RateLimiter;
  EDGE_ABUSE_RATE_LIMITER?: RateLimiter;
  METRICS?: AggregateMetrics;
}

interface InstallationResponse {
  token: string;
}

const allowedFields = new Set([
  "playerID",
  "title",
  "artist",
  "album",
  "duration",
  "spotifyID",
  "isrc",
  "appLocale",
]);

const encoder = new TextEncoder();

function base64url(bytes: ArrayBuffer): string {
  const binary = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function hmac(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return base64url(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
}

async function hash(value: string): Promise<string> {
  return base64url(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

async function issueInstallationToken(secret: string): Promise<string> {
  const unsigned = "v1." + crypto.randomUUID();
  return unsigned + "." + await hmac(unsigned, secret);
}

async function validInstallationToken(token: string | null, secret: string): Promise<boolean> {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "v1" || !parts[1] || !parts[2]) return false;
  const expected = await hmac(parts[0] + "." + parts[1], secret);
  return parts[2] === expected;
}

async function requestAllowed(
  request: Request,
  limiter: RateLimiter | undefined,
  edgeLimiter: RateLimiter | undefined,
  subject: string,
): Promise<boolean> {
  if (!limiter || !edgeLimiter) return false;
  const subjectKey = await hash("subject:" + subject);
  if (!(await limiter.limit({ key: subjectKey })).success) return false;
  const edgeAddress = request.headers.get("CF-Connecting-IP") ?? "unknown";
  return (await edgeLimiter.limit({ key: await hash("edge:" + edgeAddress) })).success;
}

function record(
  environment: BrokerEnvironment,
  outcome: string,
  provider: string,
  errorClass: string,
  startedAt: number,
): void {
  environment.METRICS?.writeDataPoint({
    // No lyric text, title, artist, identifier, IP, or token enters metrics.
    blobs: [outcome, provider, errorClass],
    doubles: [Date.now() - startedAt],
  });
}

function badRequest(message: string): Response {
  return Response.json({ error: message }, { status: 400 });
}

function parseIdentity(payload: unknown): ResolveIdentity | null {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null;
  const record = payload as Record<string, unknown>;
  if (Object.keys(record).some((key) => !allowedFields.has(key))) return null;
  if (
    typeof record.playerID !== "string" ||
    typeof record.title !== "string" ||
    typeof record.artist !== "string" ||
    typeof record.album !== "string" ||
    typeof record.duration !== "number" ||
    typeof record.appLocale !== "string" ||
    record.title.trim().length === 0 ||
    record.artist.trim().length === 0 ||
    !Number.isFinite(record.duration) ||
    record.duration <= 0
  ) {
    return null;
  }
  if (
    (record.spotifyID !== undefined && typeof record.spotifyID !== "string") ||
    (record.isrc !== undefined && typeof record.isrc !== "string")
  ) {
    return null;
  }
  return record as unknown as ResolveIdentity;
}

function validTimeline(timeline: BrokerTimeline): boolean {
  return (
    (timeline.granularity === "word" || timeline.granularity === "line") &&
    timeline.attribution.trim().length > 0 &&
    timeline.source.trim().length > 0 &&
    Number.isFinite(timeline.matchConfidence) &&
    Number.isFinite(timeline.cacheExpiresAt) &&
    timeline.cacheExpiresAt > Date.now() / 1000 &&
    timeline.lines.length > 0
  );
}

async function enroll(request: Request, environment: BrokerEnvironment): Promise<Response> {
  const startedAt = Date.now();
  const allowed = await requestAllowed(
    request,
    environment.ENROLL_RATE_LIMITER,
    environment.EDGE_ABUSE_RATE_LIMITER,
    "installation",
  );
  if (!allowed) {
    record(environment, "rate_limited", "none", "enrollment", startedAt);
    return Response.json({ error: "rate_limited" }, { status: 429 });
  }
  const token = await issueInstallationToken(environment.INSTALLATION_TOKEN_SECRET);
  record(environment, "issued", "none", "none", startedAt);
  return Response.json({ token } satisfies InstallationResponse, { status: 201 });
}

async function resolve(request: Request, environment: BrokerEnvironment): Promise<Response> {
  const startedAt = Date.now();
  const token = request.headers.get("X-Isla-Installation-Token");
  if (!(await validInstallationToken(token, environment.INSTALLATION_TOKEN_SECRET))) {
    record(environment, "rejected", "none", "invalid_token", startedAt);
    return Response.json({ error: "invalid_installation_token" }, { status: 401 });
  }
  if (
    !(await requestAllowed(
      request,
      environment.RESOLVE_RATE_LIMITER,
      environment.EDGE_ABUSE_RATE_LIMITER,
      token!,
    ))
  ) {
    record(environment, "rate_limited", "none", "resolution", startedAt);
    return Response.json({ status: "failed", errorClass: "rate_limited", retryable: true }, { status: 429 });
  }

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    record(environment, "rejected", "none", "invalid_payload", startedAt);
    return badRequest("invalid_payload");
  }
  const identity = parseIdentity(payload);
  if (!identity) {
    record(environment, "rejected", "none", "invalid_payload", startedAt);
    return badRequest("invalid_payload");
  }

  const provider = environment.LYRICS_PROVIDER;
  if (!provider) {
    record(environment, "failed", "none", "unconfigured_provider", startedAt);
    return Response.json({ status: "failed", errorClass: "service", retryable: false }, { status: 503 });
  }

  let result: ProviderResult;
  try {
    result = await provider.resolve(identity);
  } catch {
    record(environment, "failed", provider.name, "service", startedAt);
    return Response.json({ status: "failed", errorClass: "service", retryable: true }, { status: 503 });
  }
  switch (result.kind) {
    case "available":
      if (!validTimeline(result.timeline)) {
        record(environment, "failed", provider.name, "invalid_provider_result", startedAt);
        return Response.json({ status: "failed", errorClass: "service", retryable: true }, { status: 503 });
      }
      if (result.timeline.matchConfidence < 0.85) {
        record(environment, "unavailable", provider.name, "weak_match", startedAt);
        return Response.json({ status: "unavailable", territory: "unknown" });
      }
      record(environment, "available", provider.name, "none", startedAt);
      return Response.json({
        status: "available",
        territory: result.territory,
        canonicalIdentity: result.canonicalIdentity,
        timeline: result.timeline,
      });
    case "unavailable":
      record(environment, "unavailable", provider.name, result.territory ?? "none", startedAt);
      return Response.json({ status: "unavailable", territory: result.territory ?? "unknown" });
    case "failed":
      record(environment, "failed", provider.name, result.errorClass, startedAt);
      return Response.json(
        { status: "failed", errorClass: result.errorClass, retryable: result.retryable },
        { status: result.errorClass === "rate_limited" ? 429 : 503 },
      );
  }
}

const worker = {
  async fetch(request: Request, environment: BrokerEnvironment, _context: ExecutionContext): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/v1/installations" && request.method === "POST") {
      return enroll(request, environment);
    }
    if (pathname === "/v1/lyrics/resolve" && request.method === "POST") {
      return resolve(request, environment);
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  },
};

export default worker;
