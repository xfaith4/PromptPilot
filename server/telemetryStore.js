const EventEmitter = require('events');
const crypto = require('crypto');
const dayjs = require('dayjs');
const config = require('./config');
const logger = require('./logger');

const HISTORY_WINDOW_MS = config.dashboard.timeRanges['24h'] * 2;

const formatTimestamp = (input = new Date()) => dayjs(input).format('YYYY-MM-DD HH:mm:ss');

const severityFromThresholds = (value, { warning, critical }) => {
    if (Number.isNaN(value) || value === undefined || value === null) {
        return 'stable';
    }
    if (value >= critical) return 'critical';
    if (value >= warning) return 'warning';
    return 'stable';
};

const safePercentage = (part, total) => {
    if (!total) return 0;
    return (part / total) * 100;
};

const pruneHistory = (collection) => {
    const cutoff = Date.now() - HISTORY_WINDOW_MS;
    while (collection.length && collection[0].timestamp < cutoff) {
        collection.shift();
    }
};

const bucketCountForRange = (rangeMs) => {
    const fifteenMinutes = 15 * 60 * 1000;
    const oneHour = 60 * 60 * 1000;
    const sixHours = 6 * oneHour;
    if (rangeMs <= fifteenMinutes) return 12;
    if (rangeMs <= oneHour) return 12;
    if (rangeMs <= sixHours) return 12;
    return 24;
};

const buildTimeBuckets = (rangeMs, bucketCount) => {
    const now = Date.now();
    const width = rangeMs / bucketCount;
    const buckets = [];
    for (let index = bucketCount - 1; index >= 0; index -= 1) {
        const end = now - (bucketCount - 1 - index) * width;
        const start = end - width;
        buckets.push({
            index,
            start,
            end,
            label: labelForBucket(end, rangeMs),
            values: [],
        });
    }
    return buckets;
};

const labelForBucket = (endTs, rangeMs) => {
    const diffHours = rangeMs / (60 * 60 * 1000);
    if (diffHours >= 12) {
        const hoursAgo = Math.round((Date.now() - endTs) / (60 * 60 * 1000));
        if (hoursAgo === 0) return 'now';
        return `-${hoursAgo}h`;
    }
    return dayjs(endTs).format('HH:mm');
};

const assignToBucket = (buckets, timestamp, value) => {
    for (let i = buckets.length - 1; i >= 0; i -= 1) {
        const bucket = buckets[i];
        if (timestamp > bucket.start && timestamp <= bucket.end) {
            bucket.values.push(value);
            return;
        }
    }
    if (buckets.length) buckets[0].values.push(value);
};

const topOccurrences = (records, key, limit = 5) => {
    const counts = new Map();
    records.forEach((record) => {
        const bucketKey = record[key] ?? 'unknown';
        counts.set(bucketKey, (counts.get(bucketKey) ?? 0) + 1);
    });
    return Array.from(counts.entries())
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit)
        .map(([label, count]) => ({ label, count }));
};

class TelemetryStore extends EventEmitter {
    constructor() {
        super();
        this.reset();
    }

    reset() {
        this.iisRequests = [];
        this.windowsEvents = [];
        this.routerEvents = [];
        this.cache = null;
        this.seenIisEntries = new Set();
        this.seenWindowsEvents = new Set();
        this.ingestStatus = {
            windows: { status: 'unknown', lastRun: null, lastSuccess: null, error: null },
            iis: { status: 'unknown', lastRun: null, lastSuccess: null, error: null },
            router: { status: config.router.enabled ? 'listening' : 'disabled', lastRun: null, lastSuccess: null, error: null },
        };
    }

    updateIngestStatus(target, updates = {}) {
        if (!this.ingestStatus[target]) return;
        this.ingestStatus[target] = {
            ...this.ingestStatus[target],
            ...updates,
        };
    }

