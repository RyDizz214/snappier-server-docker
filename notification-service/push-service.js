const express = require('express');
const WebSocket = require('ws');
const axios = require('axios');

let server;
let wss;

// Express server for HTTP API
const expressApp = express();
expressApp.use(express.json());

// Pushover configuration
const pushoverConfig = {
    token: process.env.PUSHOVER_TOKEN || '',
    user: process.env.PUSHOVER_USER || '',
    enabled: !!(process.env.PUSHOVER_TOKEN && process.env.PUSHOVER_USER)
};

console.log('📱 Pushover Push Notification Service');
console.log(`   Status: ${pushoverConfig.enabled ? '✅ Enabled and Ready' : '❌ Not Configured'}`);

if (!pushoverConfig.enabled) {
    console.log('⚠️  To enable Pushover notifications, set these environment variables:');
    console.log('   PUSHOVER_TOKEN=your_application_token');
    console.log('   PUSHOVER_USER=your_user_key');
}

// Send notification via Pushover
async function sendPushoverNotification(title, body, options = {}) {
    if (!pushoverConfig.enabled) {
        return { 
            success: false, 
            error: 'Pushover not configured. Set PUSHOVER_TOKEN and PUSHOVER_USER environment variables.' 
        };
    }
    
    try {
        // Map urgency levels to Pushover priorities
        let priority = 0; // Normal priority
        if (options.urgency === 'critical') {
            priority = 2; // Emergency - requires acknowledgment
        } else if (options.urgency === 'high') {
            priority = 1; // High priority
        } else if (options.urgency === 'low') {
            priority = -1; // Low priority, no sound
        }

        const payload = {
            token: pushoverConfig.token,
            user: pushoverConfig.user,
            title: title,
            message: body,
            priority: priority,
            sound: options.sound || 'pushover', // Default sound
            url: options.url || '',
            url_title: options.url_title || '',
            device: options.device || '', // Leave empty to send to all devices
            timestamp: Math.floor(Date.now() / 1000)
        };

        // Add retry and expire for emergency notifications
        if (priority === 2) {
            payload.retry = options.retry || 60; // Retry every 60 seconds
            payload.expire = options.expire || 3600; // Stop retrying after 1 hour
        }

        console.log(`📤 Sending Pushover notification: "${title}" (priority: ${priority})`);
        
        const response = await axios.post('https://api.pushover.net/1/messages.json', payload);
        
        if (response.data.status === 1) {
            console.log(`✅ Pushover notification sent successfully`);
            return { 
                success: true, 
                service: 'pushover', 
                message: 'Notification sent successfully',
                pushover_request: response.data.request
            };
        } else {
            console.error('❌ Pushover API error:', response.data);
            return { 
                success: false, 
                service: 'pushover', 
                error: 'Pushover API returned error',
                details: response.data
            };
        }
    } catch (error) {
        console.error('❌ Pushover request failed:', error.message);
        return { 
            success: false, 
            service: 'pushover', 
            error: error.message,
            details: error.response?.data || null
        };
    }
}

// HTTP API endpoints
expressApp.post('/notify', async (req, res) => {
    const { title, body, options } = req.body;
    
    if (!title || !body) {
        return res.status(400).json({ 
            error: 'Title and body are required',
            example: {
                title: 'Your notification title',
                body: 'Your notification message',
                options: {
                    urgency: 'normal', // low, normal, high, critical
                    sound: 'pushover', // pushover, bike, bugle, cashregister, classical, cosmic, falling, gamelan, incoming, intermission, magic, mechanical, pianobar, siren, spacealarm, tugboat, alien, climb, persistent, echo, updown, vibrate, none
                    url: 'https://example.com',
                    url_title: 'Open Link'
                }
            }
        });
    }

    const result = await sendPushoverNotification(title, body, options || {});
    
    if (result.success) {
        res.json(result);
    } else {
        res.status(500).json(result);
    }
});

// Test endpoint
expressApp.post('/test', async (req, res) => {
    const result = await sendPushoverNotification(
        '🧪 Snappier Test Notification',
        'This is a test notification from your Snappier server!',
        { urgency: 'normal', sound: 'pushover' }
    );
    res.json(result);
});

// Health check
expressApp.get('/health', (req, res) => {
    res.json({ 
        status: 'ok',
        pushover_configured: pushoverConfig.enabled,
        service: 'pushover',
        version: '1.0.0'
    });
});

// Configuration status
expressApp.get('/config', (req, res) => {
    res.json({
        pushover: {
            enabled: pushoverConfig.enabled,
            configured: pushoverConfig.enabled,
            token_set: !!pushoverConfig.token,
            user_set: !!pushoverConfig.user
        }
    });
});

// Validate Pushover credentials
expressApp.get('/validate', async (req, res) => {
    if (!pushoverConfig.enabled) {
        return res.status(400).json({
            valid: false,
            error: 'Pushover not configured'
        });
    }

    try {
        const response = await axios.post('https://api.pushover.net/1/users/validate.json', {
            token: pushoverConfig.token,
            user: pushoverConfig.user
        });

        res.json({
            valid: response.data.status === 1,
            details: response.data
        });
    } catch (error) {
        res.status(500).json({
            valid: false,
            error: error.message,
            details: error.response?.data || null
        });
    }
});

// WebSocket for real-time notifications
function setupWebSocket() {
    const wsPort = process.env.NOTIFICATION_WS_PORT || 9081;
    wss = new WebSocket.Server({ port: wsPort });
    
    wss.on('connection', (ws) => {
        console.log('📡 WebSocket client connected');
        
        ws.on('message', async (message) => {
            try {
                const data = JSON.parse(message);
                if (data.type === 'notification') {
                    const result = await sendPushoverNotification(data.title, data.body, data.options);
                    ws.send(JSON.stringify({ type: 'response', ...result }));
                } else if (data.type === 'test') {
                    const result = await sendPushoverNotification(
                        '🧪 WebSocket Test',
                        'WebSocket notification test successful!',
                        { urgency: 'low' }
                    );
                    ws.send(JSON.stringify({ type: 'test_response', ...result }));
                }
            } catch (error) {
                console.error('WebSocket message error:', error);
                ws.send(JSON.stringify({ type: 'error', message: error.message }));
            }
        });

        ws.on('close', () => {
            console.log('📡 WebSocket client disconnected');
        });
    });
}

// Start servers
const httpPort = process.env.NOTIFICATION_HTTP_PORT || 9080;
server = expressApp.listen(httpPort, '0.0.0.0', () => {
    console.log(`🚀 Pushover notification server running on port ${httpPort}`);
    console.log(`📱 Send test notification: curl -X POST http://localhost:${httpPort}/test`);
});

setupWebSocket();
const wsPort = process.env.NOTIFICATION_WS_PORT || 9081;
console.log(`📡 WebSocket server running on port ${wsPort}`);

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('🛑 Shutting down notification service...');
    if (server) server.close();
    if (wss) wss.close();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('🛑 Shutting down notification service...');
    if (server) server.close();
    if (wss) wss.close();
    process.exit(0);
});
