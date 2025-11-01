const dgram = require('dgram');
const telemetryStore = require('../telemetryStore');
const config = require('../config');
const logger = require('../logger');

const classifyMessage = (message) => {
    const text = message.toLowerCase();
    if (/(wan|uplink|ppp|link).*(down|loss|drop)/.test(text)) return 'wan';
    if (/(auth|login|password|denied|fail)/.test(text)) return 'auth';
    if (/(dhcp|lease|bootp)/.test(text)) return 'dhcp';
    return 'info';
};

const parseSyslog = (buffer, rinfo) => {
    const raw = buffer.toString('utf8').trim();
    let body = raw;
    let facility = null;
    let severity = null;

    const priMatch = raw.match(/^<(\d+)>/);
    if (priMatch) {
        const pri = parseInt(priMatch[1], 10);
        if (!Number.isNaN(pri)) {
            severity = pri & 0x07;
            facility = pri >> 3;
        }
        body = raw.slice(priMatch[0].length).trim();
    }

    let timestamp = Date.now();
    let host = rinfo?.address;
    let message = body;
    const parts = body.split(/\s+/);

    const tryParseTimestamp = (candidateParts) => {
        const candidate = candidateParts.join(' ');
        const parsed = Date.parse(candidate);
        return Number.isNaN(parsed) ? null : parsed;
    };

    if (parts.length >= 4) {
        const monthDayTime = tryParseTimestamp(parts.slice(0, 3));
        if (monthDayTime) {
            timestamp = monthDayTime;
            host = parts[3];
            message = parts.slice(4).join(' ');
        } else {
            const isoParsed = Date.parse(parts[0]);
            if (!Number.isNaN(isoParsed)) {
                timestamp = isoParsed;
                host = parts[1];
                message = parts.slice(2).join(' ');
            }
        }
    }

    return {
        raw,
        message: message.trim(),
        timestamp,
        facility,
        severity,
        host,
        classification: classifyMessage(message),
    };
};

const start = () => {
    if (!config.router.enabled) {
        telemetryStore.updateIngestStatus('router', { status: 'disabled' });
        return;
    }

    const socket = dgram.createSocket('udp4');
    let boundPort = config.router.syslogPort;
    let attemptedFallback = false;

    const bind = (port) => {
        boundPort = port;
        socket.bind(port, config.router.interface);
    };

    socket.on('listening', () => {
        const address = socket.address();
        telemetryStore.updateIngestStatus('router', {
            status: 'listening',
            lastRun: Date.now(),
            error: null,
            notes: `Listening on udp://${address.address}:${address.port}`,
        });
        logger.info(`Syslog listener active on udp://${address.address}:${address.port}`);
    });

    socket.on('message', (msg, rinfo) => {
        const event = parseSyslog(msg, rinfo);
        telemetryStore.addRouterEvent(event);
        telemetryStore.updateIngestStatus('router', {
            status: 'healthy',
            lastSuccess: Date.now(),
            lag: '0s',
            error: null,
        });
    });

    socket.on('error', (error) => {
        logger.error('Syslog listener error', error);
        telemetryStore.updateIngestStatus('router', { status: 'error', error: error.message });
        if (!attemptedFallback && error.code === 'EACCES' && boundPort === config.router.syslogPort && config.router.fallbackPort !== config.router.syslogPort) {
            attemptedFallback = true;
            logger.warn(`Port ${boundPort} requires elevation, retrying on ${config.router.fallbackPort}`);
            bind(config.router.fallbackPort);
        } else {
            socket.close();
        }
    });

    bind(config.router.syslogPort);
};

module.exports = {
    start,
};