    addIisEntries(entries = []) {
        if (!entries.length) return;
        const initialLength = this.iisRequests.length;
        entries.forEach((entry) => {
            const key = this.hashEntry(entry);
            if (this.seenIisEntries.has(key)) return;
            this.seenIisEntries.add(key);
            this.iisRequests.push({
                ...entry,
                timestamp: typeof entry.timestamp === 'number' ? entry.timestamp : new Date(entry.timestamp).getTime(),
            });
        });
        this.iisRequests.sort((a, b) => a.timestamp - b.timestamp);
        pruneHistory(this.iisRequests);
        if (this.iisRequests.length !== initialLength) {
            this.invalidateCache();
        }
    }

    hashEntry(entry) {
        return crypto
            .createHash('sha1')
            .update(
                [
                    entry.file ?? '',
                    entry.date ?? '',
                    entry.time ?? '',
                    entry.cIp ?? '',
                    entry.csUriStem ?? '',
                    entry.scStatus ?? '',
                    entry.scSubstatus ?? '',
                    entry.scWin32Status ?? '',
                ].join('|'),
            )
            .digest('hex');
    }

    addWindowsEvents(events = []) {
        if (!events.length) return;
        const initialLength = this.windowsEvents.length;
        events.forEach((event) => {
            const key = `${event.logName ?? ''}:${event.recordId ?? ''}`;
            if (this.seenWindowsEvents.has(key)) return;
            this.seenWindowsEvents.add(key);
            this.windowsEvents.push({
                ...event,
                timestamp: typeof event.timestamp === 'number' ? event.timestamp : new Date(event.timestamp ?? event.timeCreated).getTime(),
            });
        });
        this.windowsEvents.sort((a, b) => a.timestamp - b.timestamp);
        pruneHistory(this.windowsEvents);
        if (this.windowsEvents.length !== initialLength) {
            this.invalidateCache();
        }
    }

    addRouterEvent(event) {
        this.routerEvents.push({
            ...event,
            timestamp: typeof event.timestamp === 'number' ? event.timestamp : Date.now(),
        });
        this.routerEvents.sort((a, b) => a.timestamp - b.timestamp);
        pruneHistory(this.routerEvents);
        this.invalidateCache();
    }

    invalidateCache() {
        this.cache = null;
        this.emitUpdate();
    }

    emitUpdate() {
        try {
            const payload = this.toPayload();
            this.emit('update', payload);
        } catch (error) {
            logger.error('Failed to compute telemetry payload', error);
        }
    }

    toPayload() {
        if (this.cache) {
            return this.cache;
        }

        const now = Date.now();
        const payload = {
            generatedAt: formatTimestamp(now),
            timeRanges: {},
            alerts: [],
            ingestHealth: this.buildIngestHealth(),
        };

        Object.entries(config.dashboard.timeRanges).forEach(([label, rangeMs]) => {
            payload.timeRanges[`prod:${label}`] = this.buildRange(rangeMs, now);
        });

        payload.alerts = this.buildAlerts(payload);

        this.cache = payload;
        return payload;
    }

    buildRange(rangeMs, now) {
        const since = now - rangeMs;
        const requests = this.iisRequests.filter((entry) => entry.timestamp >= since);
        const windowsEvents = this.windowsEvents.filter((entry) => entry.timestamp >= since);
        const routerEvents = this.routerEvents.filter((entry) => entry.timestamp >= since);

        const iisStats = this.buildIisStats(requests, rangeMs, now);
        const authStats = this.buildAuthStats(requests);
        const windowsStats = this.buildWindowsStats(windowsEvents, rangeMs, now);
        const routerStats = this.buildRouterStats(routerEvents, rangeMs, now);

        return {
            kpi: {
                'iis-5xx': iisStats.summary,
                'auth-failures': authStats.summary,
                'windows-events': windowsStats.summary,
                'router-syslog': routerStats.summary,
            },
            charts: {
                'iis-5xx': iisStats.chart,
                'auth-failures': authStats.chart,
                'windows-events': windowsStats.chart,
                router: routerStats.chart,
            },
        };
    }

