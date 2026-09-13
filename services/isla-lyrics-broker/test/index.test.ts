import { describe, expect, it } from "vitest";
import worker, {
  type BrokerEnvironment,
  type LicensedLyricsProvider,
} from "../src/index";

const requestIdentity = {
  playerID: "music",
  title: "Private song title",
  artist: "Private artist",
  album: "Private album",
  duration: 180,
  appLocale: "en",
};

function environment(overrides: Partial<BrokerEnvironment> = {}): BrokerEnvironment {
  const provider: LicensedLyricsProvider = {
    name: "mock-licensed-provider",
    async resolve() {
      return {
        kind: "available",
        canonicalIdentity: { isrc: "USRC17607839" },
        territory: "allowed",
        timeline: {
          granularity: "word",
          attribution: "Mock licensed lyrics",
          source: "mock-licensed-provider",
          matchConfidence: 0.99,
          cacheExpiresAt: Date.now() / 1000 + 300,
          lines: [{ at: 0, text: "Opening line", words: [] }],
        },
      };
    },
  };
  return {
    INSTALLATION_TOKEN_SECRET: "test-secret",
    LYRICS_PROVIDER: provider,
    ENROLL_RATE_LIMITER: { async limit() { return { success: true }; } },
    RESOLVE_RATE_LIMITER: { async limit() { return { success: true }; } },
    EDGE_ABUSE_RATE_LIMITER: { async limit() { return { success: true }; } },
    ...overrides,
  };
}

async function installationToken(env: BrokerEnvironment): Promise<string> {
  const response = await worker.fetch(
    new Request("https://broker.example/v1/installations", { method: "POST" }),
    env,
    {} as ExecutionContext,
  );
  expect(response.status).toBe(201);
  return (await response.json() as { token: string }).token;
}

describe("isla lyrics broker", () => {
  it("issues an anonymous signed installation token and resolves only allowed identity fields", async () => {
    const env = environment();
    const token = await installationToken(env);
    const response = await worker.fetch(
      new Request("https://broker.example/v1/lyrics/resolve", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Isla-Installation-Token": token,
        },
        body: JSON.stringify(requestIdentity),
      }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      status: "available",
      territory: "allowed",
      canonicalIdentity: { isrc: "USRC17607839" },
      timeline: { granularity: "word", lines: [{ text: "Opening line" }] },
    });
  });

  it("rejects playback, library and account data before a provider receives the request", async () => {
    let calls = 0;
    const env = environment({
      LYRICS_PROVIDER: {
        name: "mock-licensed-provider",
        async resolve() {
          calls += 1;
          return { kind: "unavailable" };
        },
      },
    });
    const token = await installationToken(env);
    const response = await worker.fetch(
      new Request("https://broker.example/v1/lyrics/resolve", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Isla-Installation-Token": token,
        },
        body: JSON.stringify({ ...requestIdentity, playbackPosition: 12 }),
      }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(400);
    expect(calls).toBe(0);
  });

  it("rate limits resolution and records only aggregate metrics", async () => {
    const metrics: unknown[] = [];
    const env = environment({
      RESOLVE_RATE_LIMITER: { async limit() { return { success: false }; } },
      METRICS: { writeDataPoint(point) { metrics.push(point); } },
    });
    const token = await installationToken(env);
    const response = await worker.fetch(
      new Request("https://broker.example/v1/lyrics/resolve", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Isla-Installation-Token": token,
        },
        body: JSON.stringify(requestIdentity),
      }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(429);
    expect(JSON.stringify(metrics)).not.toContain(requestIdentity.title);
    expect(JSON.stringify(metrics)).not.toContain(requestIdentity.artist);
  });

  it("fails closed when no licensed provider adapter is configured", async () => {
    const env = environment();
    delete env.LYRICS_PROVIDER;
    const token = await installationToken(env);
    const response = await worker.fetch(
      new Request("https://broker.example/v1/lyrics/resolve", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Isla-Installation-Token": token,
        },
        body: JSON.stringify(requestIdentity),
      }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      status: "failed",
      errorClass: "service",
      retryable: false,
    });
  });

  it("fails closed when rate-limit bindings have not been released", async () => {
    const env = environment();
    delete env.ENROLL_RATE_LIMITER;
    const response = await worker.fetch(
      new Request("https://broker.example/v1/installations", { method: "POST" }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(429);
  });

  it("fails closed when the edge-abuse binding has not been released", async () => {
    const env = environment();
    delete env.EDGE_ABUSE_RATE_LIMITER;
    const response = await worker.fetch(
      new Request("https://broker.example/v1/installations", { method: "POST" }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(429);
  });

  it("rejects a weak provider match instead of returning potentially wrong lyrics", async () => {
    const env = environment({
      LYRICS_PROVIDER: {
        name: "mock-licensed-provider",
        async resolve() {
          return {
            kind: "available",
            canonicalIdentity: {},
            territory: "allowed",
            timeline: {
              granularity: "line",
              attribution: "Mock licensed lyrics",
              source: "mock-licensed-provider",
              matchConfidence: 0.4,
              cacheExpiresAt: Date.now() / 1000 + 300,
              lines: [{ at: 0, text: "Wrong line" }],
            },
          };
        },
      },
    });
    const token = await installationToken(env);
    const response = await worker.fetch(
      new Request("https://broker.example/v1/lyrics/resolve", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Isla-Installation-Token": token,
        },
        body: JSON.stringify(requestIdentity),
      }),
      env,
      {} as ExecutionContext,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "unavailable" });
  });
});
