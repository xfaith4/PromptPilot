const { spawn } = require('child_process');
const logger = require('../logger');

const resolveBinary = () => {
    if (process.env.POWERSHELL_PATH) return process.env.POWERSHELL_PATH;
    if (process.platform === 'win32') return 'powershell.exe';
    return 'pwsh';
};

const runPowerShell = (script, { timeoutMs = 20000 } = {}) =>
    new Promise((resolve, reject) => {
        const binary = resolveBinary();
        const child = spawn(binary, ['-NoProfile', '-Command', script], { windowsHide: true });
        const stdout = [];
        const stderr = [];
        let finished = false;

        const killIfNeeded = () => {
            if (!finished) {
                finished = true;
                child.kill('SIGTERM');
                reject(new Error(`PowerShell execution timed out after ${timeoutMs} ms`));
            }
        };

        const timeout = setTimeout(killIfNeeded, timeoutMs);

        child.stdout.on('data', (data) => stdout.push(data));
        child.stderr.on('data', (data) => stderr.push(data));

        child.on('error', (error) => {
            clearTimeout(timeout);
            if (finished) return;
            finished = true;
            reject(error);
        });

        child.on('close', (code) => {
            clearTimeout(timeout);
            if (finished) return;
            finished = true;
            if (code !== 0) {
                const error = new Error(`PowerShell exited with code ${code}: ${Buffer.concat(stderr).toString()}`);
                error.code = code;
                error.stderr = Buffer.concat(stderr).toString();
                return reject(error);
            }
            resolve(Buffer.concat(stdout).toString());
        });
    });

const runJson = async (script, options) => {
    try {
        const output = await runPowerShell(script, options);
        const trimmed = output.trim();
        if (!trimmed) {
            return [];
        }
        return JSON.parse(trimmed);
    } catch (error) {
        logger.error('PowerShell JSON execution failed', error);
        throw error;
    }
};

module.exports = {
    runPowerShell,
    runJson,
};
