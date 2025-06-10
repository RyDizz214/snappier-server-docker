// Refined Snappier Log Monitor for Push Notifications with Job Tracking
const http = require('http');
const { spawn } = require('child_process');

console.log('🔗 [webhook] Snappier log monitor starting...');

// Job tracking to remember titles for completion notifications
const activeJobs = new Map();
const recentCancellations = new Set();
const suppressedCompletions = new Set();
const recentSchedulingContext = {
    lastScheduleTime: 0,
    potentialTitle: null,
    potentialJobId: null,
    potentialChannel: null,
    scheduledTime: null,
    isImmediate: false,
    notificationSent: false
};

// Send notification helper
function sendNotification(title, body, urgency = 'normal') {
    const notificationData = { title, body, options: { urgency, sound: urgency === 'high' ? 'siren' : urgency === 'low' ? 'bike' : 'pushover' } };
    const postData = JSON.stringify(notificationData);
    const requestOptions = {
        hostname: 'localhost',
        port: 9080,
        path: '/notify',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) }
    };
    const req = http.request(requestOptions, res => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
            if (res.statusCode === 200) console.log(`📱 [webhook] Notification sent: "${title}"`);
            else console.error(`❌ [webhook] Notification failed: ${res.statusCode} - ${data}`);
        });
    });
    req.on('error', err => console.error('❌ [webhook] Notification error:', err.message));
    req.write(postData);
    req.end();
}

// Utility functions
function extractJobId(msg) {
    const m = msg.match(/job-id: ([a-f0-9-]+)/);
    return m ? m[1] : null;
}
function getShortJobId(id) {
    return id ? id.substring(0, 8) : 'unknown';
}
function cleanTitle(t) {
    return t.replace(/^[A-Z]{2}\s*-\s*/i, '')
            .replace(/\s+/g, ' ')
            .replace(/ᴺᵉʷ/g, '')
            .trim();
}
function extractProgramNameFromFilename(fn) {
    const m = fn.match(/--([^-]+)--\d{8}T\d{6}-\d{4}----[a-f0-9-]+\.(ts|mp4)/);
    return m ? m[1].replace(/_/g, ' ').trim() : null;
}

