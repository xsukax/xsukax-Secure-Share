#!/bin/bash

set -e

APP_DIR="/opt/secureshare"
SERVICE_NAME="secureshare"
SERVICE_USER="secureshare"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (use sudo)"
   exit 1
fi

# Create application directory
mkdir -p "$APP_DIR"/{public/css,public/js,uploads,logs}

# Create service user
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /bin/false -d "$APP_DIR" "$SERVICE_USER"
fi

# Create package.json
cat > "$APP_DIR/package.json" << 'EOF'
{
  "name": "secureshare",
  "version": "2.0.0",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "multer": "^1.4.5-lts.1",
    "sqlite3": "^5.1.6",
    "uuid": "^9.0.0",
    "ws": "^8.13.0"
  }
}
EOF

cd "$APP_DIR"
npm install --production
cd - > /dev/null

# Create server.js
cat > "$APP_DIR/server.js" << 'EOF'
const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const sqlite3 = require('sqlite3').verbose();
const { v4: uuidv4 } = require('uuid');
const WebSocket = require('ws');
const http = require('http');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.PORT || 3456;
const MAX_FILE_SIZE = 1024 * 1024 * 1024;

app.use(express.json());
app.use(express.static('public'));

const db = new sqlite3.Database('./database.sqlite');

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )`);
    
    db.run(`CREATE TABLE IF NOT EXISTS file_transfers (
        id TEXT PRIMARY KEY,
        sender_id TEXT,
        recipient_id TEXT,
        filename TEXT,
        file_size INTEGER,
        file_path TEXT,
        encryption_key TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        download_time DATETIME,
        delete_after DATETIME,
        deleted BOOLEAN DEFAULT FALSE
    )`);
});

const activeConnections = new Map();

const storage = multer.diskStorage({
    destination: 'uploads/',
    filename: (req, file, cb) => {
        cb(null, uuidv4() + '.encrypted');
    }
});

const upload = multer({
    storage: storage,
    limits: { fileSize: MAX_FILE_SIZE }
});

wss.on('connection', (ws, req) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const userId = url.searchParams.get('userId');
    
    if (userId) {
        activeConnections.set(userId, ws);
        console.log(`[${new Date().toISOString()}] User ${userId} connected`);
        
        ws.send(JSON.stringify({
            type: 'connected',
            userId: userId
        }));
        
        ws.on('close', () => {
            activeConnections.delete(userId);
        });
    }
});

function generateUserId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let result = '';
    for (let i = 0; i < 6; i++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

app.post('/api/user/create', (req, res) => {
    const userId = generateUserId();
    
    db.run('INSERT INTO users (id) VALUES (?)', [userId], (err) => {
        if (err) {
            return res.status(500).json({ error: 'Failed to create user' });
        }
        res.json({ userId });
    });
});

app.get('/api/user/verify/:userId', (req, res) => {
    const { userId } = req.params;
    
    db.get('SELECT id FROM users WHERE id = ?', [userId], (err, row) => {
        res.json({ exists: !!row });
    });
});

app.post('/api/file/upload', upload.single('encryptedFile'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No file provided' });
    }
    
    const { senderId, recipientId, encryptionKey, originalName } = req.body;
    
    db.get('SELECT id FROM users WHERE id = ?', [recipientId], (err, user) => {
        if (!user) {
            fs.unlink(req.file.path, () => {});
            return res.status(400).json({ error: 'Recipient not found' });
        }
        
        const transferId = uuidv4();
        const deleteAfter = new Date(Date.now() + 60 * 60 * 1000);
        
        db.run(`INSERT INTO file_transfers 
                (id, sender_id, recipient_id, filename, file_size, file_path, encryption_key, delete_after) 
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, 
                [transferId, senderId, recipientId, originalName, req.file.size, req.file.path, encryptionKey, deleteAfter], 
                (err) => {
                    if (err) {
                        return res.status(500).json({ error: 'Failed to record transfer' });
                    }
                    
                    const recipientWs = activeConnections.get(recipientId);
                    if (recipientWs && recipientWs.readyState === WebSocket.OPEN) {
                        recipientWs.send(JSON.stringify({
                            type: 'file_received',
                            transferId,
                            senderId,
                            filename: originalName,
                            fileSize: req.file.size
                        }));
                    }
                    
                    res.json({ success: true, transferId });
                });
    });
});

