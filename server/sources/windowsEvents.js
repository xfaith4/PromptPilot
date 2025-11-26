const config = require('../config');
const telemetryStore = require('../telemetryStore');
const logger = require('../logger');
const { runJson } = require('../utils/powershell');

const normalizeArray = (maybeArray) => {
    if (!maybeArray) return [];
    if (Array.isArray(maybeArray)) return maybeArray;
    return [maybeArray];
};

const buildScript = () => {
    const logs = config.windows.logNames.map((log) => `'${log.replace(/'/g, "''")}'`).join(',');
    const levels = config.windows.levels.length ? config.windows.levels.join(',') : '1,2,3';

    return `
$logs = @(${logs});
$levels = @(${levels});
$events = foreach ($log in $logs) {
    Get-WinEvent -FilterHashtable @{ LogName = $log; Level = $levels } -MaxEvents 200 |
        Select-Object @{
            Name = 'logName';
            Expression = { $_.LogName }
        }, @{
            Name = 'provider';
            Expression = { $_.ProviderName }
        }, @{
            Name = 'recordId';
            Expression = { $_.RecordId }
        }, @{
            Name = 'id';
            Expression = { $_.Id }
        }, @{
            Name = 'level';
            Expression = { $_.LevelDisplayName }
        }, @{
            Name = 'message';
            Expression = { $_.Message }
        }, @{
            Name = 'timestamp';
            Expression = { $_.TimeCreated.ToUniversalTime().ToString('o') }
        }
}
$events | Sort-Object timestamp | Select-Object -Last 400 | ConvertTo-Json -Depth 3 -Compress
`.trim();
};

const poll = async () => {
    telemetryStore.updateIngestStatus('windows', { status: 'running', lastRun: Date.now(), error: null });
    try {
        const raw = await runJson(buildScript(), { timeoutMs: 30000 });
        const events = normalizeArray(raw).map((event) => ({
            ...event,
            timestamp: event.timestamp ? new Date(event.timestamp).getTime() : Date.now(),
        }));
        telemetryStore.addWindowsEvents(events);
        telemetryStore.updateIngestStatus('windows', { status: 'healthy', lastSuccess: Date.now(), error: null });
        return events.length;
    } catch (error) {
        telemetryStore.updateIngestStatus('windows', { status: 'error', error: error.message });
        logger.error('Windows event poll failed', error);
        return 0;
    }
};

const start = () => {
    if (!config.windows.enabled) {
        telemetryStore.updateIngestStatus('windows', { status: 'disabled' });
        return;
    }
    const interval = Math.max(config.windows.pollIntervalMs, 15000);
    const execute = async () => {
        await poll();
        setTimeout(execute, interval);
    };
    execute().catch((error) => logger.error('Windows event initial poll failed', error));
};

module.exports = {
    start,
    poll,
};
