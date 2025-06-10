// notification-client.js - Include this in your snappier-server project

class NotificationClient {
    constructor(options = {}) {
        this.httpUrl = options.httpUrl || process.env.NOTIFICATION_SERVICE_URL || 'http://localhost:9080';
        this.wsUrl = options.wsUrl || process.env.NOTIFICATION_WS_URL || 'ws://localhost:9081';
        this.ws = null;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 5;
        this.reconnectDelay = 1000;
        
        // Auto-connect WebSocket if enabled
        if (options.useWebSocket !== false) {
            this.connectWebSocket();
        }
    }

    // Send notification via HTTP (more reliable)
    async notify(title, body, options = {}) {
        try {
            const response = await fetch(`${this.httpUrl}/notify`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    title,
                    body,
                    options
                })
            });

            const result = await response.json();
            return result;
        } catch (error) {
            console.error('Failed to send notification via HTTP:', error);
            return { success: false, error: error.message };
        }
    }

    // Send notification via WebSocket (faster, real-time)
    notifyWS(title, body, options = {}) {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
            console.warn('WebSocket not connected, falling back to HTTP');
            return this.notify(title, body, options);
        }

        try {
            this.ws.send(JSON.stringify({
                type: 'notification',
                title,
                body,
                options
            }));
            return Promise.resolve({ success: true });
        } catch (error) {
            console.error('Failed to send notification via WebSocket:', error);
            return this.notify(title, body, options); // Fallback to HTTP
        }
    }

    // Connect to WebSocket
    connectWebSocket() {
        try {
            this.ws = new WebSocket(this.wsUrl);
            
            this.ws.onopen = () => {
                console.log('Connected to notification service via WebSocket');
                this.reconnectAttempts = 0;
            };

            this.ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    if (data.type === 'response') {
                        // Handle response if needed
                    }
                } catch (error) {
                    console.error('Failed to parse WebSocket message:', error);
                }
            };

            this.ws.onclose = () => {
                console.log('Disconnected from notification service');
                this.reconnectWebSocket();
            };

            this.ws.onerror = (error) => {
                console.error('Notification WebSocket error:', error);
            };

        } catch (error) {
            console.error('Failed to connect to notification WebSocket:', error);
            setTimeout(() => this.reconnectWebSocket(), this.reconnectDelay);
        }
    }

    // Reconnect WebSocket with exponential backoff
    reconnectWebSocket() {
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            console.log('Max reconnection attempts reached for notification service');
            return;
        }

        this.reconnectAttempts++;
        const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1);
        
        console.log(`Attempting to reconnect to notification service in ${delay}ms (attempt ${this.reconnectAttempts})`);
        
        setTimeout(() => {
            this.connectWebSocket();
        }, delay);
    }

    // Convenience methods for different notification types
    success(title, body, options = {}) {
        return this.notify(title, body, {
            ...options,
            urgency: 'low',
            icon: options.icon || 'success'
        });
    }

    warning(title, body, options = {}) {
        return this.notify(title, body, {
            ...options,
            urgency: 'normal',
            icon: options.icon || 'warning'
        });
    }

    error(title, body, options = {}) {
        return this.notify(title, body, {
            ...options,
            urgency: 'critical',
            icon: options.icon || 'error'
        });
    }

    info(title, body, options = {}) {
        return this.notify(title, body, {
            ...options,
            urgency: 'low',
            icon: options.icon || 'info'
        });
    }

    // Check if notification service is available
    async healthCheck() {
        try {
            const response = await fetch(`${this.httpUrl}/health`);
            return await response.json();
        } catch (error) {
            return { status: 'error', error: error.message };
        }
    }

    // Close WebSocket connection
    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }
}

// For Node.js environments, you might need to install 'node-fetch' and 'ws'
// npm install node-fetch ws

// If running in Node.js, uncomment these lines:
// const fetch = require('node-fetch');
// const WebSocket = require('ws');

module.exports = NotificationClient;

// Usage example:
/*
const NotificationClient = require('./notification-client');

// Create client instance
const notifications = new NotificationClient();

// Send notifications
notifications.success('Success!', 'Operation completed successfully');
notifications.error('Error!', 'Something went wrong');
notifications.info('Info', 'Just letting you know...');

// Or use the generic method
notifications.notify('Custom Title', 'Custom message', {
    urgency: 'critical',
    sound: true
});
*/