// Core log processor
function processLogLine(line) {
    const message = line.toString();

    // --- Recording scheduling and start ---
    if (message.includes('POST /ScheduleRecording') && message.includes('200')) {
        const now = Date.now();
        if (!recentSchedulingContext.notificationSent) {
            const id = recentSchedulingContext.potentialJobId;
            const shortId = getShortJobId(id);
            let scheduledTime = recentSchedulingContext.scheduledTime || '';
            const timeMatch = message.match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
            if (!scheduledTime && timeMatch) scheduledTime = new Date(timeMatch[1] + '.000Z').toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
            if (recentSchedulingContext.isImmediate) {
                const title = cleanTitle(recentSchedulingContext.potentialTitle || 'Recording');
                const channel = cleanTitle(recentSchedulingContext.potentialChannel || '');
                sendNotification(
                    'Recording Started 🔴',
                    channel ? `"${title}" on ${channel} (${shortId})` : `"${title}" (${shortId})`,
                    'normal'
                );
                activeJobs.set(id, { type: 'recording', title, channel, startTime: now });
            } else {
                const title = cleanTitle(recentSchedulingContext.potentialTitle || 'Recording');
                sendNotification(
                    'Recording Scheduled 🗓️',
                    title !== 'Recording'
                        ? `"${title}" scheduled (${shortId}) for ${scheduledTime}`
                        : `New recording scheduled (${shortId}) for ${scheduledTime}`,
                    'low'
                );
                activeJobs.set(id, { type: 'scheduled', title, startTime: now });
            }
            recentSchedulingContext.notificationSent = true;
        }
        setTimeout(() => Object.assign(recentSchedulingContext, {
            lastScheduleTime: 0,
            potentialTitle: null,
            potentialJobId: null,
            potentialChannel: null,
            scheduledTime: null,
            isImmediate: false,
            notificationSent: false
        }), 10000);
        return;
    }
    if (message.includes('immediate branch: starting recording now for')) {
        const m = message.match(/starting recording now for (.+?) on (.+)$/);
        if (m) {
            recentSchedulingContext.potentialTitle = m[1];
            recentSchedulingContext.potentialChannel = m[2];
            recentSchedulingContext.isImmediate = true;
        }
        return;
    }
    if (message.includes('scheduling start_') || message.includes('scheduling stop_')) {
        const id = message.match(/(?:start_|stop_)([a-f0-9-]+)/)?.[1];
        if (id) {
            recentSchedulingContext.potentialJobId = id;
            if (recentSchedulingContext.isImmediate && recentSchedulingContext.potentialTitle) {
                activeJobs.set(id, { type: 'recording', title: recentSchedulingContext.potentialTitle, channel: recentSchedulingContext.potentialChannel, startTime: Date.now() });
            }
        }
        const t = message.match(/at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/)?.[1];
        if (t) recentSchedulingContext.scheduledTime = new Date(t + '.000Z').toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
        return;
    }
    if (message.includes('[SSE] Emitting "scheduleCreated"')) {
        recentSchedulingContext.lastScheduleTime = Date.now();
        recentSchedulingContext.notificationSent = false;
        return;
    }

    // --- Movie downloads ---
    if (message.includes('Scheduling movie') && message.includes('job-id:')) {
        const m = message.match(/Scheduling movie "([^"]+)" \(job-id: ([a-f0-9-]+)\)/);
        if (m) {
            const title = cleanTitle(m[1]);
            const id = m[2];
            const shortId = getShortJobId(id);
            activeJobs.set(id, { type: 'movie', title, startTime: Date.now() });
            sendNotification('Movie Download Started 🎬', `"${title}" (${shortId})`, 'normal');
        }
        return;
    }
    if (message.includes('[SSE] Emitting "movieDownloadFinished"')) {
        let latest = null, ts = 0;
        for (const [id, info] of activeJobs) {
            if (info.type === 'movie' && info.startTime > ts) {
                latest = { id, ...info };
                ts = info.startTime;
            }
        }
        const msg = latest
            ? `"${latest.title}" (${getShortJobId(latest.id)})`
            : 'Movie download has finished';
        if (latest) activeJobs.delete(latest.id);
        sendNotification('Movie Download Complete ✅', msg, 'normal');
        return;
    }

    // --- Series downloads ---
    if (message.includes('[/SaveTVSeries] starting TV series')) {
        const m = message.match(/starting TV series "([^"]+)" episode "([^"]+)" download \(job-id: ([a-f0-9-]+)\)/);
        if (m) {
            const series = cleanTitle(m[1]);
            const episode = cleanTitle(m[2]);
            const fullTitle = `${series} - ${episode}`;
            const id = m[3];
            const shortId = getShortJobId(id);
            activeJobs.set(id, { type: 'series', title: fullTitle, startTime: Date.now() });
            sendNotification('Series Download Started 📺', `"${fullTitle}" (${shortId})`, 'normal');
        }
        return;
    }
    if (message.includes('[/SaveTVSeries] TV series') && message.includes('download finished')) {
        const m = message.match(/TV series "([^"]+)" episode "([^"]+)" download finished \(job-id: ([a-f0-9-]+)\)/);
        let msg = 'Series download has finished';
        if (m) {
            const title = cleanTitle(`${m[1]} - ${m[2]}`);
            const id = m[3];
            const shortId = getShortJobId(id);
            activeJobs.delete(id);
            msg = `"${title}" (${shortId})`;
        }
        sendNotification('Series Download Complete ✅', msg, 'normal');
        return;
    }

    // --- Catch-up downloads ---
    if (message.includes('[/SaveCatchup] starting catchup download')) {
        const id = extractJobId(message);
        if (id) {
            activeJobs.set(id, { type: 'catchup', title: 'Catchup recording', startTime: Date.now(), waitingForFilename: true });
        }
        return;
    }
    if (message.includes('[/SaveCatchup] recorded process for job-id:') && message.includes('filename:')) {
        const rpMatch = message.match(/recorded process for job-id: ([a-f0-9-]+), filename: (.+)$/);
        if (rpMatch) {
            const id = rpMatch[1];
            const filepath = rpMatch[2];
            const fn = filepath.split('/').pop();
            const prog = extractProgramNameFromFilename(fn);
            if (id && prog && activeJobs.has(id)) {
                const title = cleanTitle(prog);
                const shortId = getShortJobId(id);
                const job = activeJobs.get(id);
                job.title = title;
                job.waitingForFilename = false;
                sendNotification('Catch-Up Download Started ⏪', `"${title}" (${shortId})`, 'normal');
            }
        }
        return;
    }
    if (message.includes('[saveWithFfmpeg] Download started:') && message.includes('/Recordings/')) {
        const fnMatch = message.match(/\/Recordings\/(.+?\.(ts|mp4))/);
        if (fnMatch) {
            const fn = fnMatch[1];
            const idMatch = fn.match(/([a-f0-9-]{36})/);
            if (idMatch) {
                const id = idMatch[1];
                if (activeJobs.has(id)) {
                    const prog = extractProgramNameFromFilename(fn);
                    const job = activeJobs.get(id);
                    job.title = cleanTitle(prog || job.title);
                    job.waitingForFilename = false;
                }
            }
        }
        return;
    }
    if (message.includes('[/SaveCatchup] catchup download finished')) {
        const id = extractJobId(message);
        let msg = 'Catch-Up download has finished';
        if (id && activeJobs.has(id)) {
            const job = activeJobs.get(id);
            msg = `"${job.title}" (${getShortJobId(id)})`;
            activeJobs.delete(id);
        }
        sendNotification('Catch-Up Download Complete ✅', msg, 'normal');
        return;
    }

    // --- Recording cancellations and completions ---
    if (message.includes('DELETE /recordings/active/') && message.includes('200')) {
        const id = message.match(/\/recordings\/active\/([a-f0-9-]+)/)?.[1];
        if (id && activeJobs.has(id) && activeJobs.get(id).type === 'recording') {
            const info = activeJobs.get(id);
            const shortId = getShortJobId(id);
            const cancelMsg = info.channel
                ? `"${info.title}" on ${info.channel} cancelled (${shortId})` 
                : `"${info.title}" cancelled (${shortId})`;
            sendNotification('Recording Cancelled ⏹️', cancelMsg, 'low');
            activeJobs.delete(id);
            suppressedCompletions.add(id);
            setTimeout(() => suppressedCompletions.delete(id), 30000);
        }
        return;
    }
    if (message.includes('[SSE] Emitting "recordingFinished"')) {
        let recentRec = null;
        let latestTime = 0;
        for (const [id, job] of activeJobs) {
            if ((job.type === 'recording' || job.type === 'scheduled') && job.startTime > latestTime) {
                recentRec = { id, ...job };
                latestTime = job.startTime;
            }
        }
        if (recentRec && !suppressedCompletions.has(recentRec.id)) {
            const shortId = getShortJobId(recentRec.id);
            const msg = recentRec.channel
                ? `"${recentRec.title}" on ${recentRec.channel} (${shortId})` 
                : `"${recentRec.title}" (${shortId})`;
            sendNotification('Recording Complete ✅', msg, 'normal');
            activeJobs.delete(recentRec.id);
        }
        return;
    }
}

