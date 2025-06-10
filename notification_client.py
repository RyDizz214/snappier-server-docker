#!/usr/bin/env python3
"""
Notification Client for Snappier Server
Sends notifications to the integrated Electron notification service
"""

import os
import json
import requests
import websocket
import threading
import time
from typing import Dict, Any, Optional
import logging

logger = logging.getLogger(__name__)

class NotificationClient:
    def __init__(self, http_url: str = None, ws_url: str = None, use_websocket: bool = True):
        self.http_url = http_url or os.getenv('NOTIFICATION_SERVICE_URL', 'http://localhost:9080')
        self.ws_url = ws_url or os.getenv('NOTIFICATION_WS_URL', 'ws://localhost:9081')
        self.ws = None
        self.use_websocket = use_websocket
        self.reconnect_attempts = 0
        self.max_reconnect_attempts = 5
        self.reconnect_delay = 1
        self.ws_connected = False
        
        if use_websocket:
            self._connect_websocket()
    
    def notify(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        """Send notification via HTTP API"""
        if options is None:
            options = {}
            
        payload = {
            'title': title,
            'body': body,
            'options': options
        }
        
        try:
            response = requests.post(
                f'{self.http_url}/notify',
                json=payload,
                timeout=5
            )
            return response.json()
        except requests.RequestException as e:
            logger.error(f'Failed to send notification via HTTP: {e}')
            return {'success': False, 'error': str(e)}
    
    def notify_ws(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        """Send notification via WebSocket (faster)"""
        if not self.ws_connected:
            logger.warning('WebSocket not connected, falling back to HTTP')
            return self.notify(title, body, options)
        
        if options is None:
            options = {}
            
        payload = {
            'type': 'notification',
            'title': title,
            'body': body,
            'options': options
        }
        
        try:
            self.ws.send(json.dumps(payload))
            return {'success': True}
        except Exception as e:
            logger.error(f'Failed to send notification via WebSocket: {e}')
            return self.notify(title, body, options)  # Fallback to HTTP
    
    def _connect_websocket(self):
        """Connect to WebSocket in a separate thread"""
        def connect():
            try:
                self.ws = websocket.WebSocketApp(
                    self.ws_url,
                    on_open=self._on_ws_open,
                    on_message=self._on_ws_message,
                    on_error=self._on_ws_error,
                    on_close=self._on_ws_close
                )
                self.ws.run_forever()
            except Exception as e:
                logger.error(f'WebSocket connection error: {e}')
                self._reconnect_websocket()
        
        ws_thread = threading.Thread(target=connect, daemon=True)
        ws_thread.start()
    
    def _on_ws_open(self, ws):
        logger.info('Connected to notification service via WebSocket')
        self.ws_connected = True
        self.reconnect_attempts = 0
    
    def _on_ws_message(self, ws, message):
        try:
            data = json.loads(message)
            if data.get('type') == 'response':
                # Handle response if needed
                pass
        except json.JSONDecodeError as e:
            logger.error(f'Failed to parse WebSocket message: {e}')
    
    def _on_ws_error(self, ws, error):
        logger.error(f'Notification WebSocket error: {error}')
        self.ws_connected = False
    
    def _on_ws_close(self, ws, close_status_code, close_msg):
        logger.info('Disconnected from notification service')
        self.ws_connected = False
        self._reconnect_websocket()
    
    def _reconnect_websocket(self):
        """Reconnect WebSocket with exponential backoff"""
        if self.reconnect_attempts >= self.max_reconnect_attempts:
            logger.info('Max reconnection attempts reached for notification service')
            return
        
        self.reconnect_attempts += 1
        delay = self.reconnect_delay * (2 ** (self.reconnect_attempts - 1))
        
        logger.info(f'Attempting to reconnect to notification service in {delay}s (attempt {self.reconnect_attempts})')
        
        def delayed_reconnect():
            time.sleep(delay)
            self._connect_websocket()
        
        reconnect_thread = threading.Thread(target=delayed_reconnect, daemon=True)
        reconnect_thread.start()
    
    # Convenience methods for different notification types
    def success(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        if options is None:
            options = {}
        options.update({'urgency': 'low', 'icon': options.get('icon', 'success')})
        return self.notify(title, body, options)
    
    def warning(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        if options is None:
            options = {}
        options.update({'urgency': 'normal', 'icon': options.get('icon', 'warning')})
        return self.notify(title, body, options)
    
    def error(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        if options is None:
            options = {}
        options.update({'urgency': 'critical', 'icon': options.get('icon', 'error')})
        return self.notify(title, body, options)
    
    def info(self, title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
        if options is None:
            options = {}
        options.update({'urgency': 'low', 'icon': options.get('icon', 'info')})
        return self.notify(title, body, options)
    
    def health_check(self) -> Dict[str, Any]:
        """Check if notification service is available"""
        try:
            response = requests.get(f'{self.http_url}/health', timeout=5)
            return response.json()
        except requests.RequestException as e:
            return {'status': 'error', 'error': str(e)}
    
    def disconnect(self):
        """Close WebSocket connection"""
        if self.ws:
            self.ws.close()
            self.ws = None
        self.ws_connected = False

# Global instance for easy access
_notification_client = None

def get_notification_client() -> NotificationClient:
    """Get global notification client instance"""
    global _notification_client
    if _notification_client is None:
        _notification_client = NotificationClient()
    return _notification_client

# Convenience functions
def notify(title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
    return get_notification_client().notify(title, body, options)

def success(title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
    return get_notification_client().success(title, body, options)

def warning(title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
    return get_notification_client().warning(title, body, options)

def error(title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
    return get_notification_client().error(title, body, options)

def info(title: str, body: str, options: Dict[str, Any] = None) -> Dict[str, Any]:
    return get_notification_client().info(title, body, options)

# Usage example:
if __name__ == '__main__':
    # Create client instance
    client = NotificationClient()
    
    # Send notifications
    client.success('Success!', 'Operation completed successfully')
    client.error('Error!', 'Something went wrong')
    client.info('Info', 'Just letting you know...')
    
    # Or use convenience functions
    notify('Custom Title', 'Custom message', {'urgency': 'critical', 'sound': True})
    
    # Health check
    health = client.health_check()
    print(f'Notification service status: {health}')
