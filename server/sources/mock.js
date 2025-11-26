const crypto = require('crypto');
const telemetryStore = require('../telemetryStore');
const config = require('../config');
const logger = require('../logger');

const random = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

const buildMockIisEntries = (count) => {
    const statuses = [200, 200, 200, 302, 401, 403, 500, 502, 503];
    const routes = ['/auth/login', '/auth/token', '/inventory/api', '/orders/api', '/health', '/metrics'];
    const clients = ['203.0.113.24', '198.51.100.18', '192.0.2.42', '10.15.22.94', '10.15.200.5'];

    return Array.from({ length: count }).map(() => {
        const status = pick(statuses);
        const date = new Date(Date.now() - random(0, 60 * 60 * 1000));
        const iso = date.toISOString();
        return {
            file: `mock-${date.getUTCFullYear()}${date.getUTCMonth() + 1}.log`,
            date: iso.slice(0, 10),
            time: iso.slice(11, 19),
            timestamp: date.getTime(),
            cIp: pick(clients),
            csUriStem: pick(routes),
            csMethod: pick(['GET', 'POST']),
            scStatus: status,
            scSubstatus: 0,
            scWin32Status: status === 200 ? 0 : 2148074254,
        };
    });
};

const buildMockWindowsEvents = (count) => {
    const providers = ['IIS', 'MSSQLSERVER', 'System', 'Application Error'];
    const levels = [
        { label: 'Critical', level: 1 },
        { label: 'Error', level: 2 },
        { label: 'Warning', level: 3 },
    ];
    return Array.from({ length: count }).map(() => {
        const date = new Date(Date.now() - random(0, 2 * 60 * 60 * 1000));
        const level = pick(levels);
        return {
            logName: 'System',
            provider: pick(providers),
            recordId: crypto.randomUUID(),
            id: random(1000, 9999),
            level: level.label,
            message: `${level.label} mock event`,
            timestamp: date.getTime(),
        };
    });
};

const buildMockRouterEvents = (count) => {
    const hosts = ['edge-fw-01', 'edge-fw-02', 'core-router-01'];
    const messages = [
        'WAN link down detected on interface Gi0/1',
        'DHCP warning: pool nearing exhaustion',
        'Authentication failure for admin from 203.0.113.55',
        'WAN link restored on interface Gi0/1',
    ];
    return Array.from({ length: count }).map(() => {
        const message = pick(messages);
        return {
            host: pick(hosts),
            message,
            timestamp: Date.now() - random(0, 30 * 60 * 1000),
            classification: message.includes('WAN')
                ? 'wan'
                : message.toLowerCase().includes('auth')
                    ? 'auth'
                    : 'dhcp',
        };
    });
};

const start = () => {
    if (!config.mock.enabled) return;
    logger.info('Starting mock telemetry generator');
    const produce = () => {
        telemetryStore.addIisEntries(buildMockIisEntries(random(5, 15)));
        telemetryStore.addWindowsEvents(buildMockWindowsEvents(random(2, 6)));
        buildMockRouterEvents(random(1, 3)).forEach((event) => telemetryStore.addRouterEvent(event));
        setTimeout(produce, config.mock.intervalMs);
    };
    produce();
};

module.exports = {
    start,
};