// Launch and log capture
const proc = spawn('snappier-server', [], { stdio: ['pipe', 'pipe', 'pipe'], cwd: '/root/SnappierServer' });
proc.stdout.on('data', data => {
    data.toString().split('\n').forEach(line => {
        if (line.trim()) {
            console.log(line);
            processLogLine(line);
        }
    });
});
proc.stderr.on('data', data => {
    data.toString().split('\n').forEach(line => {
        if (line.trim()) {
            console.error(line);
            if (line.toLowerCase().includes('error') && line.includes('job-id')) {
                const id = extractJobId(line);
                sendNotification('System Error ❌', `Error detected (${getShortJobId(id)})`, 'high');
            }
        }
    });
});
proc.on('close', code => {
    console.log(`🎬 [webhook] Snappier server exited with code ${code}`);
    if (code !== 0) sendNotification('Server Error ❌', `Snappier server exited unexpectedly (code: ${code})`, 'high');
});
proc.on('error', error => {
    console.error('❌ [webhook] Failed to start Snappier server:', error);
    sendNotification('Server Error ❌', 'Failed to start Snappier server', 'high');
});
process.on('SIGTERM', () => { proc.kill('SIGTERM'); process.exit(0); });
process.on('SIGINT', () => { proc.kill('SIGINT'); process.exit(0); });
// Cleanup old jobs periodically
setInterval(() => {
    const now = Date.now();
    const maxAge = 24 * 60 * 60 * 1000;
    for (const [id, job] of activeJobs) {
        if (now - job.startTime > maxAge) {
            console.log(`🧹 [webhook] Cleaning up old job: ${id}`);
            activeJobs.delete(id);
        }
    }
}, 60 * 60 * 1000);
console.log('🔗 [webhook] Log monitor initialized and ready');