    buildIisStats(requests, rangeMs, now) {
        const total = requests.length;
        const fiveHundreds = requests.filter((entry) => {
            const status = parseInt(entry.scStatus ?? entry.status, 10);
            return status >= 500 && status < 600;
        });
        const rate = parseFloat(safePercentage(fiveHundreds.length, total).toFixed(2));
        const baseline = parseFloat((config.dashboard.alertSettings.iis5xx.warning / 2).toFixed(2));
        const delta = parseFloat((rate - baseline).toFixed(2));
        const severity = severityFromThresholds(rate, config.dashboard.alertSettings.iis5xx);

        const bucketCount = bucketCountForRange(rangeMs);
        const buckets = buildTimeBuckets(rangeMs, bucketCount);
        requests.forEach((entry) => {
            assignToBucket(buckets, entry.timestamp, entry);
        });

        const actualSeries = buckets.map((bucket) => {
            const bucketTotal = bucket.values.length;
            if (!bucketTotal) return 0;
            const bucket5xx = bucket.values.filter((value) => {
                const status = parseInt(value.scStatus ?? value.status, 10);
                return status >= 500 && status < 600;
            });
            return parseFloat(safePercentage(bucket5xx.length, bucketTotal).toFixed(2));
        });

        const baselineSeries = buckets.map(() => baseline);

        return {
            summary: {
                rate,
                baseline,
                delta,
                severity,
            },
            chart: {
                labels: buckets.map((bucket) => bucket.label),
                series: {
                    actual: actualSeries,
                    baseline: baselineSeries,
                },
            },
        };
    }

    buildAuthStats(requests) {
        const authRequests = requests.filter((entry) => {
            const status = parseInt(entry.scStatus ?? entry.status, 10);
            return config.iis.authFailureStatuses.includes(status);
        });

        const total = authRequests.length;
        const offenders = topOccurrences(authRequests, 'cIp', 5);
        const topOffender = offenders[0] ?? { label: '--', count: 0 };
        const severity = severityFromThresholds(total, config.dashboard.alertSettings.authFailures);

        return {
            summary: {
                total,
                topOffender: topOffender.label,
                topCount: topOffender.count,
                severity,
            },
            chart: {
                labels: offenders.map((item) => item.label),
                series: {
                    counts: offenders.map((item) => item.count),
                },
            },
        };
    }

    buildWindowsStats(events, rangeMs, now) {
        const total = events.length;
        const recentWindow = now - 10 * 60 * 1000;
        const recent = events.filter((event) => event.timestamp >= recentWindow).length;

        const hoursInRange = rangeMs / (60 * 60 * 1000);
        const perHour = hoursInRange ? total / hoursInRange : total;
        const baselinePerHour = config.dashboard.alertSettings.windowsEventsPerHour.warning;
        const deltaPercent = baselinePerHour ? ((perHour - baselinePerHour) / baselinePerHour) * 100 : 0;
        const trendLabel = `${deltaPercent >= 0 ? '+' : ''}${deltaPercent.toFixed(0)}% vs baseline`;
        const severity = severityFromThresholds(perHour, config.dashboard.alertSettings.windowsEventsPerHour);

        const bucketCount = bucketCountForRange(rangeMs);
        const buckets = buildTimeBuckets(rangeMs, bucketCount);

        events.forEach((event) => {
            assignToBucket(buckets, event.timestamp, event);
        });

        const buildSeries = (predicate) =>
            buckets.map((bucket) => bucket.values.filter(predicate).length);

        const chart = {
            labels: buckets.map((bucket) => bucket.label),
            series: {
                critical: buildSeries((event) => (event.level ?? event.levelDisplayName) === 'Critical' || event.level === 1),
                error: buildSeries((event) => (event.level ?? event.levelDisplayName) === 'Error' || event.level === 2),
                warning: buildSeries((event) => (event.level ?? event.levelDisplayName) === 'Warning' || event.level === 3),
            },
        };

        return {
            summary: {
                count: total,
                recent,
                trend: trendLabel,
                severity,
            },
            chart,
        };
    }

