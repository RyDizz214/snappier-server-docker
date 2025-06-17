// Enhanced node-notifier shim that posts to Snappier's internal webhook
// and tries to pass structured fields for EPG enrichment.
//
// HOW IT WORKS
// - Accepts the same .notify(options, cb) API as node-notifier.
// - Builds a JSON payload for /notify with:
//     action   -> inferred from title/body to match webhook _ACTION_MAP
//     program  -> best guess from title/body or parsed TS filename
//     channel  -> best guess from title/body or parsed TS filename
//     job_id   -> parsed from filename or body if present
//     file     -> if a .ts path appears
//     title    -> fallback human title (not used for action mapping)
//     desc     -> original message/body (webhook trims/uses as description)
// - Sends to NOTIFY_URL (default http://127.0.0.1:9080/notify)
//
// ENV
//   NOTIFY_URL=http://127.0.0.1:9080/notify
//   NOTIFIER_DEBUG=1                 -> verbose logs
//   NOTIFIER_HOOK_HEALTH=http://127.0.0.1:9080/health (optional preflight)
//
// INSTALL (one of):
//   A) Override module at runtime by placing this file as:
//      /opt/overrides/node-notifier/index.js  and set NODE_PATH=/opt/overrides
//   B) Replace app's node_modules copy:
//      <app>/node_modules/node-notifier/index.js  (if the app vendored it)
//
// NOTE: Using this AND log_monitor.sh may duplicate pushes. Pick one path if desired.

const http = require('http');
const url = require('url');

const NOTIFY_URL = process.env.NOTIFY_URL || 'http://127.0.0.1:9080/notify';
const HEALTH_URL = process.env.NOTIFIER_HOOK_HEALTH || (NOTIFY_URL.replace(/\/notify(\b|$)/, '/health'));
const DEBUG = !!process.env.NOTIFIER_DEBUG;

let callCount = 0;

// ─────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────
function dlog(...args) { if (DEBUG) console.log('🔔[notifier]', ...args); }
function derr(...args) { console.error('❌[notifier]', ...args); }

function toLower(s) { return (s || '').toString().toLowerCase(); }

// Try to parse Channel/Program/Start/End/UUID from Snappier TS naming:
//   Recording:  Channel--Program--START--END--UUID.ts
//   Catch-up :  --Program--START--UUID.ts
function parseTsMeta(p) {
  if (!p) return null;
  try {
    const file = (p.split('/').pop() || '').replace(/\.ts$/i, '');
    const parts = file.split('--');
    let kind, channel = '', program = '', start = '', end = '', uuid = '';

    if (parts[0] === '') {
      // catch-up
      kind = 'catchup';
      program = (parts[1] || '').replace(/_+/g, ' ').trim();
      start   = parts[2] || '';
      uuid    = parts[3] || '';
    } else {
      // recording/live
      kind    = 'recording';
      channel = (parts[0] || '').replace(/_+/g, ' ').trim();
      program = (parts[1] || '').replace(/_+/g, ' ').trim();
      start   = parts[2] || '';
      end     = parts[3] || '';
      uuid    = parts[4] || '';
    }
    return { kind, channel, program, start, end, uuid };
  } catch {
    return null;
  }
}

// Weak extract of .ts path and job id from free text
function findTsPath(text) {
  const m = /(?:^|\s)(\/[\w\/.\-]+\.ts)\b/i.exec(text || '');
  return m ? m[1] : null;
}
function findJobId(text) {
  const m = /\b([a-f0-9]{8}-[a-f0-9-]{27,36})\b/i.exec(text || '');
  return m ? m[1] : null;
}

// Inference rules -> webhook _ACTION_MAP keys
function inferAction(title, body) {
  const t = toLower(title);
  const b = toLower(body);
  const txt = `${t} ${b}`;

  // Very specific → general
  if (/\b(save\s*catch|catch-?up)\b/.test(txt)) {
    if (/\b(start|begin|download(ed)?|downloading)\b/.test(txt)) return 'catchup_started';
    if (/\b(finish|complete(d)?|done)\b/.test(txt))              return 'catchup_completed';
    if (/\b(fail|error|abort|cancelled?)\b/.test(txt))           return 'catchup_failed';
  }

  if (/\b(movie)\b/.test(txt)) {
    if (/\b(start|begin|download(ed)?|downloading)\b/.test(txt)) return 'movie_started';
    if (/\b(finish|complete(d)?|done)\b/.test(txt))              return 'movie_completed';
    if (/\b(fail|error|abort|cancelled?)\b/.test(txt))           return 'movie_failed';
  }

  if (/\b(series|episode)\b/.test(txt)) {
    if (/\b(start|begin|download(ed)?|downloading)\b/.test(txt)) return 'series_started';
    if (/\b(finish|complete(d)?|done)\b/.test(txt))              return 'series_completed';
    if (/\b(fail|error|abort|cancelled?)\b/.test(txt))           return 'series_failed';
  }

  if (/\b(record(ing)?)\b/.test(txt)) {
    if (/\b(schedule(d)?|queued?)\b/.test(txt))                  return 'recording_scheduled';
    if (/\b(start|begin)\b/.test(txt))                           return 'recording_started';
    if (/\b(finish|complete(d)?|done)\b/.test(txt))              return 'recording_completed';
    if (/\b(fail|error|abort|cancelled?)\b/.test(txt))           return 'recording_failed';
  }

  if (/\b(health|warning|degraded)\b/.test(txt))                 return 'health_warn';
  if (/\b(server)\b/.test(txt) && /\b(error|fail)\b/.test(txt))  return 'server_error';

  // Fallback: let webhook pick title from payload
  return '';
}