app.get('/api/transfer/:transferId', (req, res) => {
    const { transferId } = req.params;
    const { userId } = req.query;
    
    db.get(`SELECT * FROM file_transfers WHERE id = ? AND recipient_id = ?`, 
           [transferId, userId], (err, transfer) => {
        if (!transfer) {
            return res.status(404).json({ error: 'Transfer not found' });
        }
        
        res.json({
            transferId: transfer.id,
            filename: transfer.filename,
            fileSize: transfer.file_size,
            encryptionKey: transfer.encryption_key,
            senderId: transfer.sender_id
        });
    });
});

app.get('/api/file/download/:transferId', (req, res) => {
    const { transferId } = req.params;
    const { userId } = req.query;
    
    db.get(`SELECT * FROM file_transfers WHERE id = ? AND recipient_id = ?`, 
           [transferId, userId], (err, transfer) => {
        if (!transfer) {
            return res.status(404).json({ error: 'Transfer not found' });
        }
        
        const filePath = path.join(__dirname, transfer.file_path);
        
        if (!fs.existsSync(filePath)) {
            return res.status(404).json({ error: 'File not found' });
        }
        
        db.run('UPDATE file_transfers SET download_time = datetime("now") WHERE id = ?', [transferId]);
        
        res.download(filePath, transfer.filename + '.encrypted');
    });
});

app.get('/api/transfers/:userId', (req, res) => {
    const { userId } = req.params;
    
    db.all(`SELECT id, sender_id, filename, file_size, created_at
            FROM file_transfers 
            WHERE recipient_id = ? AND deleted = FALSE
            ORDER BY created_at DESC`, [userId], (err, transfers) => {
        res.json({ transfers: transfers || [] });
    });
});

app.get('/health', (req, res) => {
    res.json({ status: 'ok', websockets: activeConnections.size });
});