    buildRouterStats(events, rangeMs) {
        const bursts = this.countBursts(events);
        const wanDrops = events.filter((event) => event.classification === 'wan').length;
        const authAlerts = events.filter((event) => event.classification === 'auth').length;
        const severity = severityFromThresholds(bursts, config.dashboard.alertSettings.routerBursts);

        const bucketCount = bucketCountForRange(rangeMs);
        const buckets = buildTimeBuckets(rangeMs, bucketCount);
        events.forEach((event) => assignToBucket(buckets, event.timestamp, event));

        const chart = {
            labels: buckets.map((bucket) => bucket.label),
            series: {
                wanDrops: buckets.map((bucket) => bucket.values.filter((event) => event.classification === 'wan').length),
                dhcp: buckets.map((bucket) => bucket.values.filter((event) => event.classification === 'dhcp').length),
                auth: buckets.map((bucket) => bucket.values.filter((event) => event.classification === 'auth').length),
            },
        };

        return {
            summary: {
                bursts,
                wanDrops,
                authAlerts,
                severity,
            },
            chart,
        };
    }

    countBursts(events) {
        if (!events.length) return 0;
        const { burstWindowMs, burstThreshold } = config.router;
        let bursts = 0;
        let windowStart = 0;
        for (let i = 0; i < events.length; i += 1) {
            windowStart = events[i].timestamp;
            let count = 1;
            for (let j = i + 1; j < events.length; j += 1) {
                if (events[j].timestamp - windowStart <= burstWindowMs) {
                    count += 1;
                } else {
                    break;
                }
            }
            if (count >= burstThreshold) {
                bursts += 1;
                i += count - 1;
            }
        }
        return bursts;
    }

    buildAlerts(payload) {
        const alerts = [];
        const latest24h = payload.timeRanges['prod:24h'] ?? null;
        if (!latest24h) return alerts;

        const kpi = latest24h.kpi;
        if (!kpi) return alerts;

        if (kpi['iis-5xx'].severity !== 'stable') {
            alerts.push({
                id: 'iis-5xx',
                metric: 'iis-5xx',
                title: 'IIS 5xx spike detected',
                subtitle: `Error rate ${kpi['iis-5xx'].rate}% vs baseline ${kpi['iis-5xx'].baseline}%`,
                window: '24h',
                severity: kpi['iis-5xx'].severity,
                severityLabel: kpi['iis-5xx'].severity.replace(/^\w/, (c) => c.toUpperCase()),
                impact: `${this.iisRequests.length} total requests observed`,
                topOffenders: payload.timeRanges['prod:24h'].charts['auth-failures'].series.counts.map((count, index) => ({
                    label: payload.timeRanges['prod:24h'].charts['auth-failures'].labels[index],
                    count,
                    detail: 'Repeated authentication failures',
                })),
                timeline: this.buildTimelineFromBuckets(payload.timeRanges['prod:24h'].charts['iis-5xx']),
                actions: [
                    'Validate upstream dependencies (database, authentication services).',
                    'Review the highlighted offending IPs for abuse.',
                ],
                tags: ['IIS', '5xx', 'Error Rate'],
                sql: 'SELECT * FROM rpt.iis_errors_rolling_24h WHERE status >= 500;',
            });
        }

        if (kpi['auth-failures'].severity !== 'stable') {
            alerts.push({
                id: 'auth-failures',
                metric: 'auth-failures',
                title: 'Authentication failure flood',
                subtitle: `${kpi['auth-failures'].total} failed attempts across last 24h`,
                window: '24h',
                severity: kpi['auth-failures'].severity,
                severityLabel: kpi['auth-failures'].severity.replace(/^\w/, (c) => c.toUpperCase()),
                impact: `Top offender ${kpi['auth-failures'].topOffender}`,
                topOffenders: payload.timeRanges['prod:24h'].charts['auth-failures'].labels.map((label, index) => ({
                    label,
                    count: payload.timeRanges['prod:24h'].charts['auth-failures'].series.counts[index],
                    detail: '401/403 observed',
                })),
                timeline: this.buildTimelineFromBuckets(payload.timeRanges['prod:6h'].charts['iis-5xx']),
                actions: [
                    'Check firewall ACLs or WAF signatures for brute-force mitigation.',
                    'Coordinate with IAM team to validate legitimate activity.',
                ],
                tags: ['IIS', 'Authentication', 'Security'],
                sql: 'SELECT * FROM rpt.iis_auth_failures WHERE observed_at >= now() - interval \'1 day\';',
            });
        }

        if (kpi['windows-events'].severity !== 'stable') {
            alerts.push({
                id: 'windows-events',
                metric: 'windows-events',
                title: 'Windows critical/error surge',
                subtitle: `${kpi['windows-events'].count} high severity events`,
                window: '24h',
                severity: kpi['windows-events'].severity,
                severityLabel: kpi['windows-events'].severity.replace(/^\w/, (c) => c.toUpperCase()),
                impact: `${kpi['windows-events'].recent} events in last 10 min`,
                timeline: this.buildTimelineFromBuckets(payload.timeRanges['prod:24h'].charts['windows-events']),
                tags: ['Windows', 'EventLog'],
                actions: [
                    'Drill into Event Viewer for the nodes involved.',
                    'Confirm recent patches or deployments did not trigger alerts.',
                ],
                sql: 'SELECT * FROM rpt.windows_events WHERE level IN (\'Critical\', \'Error\', \'Warning\');',
            });
        }

        if (kpi['router-syslog'].severity !== 'stable') {
            alerts.push({
                id: 'router-syslog',
                metric: 'router-syslog',
                title: 'Router syslog burst',
                subtitle: `${kpi['router-syslog'].bursts} bursts detected on WAN edge`,
                window: '24h',
                severity: kpi['router-syslog'].severity,
                severityLabel: kpi['router-syslog'].severity.replace(/^\w/, (c) => c.toUpperCase()),
                impact: `${kpi['router-syslog'].wanDrops} WAN drop events`,
                tags: ['Network', 'Syslog'],
                timeline: this.buildTimelineFromBuckets(payload.timeRanges['prod:24h'].charts.router),
                actions: [
                    'Check WAN provider status page and SNMP metrics.',
                    'Validate router HA pair status and failover logs.',
                ],
                sql: 'SELECT * FROM rpt.router_syslog_bursts WHERE observed_at >= now() - interval \'1 day\';',
            });
        }

        return alerts;
    }