// urgency/sound decoration is no longer critical (webhook sets priority),
// but we keep a simple mapping for logging/debug parity with your original.
function classifyTone(title, body) {
  const txt = toLower(`${title} ${body}`);
  if (/\b(error|fail|failed|fatal)\b/.test(txt)) return { urgency: 'high',   sound: 'siren'   };
  if (/\b(complete|finished|done)\b/.test(txt)) return { urgency: 'normal', sound: 'magic'   };
  if (/\b(start|begin|download)\b/.test(txt))   return { urgency: 'normal', sound: 'pushover' };
  if (/\b(schedul)\b/.test(txt))                return { urgency: 'low',    sound: 'bike'    };
  return { urgency: 'normal', sound: 'pushover' };
}

// POST helper
function postJson(targetUrl, obj, cb) {
  const u = url.parse(targetUrl);
  const data = Buffer.from(JSON.stringify(obj));
  const req = http.request({
    hostname: u.hostname,
    port: u.port || 80,
    path: u.path || '/notify',
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': data.length }
  }, (res) => {
    let chunks = '';
    res.on('data', c => chunks += c);
    res.on('end', () => {
      if (res.statusCode === 200) {
        dlog(`✅ delivered (${res.statusCode})`, chunks);
        cb && cb(null, chunks);
      } else {
        derr(`HTTP ${res.statusCode}: ${chunks}`);
        cb && cb(new Error(`HTTP ${res.statusCode}`));
      }
    });
  });
  req.on('error', (e) => { derr('request error', e.message); cb && cb(e); });
  req.write(data); req.end();
}

// Optional preflight
function healthCheck(cb) {
  if (!HEALTH_URL) return cb && cb();
  const u = url.parse(HEALTH_URL);
  const req = http.request({
    hostname: u.hostname, port: u.port || 80, path: u.path || '/health', method: 'GET', timeout: 1000
  }, (res) => { res.resume(); cb && cb(); });
  req.on('error', () => cb && cb());
  req.on('timeout', () => { try { req.destroy(); } catch {} cb && cb(); });
  req.end();
}

// ─────────────────────────────────────────────────────────────
// Core notify() (node-notifier API)
// ─────────────────────────────────────────────────────────────
function notify(options, callback) {
  dlog('notify() called with:', JSON.stringify(options, null, 2));
  if (typeof options === 'string') options = { message: options };
  options = options || {};

  // Normalize raw inputs from various libs
  const title = options.title || options.subtitle || 'Snappier';
  const body  = options.message || options.body || options.text || '';
  const mergedText = `${title}\n${body}`;

  // Try to find a .ts path, then derive meta
  let filePath = options.file || findTsPath(mergedText);
  let meta = filePath ? parseTsMeta(filePath) : null;

  // Try to extract a job id if not in filename
  let jobId = options.job_id || (meta && meta.uuid) || findJobId(mergedText) || '';

  // Some apps pass channel/program somewhere else
  const program = options.program || (meta && meta.program) || title || '';
  const channel = options.channel || (meta && meta.channel) || '';

  // Map to webhook action keys
  let action = options.action || inferAction(title, body);

  // Build payload for webhook
  const payload = {
    action,                    // key for _ACTION_MAP (empty -> webhook will fallback)
    program,
    channel,
    job_id: jobId || undefined,
    file: filePath || undefined,
    title,                     // human title fallback
    desc: body                 // put original message into 'desc' for webhook
  };

  // Add tone (purely informational; webhook does final priority)
  payload._tone = classifyTone(title, body);

  console.log(`📱 [node-notifier] Sending notification #${++callCount}`);
  dlog(`raw options: ${JSON.stringify(options)}`);
  dlog(`payload: ${JSON.stringify(payload)}`);

  const done = (err) => {
    if (typeof callback === 'function') {
      // keep compatibility with async callback
      setTimeout(() => callback(err || null, err ? 'error' : 'sent'), 50);
    }
  };

  // Quick health probe, then send
  healthCheck(() => {
    postJson(NOTIFY_URL, payload, done);
  });

  return true;
}

// Compatibility façade (node-notifier exports)
const nodeNotifier = {
  notify,
  NotificationCenter: { notify },
  WindowsToaster:     { notify },
  WindowsBalloon:     { notify },
  NotifySend:         { notify },
  Growl:              { notify }
};
nodeNotifier.default = nodeNotifier;

module.exports = nodeNotifier;
module.exports.default = nodeNotifier;
module.exports.notify = notify;

// Optional global debug hook (OFF by default)
// Enable with: NOTIFIER_DEBUG_HOOK=1
if (process.env.NOTIFIER_DEBUG_HOOK) {
  const originalConsoleLog = console.log;
  console.log = function (...args) {
    const message = args.join(' ');
    if (message.match(/notify|notification|pushover|snappier/i)) {
      originalConsoleLog('🔍 [DEBUG] potential notification log:', ...args);
    }
    return originalConsoleLog.apply(console, args);
  };
}

console.log('🔔 [node-notifier] Enhanced shim loaded');
