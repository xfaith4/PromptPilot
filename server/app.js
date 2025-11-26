const path = require('path');
const express = require('express');
const cors = require('cors');
const config = require('./config');
const logger = require('./logger');
const telemetryStore = require('./telemetryStore');
const sources = require('./sources');

const app = express();

if (config.server.enableCors) {
    app.use(
        cors({
            origin: true,
            credentials: true,
        }),
    );
}

app.get('/api/dashboard', (req, res) => {
    try {
        const payload = telemetryStore.toPayload();
        res.json(payload);
    } catch (error) {
        logger.error('Failed to build dashboard payload', error);
        res.status(500).json({ error: 'Dashboard unavailable' });
    }
});

app.get('/api/health', (req, res) => {
    res.json({
        generatedAt: new Date().toISOString(),
        ingest: telemetryStore.buildIngestHealth(),
    });
});

const sseClients = new Set();

const sendEvent = (res, payload) => {
    res.write(`data: ${JSON.stringify(payload)}\n\n`);
};

app.get('/api/stream', (req, res) => {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders?.();
    const payload = telemetryStore.toPayload();
    sendEvent(res, payload);

    const listener = (update) => {
        try {
            sendEvent(res, update);
        } catch (error) {
            logger.warn('Failed to push SSE update', error);
        }
    };

    telemetryStore.on('update', listener);
    sseClients.add(res);

    req.on('close', () => {
        telemetryStore.off('update', listener);
        sseClients.delete(res);
    });
});

app.use(express.static(config.server.staticDir));

app.get('*', (req, res, next) => {
    if (req.path.startsWith('/api/')) {
        return next();
    }
    return res.sendFile(path.join(config.server.staticDir, 'index.html'));
});

const server = app.listen(config.server.port, () => {
    logger.info(`Ops Telemetry Control Room listening on http://localhost:${config.server.port}`);
});

const shutdown = () => {
    logger.info('Shutting down telemetry server');
    sseClients.forEach((client) => client.end());
    server.close(() => {
        process.exit(0);
    });
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

sources.start();
