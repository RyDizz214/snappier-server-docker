// Enhanced node-notifier that sends to our Pushover service with comprehensive logging
const http = require('http');

// Track all calls for debugging
let callCount = 0;

// Function to send notification to our Pushover service
function sendToPushover(options) {
    console.log(`📱 [node-notifier] Sending notification #${++callCount}`);
    console.log(`📱 [node-notifier] Raw options:`, JSON.stringify(options, null, 2));

    const notificationData = {
        title: options.title || options.subtitle || 'Snappier Server',
        body: options.message || options.body || options.text || 'Notification',
        options: {
            urgency: 'normal',
            sound: 'pushover'
        }
    };

    // Map different notification types to different urgency levels and sounds
    const titleLower = (notificationData.title || '').toLowerCase();
    const bodyLower = (notificationData.body || '').toLowerCase();
    const combinedText = (titleLower + ' ' + bodyLower).toLowerCase();

    if (combinedText.includes('error') || combinedText.includes('fail')) {
        notificationData.options.urgency = 'high';
        notificationData.options.sound = 'siren';
    } else if (combinedText.includes('complete') || combinedText.includes('finished') || combinedText.includes('done')) {
        notificationData.options.urgency = 'normal';
        notificationData.options.sound = 'magic';
    } else if (combinedText.includes('start') || combinedText.includes('begin') || combinedText.includes('download')) {
        notificationData.options.urgency = 'normal';
        notificationData.options.sound = 'pushover';
    } else if (combinedText.includes('schedul')) {
        notificationData.options.urgency = 'low';
        notificationData.options.sound = 'bike';
    }

    console.log(`📱 [node-notifier] Processed notification:`, JSON.stringify(notificationData, null, 2));

    const postData = JSON.stringify(notificationData);
    
    const requestOptions = {
        hostname: 'localhost',
        port: 9080,
        path: '/notify',
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData)
        }
    };

    const req = http.request(requestOptions, (res) => {
        let data = '';
        res.on('data', (chunk) => {
            data += chunk;
        });
        res.on('end', () => {
            if (res.statusCode === 200) {
                console.log(`✅ [node-notifier] Notification sent successfully: "${notificationData.title}"`);
            } else {
                console.error(`❌ [node-notifier] Notification failed: ${res.statusCode} - ${data}`);
            }
        });
    });

    req.on('error', (error) => {
        console.error('❌ [node-notifier] Notification request error:', error.message);
    });

    req.write(postData);
    req.end();
}

// Main notify function that mimics node-notifier API
function notify(options, callback) {
    console.log('🔔 [node-notifier] notify() called with:', JSON.stringify(options, null, 2));
    
    // Handle different input formats
    if (typeof options === 'string') {
        options = { message: options };
    }
    
    // Send to our Pushover service
    sendToPushover(options);
    
    // Call callback if provided (for compatibility)
    if (typeof callback === 'function') {
        // Simulate async callback
        setTimeout(() => {
            console.log('🔔 [node-notifier] Calling callback with success');
            callback(null, 'sent');
        }, 100);
    }
    
    return true; // Some libraries expect a return value
}

// Create a comprehensive notification object that covers all possible APIs
const NotificationCenter = {
    notify: notify
};

const WindowsToaster = {
    notify: notify
};

const WindowsBalloon = {
    notify: notify
};

const NotifySend = {
    notify: notify
};

const Growl = {
    notify: notify
};

// Log when module is loaded
console.log('🔔 [node-notifier] Enhanced module loaded successfully');

// Export the notify function and other compatibility methods
const nodeNotifier = {
    notify: notify,
    NotificationCenter: NotificationCenter,
    WindowsToaster: WindowsToaster,
    WindowsBalloon: WindowsBalloon,
    NotifySend: NotifySend,
    Growl: Growl
};

// Also add direct properties for maximum compatibility
nodeNotifier.default = nodeNotifier;

// Export in multiple ways for maximum compatibility
module.exports = nodeNotifier;
module.exports.default = nodeNotifier;
module.exports.notify = notify;

// Global logging to catch any missed calls
const originalConsoleLog = console.log;
console.log = function(...args) {
    // Look for notification-related logs from Snappier
    const message = args.join(' ');
    if (message.includes('notification') || message.includes('notify')) {
        originalConsoleLog('🔍 [DEBUG] Potential notification log:', ...args);
    }
    return originalConsoleLog.apply(console, args);
};