setInterval(() => {
    db.all(`SELECT * FROM file_transfers 
            WHERE delete_after < datetime('now') AND deleted = FALSE`, (err, transfers) => {
        if (transfers) {
            transfers.forEach(transfer => {
                const filePath = path.join(__dirname, transfer.file_path);
                fs.unlink(filePath, () => {});
                db.run('UPDATE file_transfers SET deleted = TRUE WHERE id = ?', [transfer.id]);
            });
        }
    });
}, 5 * 60 * 1000);

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] SecureShare service started on port ${PORT}`);
});
EOF

# Create crypto.js
cat > "$APP_DIR/public/js/crypto.js" << 'EOF'
class CryptoUtils {
    constructor() {
        this.algorithm = 'AES-GCM';
        this.keyLength = 256;
        this.ivLength = 12;
    }

    async generateKey() {
        return await crypto.subtle.generateKey(
            { name: this.algorithm, length: this.keyLength },
            true,
            ['encrypt', 'decrypt']
        );
    }

    async exportKey(key) {
        const exported = await crypto.subtle.exportKey('raw', key);
        return btoa(String.fromCharCode(...new Uint8Array(exported)));
    }

    async importKey(keyString) {
        const keyData = Uint8Array.from(atob(keyString), c => c.charCodeAt(0));
        return await crypto.subtle.importKey(
            'raw',
            keyData,
            { name: this.algorithm, length: this.keyLength },
            true,
            ['encrypt', 'decrypt']
        );
    }

    async encryptFile(file, progressCallback) {
        const key = await this.generateKey();
        const iv = crypto.getRandomValues(new Uint8Array(this.ivLength));
        const fileData = await file.arrayBuffer();
        
        const encryptedData = await crypto.subtle.encrypt(
            { name: this.algorithm, iv: iv },
            key,
            fileData
        );
        
        const combined = new Uint8Array(iv.length + encryptedData.byteLength);
        combined.set(iv, 0);
        combined.set(new Uint8Array(encryptedData), iv.length);
        
        const encryptedBlob = new Blob([combined], { type: 'application/octet-stream' });
        const exportedKey = await this.exportKey(key);
        
        if (progressCallback) progressCallback(100);
        
        return { encryptedFile: encryptedBlob, key: exportedKey };
    }

    async decryptFile(encryptedData, keyString, progressCallback) {
        const key = await this.importKey(keyString);
        const dataArray = new Uint8Array(encryptedData);
        const iv = dataArray.slice(0, this.ivLength);
        const encrypted = dataArray.slice(this.ivLength);
        
        const decryptedData = await crypto.subtle.decrypt(
            { name: this.algorithm, iv: iv },
            key,
            encrypted
        );
        
        if (progressCallback) progressCallback(100);
        return decryptedData;
    }
}

window.cryptoUtils = new CryptoUtils();
EOF

# Create modern luxury HTML
cat > "$APP_DIR/public/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>xsukax Secure Share</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <div class="app">
        <header class="header">
            <div class="logo">xsukax Secure Share</div>
            <div class="status-indicator" id="status">
                <span class="status-dot"></span>
                <span class="status-text">Connecting...</span>
            </div>
        </header>

        <main class="main">
            <div class="hero-section" id="hero">
                <h1 class="hero-title">xsukax Secure Share</h1>
                <p class="hero-subtitle">End-to-end encrypted. Simple. Private.</p>
                
                <div class="id-card" id="id-card" style="display: none;">
                    <div class="id-label">Your ID</div>
                    <div class="id-value" id="user-id" title="Click to copy">------</div>
                    <div class="id-copied" id="copy-feedback">Copied!</div>
                </div>
                
                <button class="btn-primary" id="get-started">Generate ID</button>
            </div>

            <div class="transfer-section" id="transfer-section" style="display: none;">
                <div class="card send-card">
                    <h2>Send File</h2>
                    <div class="input-group">
                        <input type="text" 
                               id="recipient-input" 
                               class="input-field" 
                               placeholder="Enter recipient ID"
                               maxlength="6"
                               autocomplete="off">
                        <div class="input-hint" id="recipient-hint"></div>
                    </div>
                    
                    <div class="drop-zone" id="drop-zone">
                        <div class="drop-zone-content">
                            <svg class="drop-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                                <path d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/>
                            </svg>
                            <p class="drop-text">Drop file here or click to browse</p>
                            <p class="drop-hint">Max 1GB • Encrypted before upload</p>
                        </div>
                        <input type="file" id="file-input" hidden>
                    </div>
                    
                    <div class="file-preview" id="file-preview" style="display: none;">
                        <div class="file-info">
                            <span class="file-name" id="file-name"></span>
                            <span class="file-size" id="file-size"></span>
                        </div>
                        <button class="btn-remove" id="remove-file">×</button>
                    </div>
                    
                    <div class="progress-bar" id="progress" style="display: none;">
                        <div class="progress-fill" id="progress-fill"></div>
                    </div>
                    
                    <button class="btn-send" id="send-btn" disabled>Send Encrypted</button>
                </div>

                <div class="card receive-card">
                    <h2>Received Files</h2>
                    <div class="files-list" id="files-list">
                        <div class="empty-state">
                            <svg class="empty-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                                <path d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z"/>
                            </svg>
                            <p>No files yet</p>
                        </div>
                    </div>
                </div>
            </div>
        </main>

        <div class="toast" id="toast">
            <div class="toast-content">
                <span class="toast-message" id="toast-message"></span>
            </div>
        </div>
    </div>

    <script src="/js/crypto.js"></script>
    <script src="/js/app.js"></script>
</body>
</html>
EOF

# Create modern luxury CSS
cat > "$APP_DIR/public/css/styles.css" << 'EOF'
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

:root {
    --primary: #000;
    --secondary: #666;
    --accent: #4F46E5;
    --success: #10B981;
    --danger: #EF4444;
    --bg: #FAFAFA;
    --card: #FFF;
    --border: #E5E7EB;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', sans-serif;
    background: var(--bg);
    color: var(--primary);
    line-height: 1.6;
    min-height: 100vh;
}

.app {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 20px;
}

.header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 30px 0;
    border-bottom: 1px solid var(--border);
}

.logo {
    font-size: 24px;
    font-weight: 600;
    letter-spacing: -0.5px;
}

.status-indicator {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 16px;
    background: var(--card);
    border-radius: 20px;
    border: 1px solid var(--border);
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--danger);
    transition: background 0.3s;
}

.status-dot.connected {
    background: var(--success);
    animation: pulse 2s infinite;
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
}

.status-text {
    font-size: 13px;
    color: var(--secondary);
}

.main {
    padding: 60px 0;
}

.hero-section {
    text-align: center;
    max-width: 500px;
    margin: 0 auto 60px;
}

.hero-title {
    font-size: 48px;
    font-weight: 700;
    letter-spacing: -1px;
    margin-bottom: 16px;
}

.hero-subtitle {
    font-size: 18px;
    color: var(--secondary);
    margin-bottom: 40px;
}

.id-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 24px;
    margin-bottom: 32px;
    position: relative;
}

.id-label {
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--secondary);
    margin-bottom: 8px;
}

.id-value {
    font-size: 32px;
    font-weight: 600;
    letter-spacing: 4px;
    font-variant-numeric: tabular-nums;
    cursor: pointer;
    transition: color 0.2s;
}

.id-value:hover {
    color: var(--accent);
}

.id-copied {
    position: absolute;
    top: 50%;
    right: 24px;
    transform: translateY(-50%);
    background: var(--success);
    color: white;
    padding: 4px 12px;
    border-radius: 6px;
    font-size: 12px;
    opacity: 0;
    transition: opacity 0.3s;
    pointer-events: none;
}

.id-copied.show {
    opacity: 1;
}

.btn-primary {
    background: var(--primary);
    color: white;
    border: none;
    padding: 16px 32px;
    border-radius: 8px;
    font-size: 16px;
    font-weight: 500;
    cursor: pointer;
    transition: transform 0.2s, box-shadow 0.2s;
}

.btn-primary:hover {
    transform: translateY(-2px);
    box-shadow: 0 10px 20px rgba(0,0,0,0.1);
}

.transfer-section {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 32px;
}

@media (max-width: 768px) {
    .transfer-section {
        grid-template-columns: 1fr;
    }
}

.card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 32px;
}

.card h2 {
    font-size: 20px;
    font-weight: 600;
    margin-bottom: 24px;
}

.input-group {
    margin-bottom: 24px;
}

.input-field {
    width: 100%;
    padding: 12px 16px;
    border: 1px solid var(--border);
    border-radius: 8px;
    font-size: 16px;
    font-family: 'SF Mono', 'Monaco', monospace;
    letter-spacing: 2px;
    text-transform: uppercase;
    transition: border-color 0.2s;
}

.input-field:focus {
    outline: none;
    border-color: var(--accent);
}

.input-hint {
    margin-top: 8px;
    font-size: 13px;
    color: var(--secondary);
}

.input-hint.success {
    color: var(--success);
}

.input-hint.error {
    color: var(--danger);
}

.drop-zone {
    border: 2px dashed var(--border);
    border-radius: 12px;
    padding: 48px;
    text-align: center;
    cursor: pointer;
    transition: all 0.3s;
    margin-bottom: 24px;
}

.drop-zone:hover {
    border-color: var(--accent);
    background: rgba(79, 70, 229, 0.02);
}

.drop-zone.dragover {
    border-color: var(--accent);
    background: rgba(79, 70, 229, 0.05);
}

.drop-icon {
    width: 48px;
    height: 48px;
    color: var(--secondary);
    margin-bottom: 16px;
}

.drop-text {
    font-size: 16px;
    margin-bottom: 8px;
}

.drop-hint {
    font-size: 13px;
    color: var(--secondary);
}

.file-preview {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: var(--bg);
    border-radius: 8px;
    margin-bottom: 24px;
}

.file-info {
    display: flex;
    flex-direction: column;
}

.file-name {
    font-weight: 500;
}

.file-size {
    font-size: 13px;
    color: var(--secondary);
}

.btn-remove {
    background: none;
    border: none;
    font-size: 24px;
    color: var(--secondary);
    cursor: pointer;
    padding: 0;
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.progress-bar {
    height: 4px;
    background: var(--border);
    border-radius: 2px;
    overflow: hidden;
    margin-bottom: 24px;
}

.progress-fill {
    height: 100%;
    background: var(--accent);
    width: 0%;
    transition: width 0.3s;
}

.btn-send {
    width: 100%;
    padding: 14px;
    background: var(--accent);
    color: white;
    border: none;
    border-radius: 8px;
    font-size: 16px;
    font-weight: 500;
    cursor: pointer;
    transition: opacity 0.2s;
}

.btn-send:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.btn-send:not(:disabled):hover {
    opacity: 0.9;
}

.files-list {
    max-height: 400px;
    overflow-y: auto;
}

.empty-state {
    text-align: center;
    padding: 48px;
    color: var(--secondary);
}

.empty-icon {
    width: 48px;
    height: 48px;
    margin-bottom: 16px;
    opacity: 0.3;
}

.file-item {
    padding: 16px;
    border: 1px solid var(--border);
    border-radius: 8px;
    margin-bottom: 12px;
    transition: all 0.2s;
}

.file-item:hover {
    border-color: var(--accent);
}

.file-header {
    display: flex;
    justify-content: space-between;
    align-items: start;
    margin-bottom: 8px;
}

.file-title {
    font-weight: 500;
}

.file-meta {
    display: flex;
    gap: 16px;
    font-size: 13px;
    color: var(--secondary);
}

.btn-download {
    padding: 8px 16px;
    background: var(--primary);
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 14px;
    cursor: pointer;
    transition: transform 0.2s;
}

.btn-download:hover {
    transform: scale(1.05);
}

.toast {
    position: fixed;
    bottom: 32px;
    left: 50%;
    transform: translateX(-50%) translateY(100px);
    background: var(--primary);
    color: white;
    padding: 16px 24px;
    border-radius: 8px;
    opacity: 0;
    transition: all 0.3s;
    pointer-events: none;
    z-index: 1000;
}

.toast.show {
    transform: translateX(-50%) translateY(0);
    opacity: 1;
}
EOF

# Create modern app.js
cat > "$APP_DIR/public/js/app.js" << 'EOF'
class SecureShare {
    constructor() {
        this.userId = localStorage.getItem('userId');
        this.recipientId = null;
        this.selectedFile = null;
        this.ws = null;
        
        this.initElements();
        this.initEventListeners();
        this.init();
    }
    
    initElements() {
        this.statusDot = document.querySelector('.status-dot');
        this.statusText = document.querySelector('.status-text');
        this.heroSection = document.getElementById('hero');
        this.transferSection = document.getElementById('transfer-section');
        this.idCard = document.getElementById('id-card');
        this.userIdEl = document.getElementById('user-id');
        this.copyFeedback = document.getElementById('copy-feedback');
        this.getStartedBtn = document.getElementById('get-started');
        this.recipientInput = document.getElementById('recipient-input');
        this.recipientHint = document.getElementById('recipient-hint');
        this.dropZone = document.getElementById('drop-zone');
        this.fileInput = document.getElementById('file-input');
        this.filePreview = document.getElementById('file-preview');
        this.fileName = document.getElementById('file-name');
        this.fileSize = document.getElementById('file-size');
        this.removeFileBtn = document.getElementById('remove-file');
        this.progressBar = document.getElementById('progress');
        this.progressFill = document.getElementById('progress-fill');
        this.sendBtn = document.getElementById('send-btn');
        this.filesList = document.getElementById('files-list');
    }
    
    initEventListeners() {
        this.getStartedBtn?.addEventListener('click', () => this.start());
        this.userIdEl?.addEventListener('click', () => this.copyId());
        this.recipientInput?.addEventListener('input', (e) => this.handleRecipientInput(e));
        this.dropZone?.addEventListener('click', () => this.fileInput.click());
        this.dropZone?.addEventListener('dragover', (e) => this.handleDragOver(e));
        this.dropZone?.addEventListener('dragleave', () => this.handleDragLeave());
        this.dropZone?.addEventListener('drop', (e) => this.handleDrop(e));
        this.fileInput?.addEventListener('change', (e) => this.handleFileSelect(e));
        this.removeFileBtn?.addEventListener('click', () => this.removeFile());
        this.sendBtn?.addEventListener('click', () => this.sendFile());
    }
    
    async init() {
        if (this.userId) {
            await this.setupUser();
        }
    }
    
    async start() {
        const response = await fetch('/api/user/create', { method: 'POST' });
        const data = await response.json();
        
        if (data.userId) {
            this.userId = data.userId;
            localStorage.setItem('userId', this.userId);
            await this.setupUser();
        }
    }
    
    async setupUser() {
        this.userIdEl.textContent = this.userId;
        this.idCard.style.display = 'block';
        this.getStartedBtn.style.display = 'none';
        this.transferSection.style.display = 'grid';
        
        this.connectWebSocket();
        this.loadFiles();
    }
    
    connectWebSocket() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        this.ws = new WebSocket(`${protocol}//${window.location.host}?userId=${this.userId}`);
        
        this.ws.onopen = () => {
            this.statusDot.classList.add('connected');
            this.statusText.textContent = 'Connected';
        };
        
        this.ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === 'file_received') {
                this.showToast(`New file from ${data.senderId}`);
                this.loadFiles();
            }
        };
        
        this.ws.onclose = () => {
            this.statusDot.classList.remove('connected');
            this.statusText.textContent = 'Disconnected';
            setTimeout(() => this.connectWebSocket(), 3000);
        };
    }
    
    copyId() {
        navigator.clipboard.writeText(this.userId);
        this.copyFeedback.classList.add('show');
        setTimeout(() => this.copyFeedback.classList.remove('show'), 2000);
    }
    
    async handleRecipientInput(e) {
        const value = e.target.value.toUpperCase();
        e.target.value = value;
        
        if (value.length === 6) {
            const response = await fetch(`/api/user/verify/${value}`);
            const data = await response.json();
            
            if (data.exists) {
                this.recipientId = value;
                this.recipientHint.textContent = 'Recipient verified';
                this.recipientHint.className = 'input-hint success';
                this.updateSendButton();
            } else {
                this.recipientId = null;
                this.recipientHint.textContent = 'User not found';
                this.recipientHint.className = 'input-hint error';
                this.updateSendButton();
            }
        } else {
            this.recipientHint.textContent = '';
            this.recipientId = null;
            this.updateSendButton();
        }
    }
    
    handleDragOver(e) {
        e.preventDefault();
        this.dropZone.classList.add('dragover');
    }
    
    handleDragLeave() {
        this.dropZone.classList.remove('dragover');
    }
    
    handleDrop(e) {
        e.preventDefault();
        this.dropZone.classList.remove('dragover');
        
        const files = e.dataTransfer.files;
        if (files.length > 0) {
            this.selectFile(files[0]);
        }
    }
    
    handleFileSelect(e) {
        if (e.target.files.length > 0) {
            this.selectFile(e.target.files[0]);
        }
    }
    
    selectFile(file) {
        if (file.size > 1024 * 1024 * 1024) {
            this.showToast('File exceeds 1GB limit');
            return;
        }
        
        this.selectedFile = file;
        this.fileName.textContent = file.name;
        this.fileSize.textContent = this.formatSize(file.size);
        this.filePreview.style.display = 'flex';
        this.dropZone.style.display = 'none';
        this.updateSendButton();
    }
    
    removeFile() {
        this.selectedFile = null;
        this.fileInput.value = '';
        this.filePreview.style.display = 'none';
        this.dropZone.style.display = 'block';
        this.updateSendButton();
    }
    
    updateSendButton() {
        this.sendBtn.disabled = !this.selectedFile || !this.recipientId;
    }
    
    async sendFile() {
        if (!this.selectedFile || !this.recipientId) return;
        
        this.sendBtn.disabled = true;
        this.progressBar.style.display = 'block';
        
        try {
            // Encrypt
            this.progressFill.style.width = '30%';
            const encrypted = await window.cryptoUtils.encryptFile(this.selectedFile);
            
            // Upload
            this.progressFill.style.width = '60%';
            const formData = new FormData();
            formData.append('encryptedFile', encrypted.encryptedFile);
            formData.append('senderId', this.userId);
            formData.append('recipientId', this.recipientId);
            formData.append('encryptionKey', encrypted.key);
            formData.append('originalName', this.selectedFile.name);
            
            const response = await fetch('/api/file/upload', {
                method: 'POST',
                body: formData
            });
            
            if (response.ok) {
                this.progressFill.style.width = '100%';
                this.showToast('File sent successfully');
                this.removeFile();
                setTimeout(() => {
                    this.progressBar.style.display = 'none';
                    this.progressFill.style.width = '0%';
                }, 500);
            }
        } catch (error) {
            this.showToast('Failed to send file');
        } finally {
            this.sendBtn.disabled = false;
        }
    }
    
    async loadFiles() {
        const response = await fetch(`/api/transfers/${this.userId}`);
        const data = await response.json();
        
        if (data.transfers && data.transfers.length > 0) {
            this.filesList.innerHTML = data.transfers.map(t => `
                <div class="file-item">
                    <div class="file-header">
                        <div>
                            <div class="file-title">${t.filename}</div>
                            <div class="file-meta">
                                <span>From: ${t.sender_id}</span>
                                <span>${this.formatSize(t.file_size)}</span>
                            </div>
                        </div>
                        <button class="btn-download" onclick="app.downloadFile('${t.id}')">
                            Download
                        </button>
                    </div>
                </div>
            `).join('');
        } else {
            this.filesList.innerHTML = `
                <div class="empty-state">
                    <svg class="empty-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                        <path d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z"/>
                    </svg>
                    <p>No files yet</p>
                </div>
            `;
        }
    }
    
    async downloadFile(transferId) {
        try {
            const infoRes = await fetch(`/api/transfer/${transferId}?userId=${this.userId}`);
            const info = await infoRes.json();
            
            const fileRes = await fetch(`/api/file/download/${transferId}?userId=${this.userId}`);
            const encrypted = await fileRes.blob();
            
            const decrypted = await window.cryptoUtils.decryptFile(
                await encrypted.arrayBuffer(),
                info.encryptionKey
            );
            
            const blob = new Blob([decrypted]);
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = info.filename;
            a.click();
            URL.revokeObjectURL(url);
            
            this.showToast('File downloaded');
            setTimeout(() => this.loadFiles(), 1000);
        } catch (error) {
            this.showToast('Download failed');
        }
    }
    
    formatSize(bytes) {
        const sizes = ['B', 'KB', 'MB', 'GB'];
        if (bytes === 0) return '0 B';
        const i = Math.floor(Math.log(bytes) / Math.log(1024));
        return Math.round(bytes / Math.pow(1024, i) * 100) / 100 + ' ' + sizes[i];
    }
    
    showToast(message) {
        const toast = document.getElementById('toast');
        document.getElementById('toast-message').textContent = message;
        toast.classList.add('show');
        setTimeout(() => toast.classList.remove('show'), 3000);
    }
}

