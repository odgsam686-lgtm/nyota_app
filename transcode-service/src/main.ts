import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import dns from "node:dns";

dns.setDefaultResultOrder("ipv4first");

const SUPABASE_URL = process.env.SUPABASE_URL!;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET!;
const BUCKET = process.env.BUCKET || "posts";
const PORT = Number(process.env.PORT || 3000);
const MODE = process.env.MODE || "queue";
const WORKER_INTERVAL = Number(process.env.WORKER_INTERVAL || 2000);

if (!SUPABASE_URL) {
  console.error("Missing SUPABASE_URL.");
  process.exit(1);
}
if (!SUPABASE_SERVICE_ROLE_KEY) {
  console.error("Missing SUPABASE_SERVICE_ROLE_KEY.");
  process.exit(1);
}
if (!WEBHOOK_SECRET) {
  console.error("Missing WEBHOOK_SECRET.");
  process.exit(1);
}
if (!SUPABASE_URL.startsWith("https://") || !SUPABASE_URL.includes(".supabase.co")) {
  console.error("Invalid SUPABASE_URL. Expected https://<project-ref>.supabase.co");
  process.exit(1);
}
if (!WEBHOOK_SECRET.trim()) {
  console.error("WEBHOOK_SECRET must be non-empty.");
  process.exit(1);
}

const supabaseHost = new URL(SUPABASE_URL).hostname;
try {
  await dns.promises.lookup(supabaseHost);
} catch (e: any) {
  console.error(`DNS FAIL ${supabaseHost}`);
  console.error("Check your SUPABASE_URL or DNS settings.");
  throw e;
}

console.log("ENV CHECK", {
  SUPABASE_URL: !!process.env.SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
  WEBHOOK_SECRET: !!process.env.WEBHOOK_SECRET,
  BUCKET: process.env.BUCKET,
  MODE: process.env.MODE,
});

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function log(...args: unknown[]) {
  console.log(new Date().toISOString(), ...args);
}

function logStep(ctx: { requestId?: string; jobId?: string }, step: string, extra?: unknown) {
  log({
    step,
    requestId: ctx.requestId,
    jobId: ctx.jobId,
    extra,
  });
}

function isRetryableNetworkError(e: any) {
  const code = e?.cause?.code || e?.code;
  const msg = String(e?.message || "");
  const retryCodes = new Set([
    "ECONNRESET",
    "ETIMEDOUT",
    "EAI_AGAIN",
    "ENOTFOUND",
  ]);
  if (retryCodes.has(code)) return true;
  if (msg.includes("fetch failed")) return true;
  return false;
}

async function fetchWithRetry(
  url: string,
  options: RequestInit = {},
  attempts = 3,
  backoffMs = [500, 1500, 3500],
) {
  for (let i = 0; i < attempts; i += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const res = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timeout);
      return res;
    } catch (e: any) {
      clearTimeout(timeout);
      log("fetchWithRetry attempt", i + 1, "failed", e?.message || e);
      if (!isRetryableNetworkError(e) || i === attempts - 1) {
        throw e;
      }
      await new Promise((r) => setTimeout(r, backoffMs[i] || 3500));
    }
  }
  throw new Error("fetchWithRetry exhausted");
}

function normalizeObjectName(bucket: string, sourceName: string) {
  if (bucket === "posts") {
    let n = sourceName;
    while (n.startsWith("posts/")) {
      n = n.substring("posts/".length);
    }
    return n;
  }
  return sourceName;
}

function shouldIgnore(name: string) {
  if (name.includes("/variants/")) return true;
  return /\.(jpg|jpeg|png|webp)$/i.test(name);
}

function isLikelyVideo(name: string, contentType?: string) {
  if (contentType && contentType.startsWith("video/")) return true;
  return /\.(mp4|mov|mkv|webm)$/i.test(name);
}

function buildVariantPaths(objectName: string) {
  const dir = path.posix.dirname(objectName);
  const variantsDir = `${dir}/variants`;
  return {
    "360": `${variantsDir}/360p.mp4`,
    "720": `${variantsDir}/720p.mp4`,
    "1080": `${variantsDir}/1080p.mp4`,
  };
}

async function createSignedUrl(bucket: string, objectName: string) {
  const { data, error } = await supabase.storage
    .from(bucket)
    .createSignedUrl(objectName, 300);
  if (error || !data?.signedUrl) {
    throw error ?? new Error("Signed URL error");
  }
  return data.signedUrl;
}

