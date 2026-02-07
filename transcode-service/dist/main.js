import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import { promises as dns } from "node:dns";
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET;
const BUCKET = process.env.BUCKET || "posts";
const PORT = Number(process.env.PORT || 3000);
const MODE = process.env.MODE || "queue";
const WORKER_INTERVAL = Number(process.env.WORKER_INTERVAL || 2000);
const supabaseHost = new URL(SUPABASE_URL).hostname;
try {
    await dns.lookup(supabaseHost);
}
catch (e) {
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
function log(...args) {
    console.log(new Date().toISOString(), ...args);
}
function normalizeObjectName(bucket, sourceName) {
    if (bucket === "posts") {
        let n = sourceName;
        while (n.startsWith("posts/")) {
            n = n.substring("posts/".length);
        }
        return n;
    }
    return sourceName;
}
function shouldIgnore(name) {
    if (name.includes("/variants/"))
        return true;
    return /\.(jpg|jpeg|png|webp)$/i.test(name);
}
function isLikelyVideo(name, contentType) {
    if (contentType && contentType.startsWith("video/"))
        return true;
    return /\.(mp4|mov|mkv|webm)$/i.test(name);
}
function buildVariantPaths(objectName) {
    const dir = path.posix.dirname(objectName);
    const variantsDir = `${dir}/variants`;
    return {
        "360": `${variantsDir}/360p.mp4`,
        "720": `${variantsDir}/720p.mp4`,
        "1080": `${variantsDir}/1080p.mp4`,
    };
}
async function createSignedUrl(bucket, objectName) {
    const { data, error } = await supabase.storage
        .from(bucket)
        .createSignedUrl(objectName, 300);
    if (error || !data?.signedUrl) {
        throw error ?? new Error("Signed URL error");
    }
    return data.signedUrl;
}
async function uploadObject(bucket, objectName, filePath) {
    const body = await readFileBuffer(filePath);
    const { data, error } = await supabase.storage
        .from(bucket)
        .upload(objectName, body, {
        contentType: "video/mp4",
        upsert: true,
    });
    if (error)
        throw error;
    return data;
}
async function readFileBuffer(filePath) {
    const fs = await import("node:fs/promises");
    return fs.readFile(filePath);
}
async function updatePostVariants(sourceName, objectName, variants) {
    const { error } = await supabase
        .from("posts")
        .update({ video_variants: variants })
        .or(`media_path.eq.${sourceName},media_path.eq.${objectName}`);
    if (error)
        throw error;
}
function spawnFfmpeg(args) {
    return new Promise((resolve, reject) => {
        const p = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] });
        let err = "";
        p.stderr.on("data", (d) => (err += d.toString()));
        p.on("close", (code) => {
            if (code === 0)
                resolve();
            else
                reject(new Error(`ffmpeg failed: ${err}`));
        });
    });
}
async function runTranscode(bucket, sourceName, contentType) {
    if (bucket !== BUCKET)
        return;
    if (shouldIgnore(sourceName))
        return;
    if (!isLikelyVideo(sourceName, contentType))
        return;
    const objectName = normalizeObjectName(bucket, sourceName);
    log("SOURCE", sourceName, "OBJECT", objectName);
    let signedUrl;
    try {
        log("STEP 1: createSignedUrl start");
        signedUrl = await createSignedUrl(bucket, objectName);
        log("STEP 2: createSignedUrl done");
    }
    catch (e) {
        log("STEP 2B: createSignedUrl failed");
        console.error(e?.stack);
        console.error(e?.cause);
        throw e;
    }
    log("FETCHING URL:", signedUrl);
    log("FETCHING URL (worker):", signedUrl);
    log("FETCHING URL LENGTH:", signedUrl.length);
    log("FETCHING URL HTTPS:", signedUrl.startsWith("https://"));
    log("FETCHING URL TYPE:", typeof signedUrl);
    if (!signedUrl || !signedUrl.startsWith("https://")) {
        throw new Error("Invalid signedUrl");
    }
    const workDir = path.join("/tmp", `job_${Date.now()}`);
    mkdirSync(workDir, { recursive: true });
    const inputPath = path.join(workDir, "input.mp4");
    const res = await fetch(signedUrl);
    log("FETCH RESULT:", res.status, res.ok);
    if (!res.ok)
        throw new Error(`Download failed: ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    await writeFile(inputPath, buf);
    const variants = buildVariantPaths(objectName);
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
        const data = await uploadObject(bucket, targetPath, outPath);
        log("UPLOAD OK", data);
    }
    await updatePostVariants(sourceName, objectName, variants);
    rmSync(workDir, { recursive: true, force: true });
}
async function enqueueJob(bucket, objectName) {
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
    log("FETCH HEADERS =", headers);
    try {
        const res = await fetch(url, { headers });
        if (!res.ok) {
            throw new Error(`fetchNextJob failed: ${res.status} ${res.statusText}`);
        }
        const data = await res.json();
        return data?.[0];
    }
    catch (e) {
        log("FETCH FAILED:", e?.message);
        console.error(e);
        console.error(e?.cause);
        throw e;
    }
}
async function updateJob(id, fields) {
    const { error } = await supabase.from("transcode_jobs").update(fields).eq("id", id);
    if (error)
        throw error;
}
let workerBusy = false;
async function workerLoop() {
    if (MODE !== "queue")
        return;
    setInterval(async () => {
        if (workerBusy)
            return;
        workerBusy = true;
        let job;
        try {
            job = await fetchNextJob();
            if (!job)
                return;
            await updateJob(job.id, {
                status: "processing",
                attempts: (job.attempts ?? 0) + 1,
            });
            await runTranscode(job.bucket, job.object_name);
            await updateJob(job.id, { status: "done", error: null });
        }
        catch (e) {
            log("JOB FAILED", e?.message || e);
            if (job?.id) {
                try {
                    await updateJob(job.id, {
                        status: "failed",
                        error: String(e),
                    });
                }
                catch { }
            }
        }
        finally {
            workerBusy = false;
        }
    }, WORKER_INTERVAL);
}
const server = http.createServer(async (req, res) => {
    if (req.method !== "POST" || req.url !== "/webhooks/storage") {
        res.writeHead(404).end("not found");
        return;
    }
    const secret = req.headers["x-webhook-secret"];
    if (!secret || secret !== WEBHOOK_SECRET) {
        res.writeHead(401).end("unauthorized");
        return;
    }
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
        try {
            const payload = JSON.parse(body);
            const record = payload.record ?? payload;
            const bucket = record.bucket_id ?? record.bucket ?? BUCKET;
            const sourceName = record.name ??
                record.media_path ??
                record.media_url ??
                payload.name ??
                payload.media_path ??
                payload.media_url;
            const contentType = record.content_type ?? payload.content_type ?? "";
            if (!sourceName) {
                res.writeHead(400).end("missing name");
                return;
            }
            if (bucket !== BUCKET) {
                res.writeHead(200).end("ignored bucket");
                return;
            }
            if (shouldIgnore(sourceName)) {
                res.writeHead(200).end("ignored path");
                return;
            }
            if (!isLikelyVideo(sourceName, contentType)) {
                res.writeHead(200).end("not video");
                return;
            }
            const objectName = normalizeObjectName(bucket, sourceName);
            if (MODE === "direct") {
                runTranscode(bucket, sourceName, contentType).catch((e) => log("DIRECT FAILED", e));
            }
            else {
                await enqueueJob(bucket, objectName);
            }
            res.writeHead(202).end("accepted");
        }
        catch (e) {
            log("WEBHOOK ERROR", e);
            res.writeHead(500).end("error");
        }
    });
});
server.listen(PORT, () => {
    log(`API listening on :${PORT} (mode=${MODE})`);
});
workerLoop();
