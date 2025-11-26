const formatTs = () => new Date().toISOString();

const log = (level, ...args) => {
    const prefix = `[${level.toUpperCase()} ${formatTs()}]`;
    // eslint-disable-next-line no-console
    console[level === 'error' ? 'error' : 'log'](prefix, ...args);
};

module.exports = {
    info: (...args) => log('info', ...args),
    warn: (...args) => log('warn', ...args),
    error: (...args) => log('error', ...args),
};
