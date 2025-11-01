const path = require('path');

const rootDir = path.resolve(__dirname, '..');

const minutes = (value) => value * 60 * 1000;
const hours = (value) => minutes(value * 60);

module.exports = {
    server: {
        port: parseInt(process.env.PORT ?? '3001', 10),
        staticDir: path.join(rootDir, 'web'),
        enableCors: (process.env.CORS_ENABLED ?? '0') === '1',
    },
    dashboard: {
        environments: ['prod'],
        timeRanges: {
            '15m': minutes(15),
            '1h': hours(1),
            '6h': hours(6),
            '24h': hours(24),
        },
        alertSettings: {
            iis5xx: { warning: 2.5, critical: 5 },
            authFailures: { warning: 25, critical: 100 },
            windowsEventsPerHour: { warning: 40, critical: 75 },
            routerBursts: { warning: 2, critical: 4 },
        },
    },
    windows: {
        enabled: (process.env.WINDOWS_EVENTS_ENABLED ?? '1') === '1',
        logNames: (process.env.WINDOWS_EVENT_LOGS ?? 'System,Application').split(',').map((name) => name.trim()),
        levels: (process.env.WINDOWS_EVENT_LEVELS ?? '1,2,3')
            .split(',')
            .map((level) => parseInt(level.trim(), 10))
            .filter((level) => Number.isInteger(level)),
        pollIntervalMs: parseInt(process.env.WINDOWS_EVENT_INTERVAL_MS ?? '45000', 10),
    },
    iis: {
        enabled: (process.env.IIS_ENABLED ?? '1') === '1',
        logRoots: (process.env.IIS_LOG_ROOT ?? 'C:\\\\inetpub\\\\logs\\\\LogFiles')
            .split(';')
            .map((dir) => dir.trim())
            .filter(Boolean),
        pollIntervalMs: parseInt(process.env.IIS_POLL_INTERVAL_MS ?? '30000', 10),
        tailBytes: parseInt(process.env.IIS_TAIL_BYTES ?? (256 * 1024), 10),
        authFailureStatuses: (process.env.IIS_AUTH_STATUSES ?? '401,403,429')
            .split(',')
            .map((status) => parseInt(status.trim(), 10))
            .filter((status) => Number.isInteger(status)),
    },
    router: {
        enabled: (process.env.SYSLOG_ENABLED ?? '1') === '1',
        syslogPort: parseInt(process.env.SYSLOG_PORT ?? '514', 10),
        fallbackPort: parseInt(process.env.SYSLOG_FALLBACK_PORT ?? '5514', 10),
        interface: process.env.SYSLOG_BIND_ADDRESS ?? '0.0.0.0',
        burstWindowMs: parseInt(process.env.SYSLOG_BURST_WINDOW_MS ?? '60000', 10),
        burstThreshold: parseInt(process.env.SYSLOG_BURST_THRESHOLD ?? '20', 10),
    },
    mock: {
        enabled: (process.env.MOCK_MODE ?? '0') === '1',
        seed: process.env.MOCK_SEED ?? undefined,
        intervalMs: parseInt(process.env.MOCK_INTERVAL_MS ?? '15000', 10),
    },
};