const app = new SecureShare();
window.app = app;
EOF

# Set permissions
chown -R $SERVICE_USER:$SERVICE_USER "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod 700 "$APP_DIR/uploads"

# Create systemd service
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=SecureShare - Encrypted File Transfer Service
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node $APP_DIR/server.js
Restart=always
RestartSec=10
StandardOutput=append:$APP_DIR/logs/secureshare.log
StandardError=append:$APP_DIR/logs/secureshare.error.log
Environment=NODE_ENV=production
Environment=PORT=3456

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

# Create nginx config (optional)
if command -v nginx &> /dev/null; then
    cat > "/etc/nginx/sites-available/secureshare" << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:3456;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/secureshare /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
fi

echo "✅ xsukax SecureShare installed and running as a service!"
echo ""
echo "📍 Access points:"
echo "   • Direct: http://localhost:3456"
echo "   • Nginx: http://localhost (if nginx installed)"
echo ""
echo "🔧 Service commands:"
echo "   • Status: systemctl status $SERVICE_NAME"
echo "   • Logs: journalctl -u $SERVICE_NAME -f"
echo "   • Restart: systemctl restart $SERVICE_NAME"
echo "   • Stop: systemctl stop $SERVICE_NAME"
echo ""
echo "🎨 Features:"
echo "   • Minimal luxury design"
echo "   • Click-to-copy ID"
echo "   • Auto-start on boot"
echo "   • Runs as system service"
echo "   • Files deleted 1 hour after download"