    buildTimelineFromBuckets(chart) {
        if (!chart) return [];
        const { labels, series } = chart;
        if (!labels || !series) return [];
        const values = series.actual ?? series.critical ?? series.wanDrops ?? [];
        return labels.map((label, index) => ({
            time: label,
            detail: `${values[index] ?? 0} events`,
        }));
    }

    buildIngestHealth() {
        return Object.entries(this.ingestStatus).map(([key, status]) => ({
            name: this.labelForIngestKey(key),
            status: this.statusToBadge(status.status),
            statusLabel: this.statusLabel(status.status),
            lag: status.lag ?? '--',
            lastRun: status.lastRun ? formatTimestamp(status.lastRun) : '--',
            notes: status.error
                ? String(status.error).slice(0, 120)
                : status.status === 'disabled'
                  ? 'Source disabled by configuration'
                  : status.status === 'listening'
                    ? 'Awaiting messages'
                    : 'Healthy',
        }));
    }

    labelForIngestKey(key) {
        switch (key) {
            case 'windows':
                return 'Windows EventLog Poller';
            case 'iis':
                return 'IIS Log Tailer';
            case 'router':
                return 'Router Syslog Listener';
            default:
                return key;
        }
    }

    statusToBadge(status) {
        if (status === 'healthy') return 'stable';
        if (status === 'listening') return 'stable';
        if (status === 'disabled') return 'stable';
        if (status === 'warning') return 'warning';
        if (status === 'error') return 'critical';
        if (status === 'unknown') return 'warning';
        return 'warning';
    }

    statusLabel(status) {
        switch (status) {
            case 'healthy':
                return 'Healthy';
            case 'listening':
                return 'Listening';
            case 'disabled':
                return 'Disabled';
            case 'warning':
                return 'Warning';
            case 'error':
                return 'Error';
            default:
                return 'Unknown';
        }
    }
}

module.exports = new TelemetryStore();
