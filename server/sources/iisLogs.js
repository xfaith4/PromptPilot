const fs = require('fs/promises');
const path = require('path');
const telemetryStore = require('../telemetryStore');
const config = require('../config');
const logger = require('../logger');

const gatherLogFiles = async () => {
    const candidates = [];
    await Promise.all(
        config.iis.logRoots.map(async (root) => {
            try {
                const dirEntries = await fs.readdir(root, { withFileTypes: true });
                const logFiles = await Promise.all(
                    dirEntries
                        .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.log'))
                        .map(async (entry) => {
                            const fullPath = path.join(root, entry.name);
                            const stats = await fs.stat(fullPath);
                            return { path: fullPath, mtime: stats.mtimeMs };
                        }),
                );
                candidates.push(...logFiles);
            } catch (error) {
                logger.warn(`Failed to scan IIS log directory ${root}`, error);
            }
        }),
    );

    candidates.sort((a, b) => b.mtime - a.mtime);
    return candidates.slice(0, 8).map((file) => file.path);
};

const readTail = async (filePath, bytes) => {
    const handle = await fs.open(filePath, 'r');
    try {
        const stats = await handle.stat();
        const start = Math.max(0, stats.size - bytes);
        const length = stats.size - start;
        const buffer = Buffer.alloc(length);
        await handle.read(buffer, 0, length, start);
        return buffer.toString('utf8');
    } finally {
        await handle.close();
    }
};

const parseContent = (content, filePath) => {
    const entries = [];
    const lines = content.split(/\r?\n/);
    let fields = [];
    lines.forEach((line) => {
        if (!line || line.startsWith('#Software')) return;
        if (line.startsWith('#Fields:')) {
            fields = line
                .replace('#Fields:', '')
                .trim()
                .split(/\s+/)
                .filter(Boolean);
            return;
        }
        if (line.startsWith('#')) return;
        if (!fields.length) return;

        const values = line.split(/\s+/);
        const entry = { file: filePath };
        fields.forEach((field, index) => {
            entry[field] = values[index] ?? '';
        });

        const date = entry.date ?? entry['date'];
        const time = entry.time ?? entry['time'];
        const timestamp = Date.parse(`${date}T${(time ?? '').replace(',', '.')}Z`);
        entry.timestamp = Number.isNaN(timestamp) ? Date.now() : timestamp;
        entry.cIp = entry['c-ip'] ?? entry.cIp;
        entry.csUriStem = entry['cs-uri-stem'] ?? entry.csUriStem;
        entry.csMethod = entry['cs-method'] ?? entry.csMethod;
        entry.scStatus = entry['sc-status'] ?? entry.scStatus;
        entry.scSubstatus = entry['sc-substatus'] ?? entry.scSubstatus;
        entry.scWin32Status = entry['sc-win32-status'] ?? entry.scWin32Status;

        entries.push(entry);
    });
    return entries;
};

const poll = async () => {
    if (!config.iis.enabled) {
        telemetryStore.updateIngestStatus('iis', { status: 'disabled' });
        return 0;
    }

    telemetryStore.updateIngestStatus('iis', { status: 'running', lastRun: Date.now(), error: null });
    try {
        const files = await gatherLogFiles();
        const allEntries = [];
        // eslint-disable-next-line no-restricted-syntax
        for (const file of files) {
            try {
                const content = await readTail(file, config.iis.tailBytes);
                const entries = parseContent(content, file);
                allEntries.push(...entries);
            } catch (error) {
                logger.warn(`Failed to parse IIS log ${file}`, error);
            }
        }
        telemetryStore.addIisEntries(allEntries);
        telemetryStore.updateIngestStatus('iis', { status: 'healthy', lastSuccess: Date.now(), error: null });
        return allEntries.length;
    } catch (error) {
        telemetryStore.updateIngestStatus('iis', { status: 'error', error: error.message });
        logger.error('IIS log poll failed', error);
        return 0;
    }
};

const start = () => {
    if (!config.iis.enabled) {
        telemetryStore.updateIngestStatus('iis', { status: 'disabled' });
        return;
    }
    const interval = Math.max(config.iis.pollIntervalMs, 15000);
    const execute = async () => {
        await poll();
        setTimeout(execute, interval);
    };
    execute().catch((error) => logger.error('IIS log initial poll failed', error));
};

module.exports = {
    start,
    poll,
};