async function uploadObject(
  bucket: string,
  objectName: string,
  filePath: string,
) {
  const body = await readFileBuffer(filePath);
  const { data, error } = await supabase.storage
    .from(bucket)
    .upload(objectName, body, {
      contentType: "video/mp4",
      upsert: true,
    });
  if (error) throw error;
  return data;
}

async function readFileBuffer(filePath: string) {
  const fs = await import("node:fs/promises");
  return fs.readFile(filePath);
}

async function updatePostVariants(
  sourceName: string,
  objectName: string,
  variants: Record<string, string>,
) {
  const { error } = await supabase
    .from("posts")
    .update({ video_variants: variants })
    .or(`media_path.eq.${sourceName},media_path.eq.${objectName}`);
  if (error) throw error;
}

function spawnFfmpeg(args: string[]) {
  return new Promise<void>((resolve, reject) => {
    const p = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] });
    let err = "";
    p.stderr.on("data", (d) => (err += d.toString()));
    p.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg failed: ${err}`));
    });
  });
}

async function runTranscode(
  bucket: string,
  sourceName: string,
  contentType?: string,
  ctx: { requestId?: string; jobId?: string } = {},
) {
  if (bucket !== BUCKET) return;
  if (shouldIgnore(sourceName)) return;
  if (!isLikelyVideo(sourceName, contentType)) return;

  const objectName = normalizeObjectName(bucket, sourceName);
  log("SOURCE", sourceName, "OBJECT", objectName);
  logStep(ctx, "download_start");

  let signedUrl: string;
  try {
    log("STEP 1: createSignedUrl start");
    signedUrl = await createSignedUrl(bucket, objectName);
    log("STEP 2: createSignedUrl done");
  } catch (e: any) {
    log("STEP 2B: createSignedUrl failed");
    console.error(e?.stack);
    console.error(e?.cause);
    throw e;
  }
  log("SIGNED URL CHECK", {
    length: signedUrl.length,
    https: signedUrl.startsWith("https://"),
    type: typeof signedUrl,
  });
  if (!signedUrl || !signedUrl.startsWith("https://")) {
    throw new Error("Invalid signedUrl");
  }

  const workDir = path.join("/tmp", `job_${Date.now()}`);
  mkdirSync(workDir, { recursive: true });

  const inputPath = path.join(workDir, "input.mp4");
  const res = await fetchWithRetry(signedUrl);
  log("FETCH RESULT:", res.status, res.ok);
  if (!res.ok) throw new Error(`Download failed: ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  await writeFile(inputPath, buf);

  const variants = buildVariantPaths(objectName);

  logStep(ctx, "transcode_start");
  for (const [key, targetPath] of Object.entries(variants)) {
    const height = Number(key);
    const outPath = path.join(workDir, `${key}.mp4`);
    log("FFMPEG", key, "START");
    await spawnFfmpeg([
      "-i", inputPath,
      "-vf", `scale='if(gt(ih,${height}),-2,iw)':'if(gt(ih,${height}),${height},ih)'`,
      "-c:v", "libx264",
      "-profile:v", "main",
      "-preset", "veryfast",
      "-crf", "23",
      "-c:a", "aac",
      "-b:a", "128k",
      "-movflags", "+faststart",
      outPath,
    ]);
    log("UPLOAD TARGET", targetPath);
    logStep(ctx, "upload_start", { targetPath });
    const data = await uploadObject(bucket, targetPath, outPath);
    log("UPLOAD OK", data);
  }

  logStep(ctx, "upload_ok");
  await updatePostVariants(sourceName, objectName, variants);
  logStep(ctx, "db_update_ok");

  rmSync(workDir, { recursive: true, force: true });
}

async function enqueueJob(bucket: string, objectName: string) {
  const { error } = await supabase.from("transcode_jobs").insert({
    bucket,
    object_name: objectName,
    status: "pending",
    attempts: 0,
  });
  if (error && !String(error.message).includes("duplicate")) {
    throw error;
  }
}

async function fetchNextJob() {
  const url = `${SUPABASE_URL}/rest/v1/transcode_jobs?status=eq.pending&order=created_at.asc&limit=1`;
  const headers = {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
  };
  const host = new URL(SUPABASE_URL).hostname;
  log("FETCH URL =", url);
  log("FETCH HOST =", host);
  try {
    const res = await fetchWithRetry(url, { headers });
    if (!res.ok) {
      throw new Error(`fetchNextJob failed: ${res.status} ${res.statusText}`);
    }
    const data = await res.json();
    return data?.[0];
  } catch (e: any) {
    log("FETCH FAILED:", e?.message);
    console.error(e);
    console.error(e?.cause);
    throw e;
  }
}

async function updateJob(id: string, fields: Record<string, unknown>) {
  const { error } = await supabase.from("transcode_jobs").update(fields).eq("id", id);
  if (error) throw error;
}

let workerBusy = false;

async function workerLoop() {
  if (MODE !== "queue") return;
  setInterval(async () => {
    if (workerBusy) return;
    workerBusy = true;
    let job: any;
    try {
      job = await fetchNextJob();
      if (!job) return;

      await updateJob(job.id, {
        status: "processing",
        attempts: (job.attempts ?? 0) + 1,
      });

      logStep({ jobId: job.id }, "webhook_received");
      await runTranscode(job.bucket, job.object_name, undefined, { jobId: job.id });

      await updateJob(job.id, { status: "done", error: null });
    } catch (e: any) {
      logStep({ jobId: job?.id }, "job_failed", e?.message || e);
      console.error(e);
      console.error(e?.stack);
      if (job?.id) {
        try {
          await updateJob(job.id, {
            status: "failed",
            error: String(e),
          });
        } catch {}
      }
    } finally {
      workerBusy = false;
    }
  }, WORKER_INTERVAL);
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && (req.url ?? "") === "/") {
    res.writeHead(200, { "content-type": "text/plain" }).end("ok");
    return;
  }
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, ts: new Date().toISOString(), version: "1.0.0" }));
    return;
  }
  if (req.method === "GET" && req.url === "/ready") {
    const url = `${SUPABASE_URL}/rest/v1/`;
    const headers = {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    };
    try {
      const probe = await fetchWithRetry(url, { method: "HEAD", headers });
      if (probe.ok) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } else {
        res.writeHead(503, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: false }));
      }
    } catch (e: any) {
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: e?.message || "fail" }));
    }
    return;
  }
  if (req.method !== "POST" || (req.url ?? "") !== "/webhooks/storage") {
    res.writeHead(404).end("not found");
    return;
  }

  const secret = req.headers["x-webhook-secret"];
  if (!secret || secret !== WEBHOOK_SECRET) {
    log("[WEBHOOK] invalid secret");
    res.writeHead(401).end("unauthorized");
    return;
  }

  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    let payload: any = {};
    try {
      payload = body ? JSON.parse(body) : {};
    } catch (e: any) {
      log("[WEBHOOK] invalid json");
      res.writeHead(400).end("invalid json");
      return;
    }

    const record = payload.record ?? payload.new ?? payload;
    const bucket = record.bucket_id ?? record.bucket ?? BUCKET;
    const sourceName =
      record.name ??
      record.media_path ??
      record.media_url ??
      payload.name ??
      payload.media_path ??
      payload.media_url;
    const contentType =
      record.content_type ??
      record.metadata?.mimetype ??
      payload.content_type ??
      "";
    const eventType =
      payload.type ?? payload.eventType ?? payload.event ?? "unknown";

    const requestId =
      record.id ?? record.object_id ?? record?.name ?? "unknown";

    log("[WEBHOOK] received", {
      requestId,
      bucket_id: bucket,
      name: sourceName,
      mimetype: contentType,
      eventType,
    });

    if (!sourceName) {
      log("[WEBHOOK] rejected (missing name)");
      res.writeHead(202).end("accepted");
      return;
    }
    if (bucket !== BUCKET) {
      log("[WEBHOOK] ignored (bucket mismatch)", { bucket });
      res.writeHead(202).end("accepted");
      return;
    }
    if (shouldIgnore(sourceName)) {
      log("[WEBHOOK] ignored (path)", { sourceName });
      res.writeHead(202).end("accepted");
      return;
    }
    if (!isLikelyVideo(sourceName, contentType)) {
      log("[WEBHOOK] ignored (not video)", { sourceName, contentType });
      res.writeHead(202).end("accepted");
      return;
    }

    res.writeHead(202).end("accepted");

    const objectName = normalizeObjectName(bucket, sourceName);
    const ctx = { requestId };

    if (MODE === "direct") {
      setImmediate(() => {
        runTranscode(bucket, sourceName, contentType, ctx).catch((e) => {
          log("[WEBHOOK] job_failed", e?.message || e);
          console.error(e?.stack);
        });
      });
    } else {
      setImmediate(() => {
        enqueueJob(bucket, objectName)
          .then(() => log("[WEBHOOK] job enqueued", { requestId }))
          .catch((e) => {
            log("[WEBHOOK] enqueue failed", e?.message || e);
            console.error(e?.stack);
          });
      });
    }
  });
});

server.listen(PORT, "0.0.0.0", () => {
  log(`API listening on :${PORT} (mode=${MODE})`);
});

workerLoop();
