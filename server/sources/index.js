const windows = require('./windowsEvents');
const iis = require('./iisLogs');
const router = require('./routerSyslog');
const mock = require('./mock');
const config = require('../config');
const logger = require('../logger');

const start = () => {
    logger.info('Initializing telemetry sources');
    windows.start();
    iis.start();
    router.start();
    if (config.mock.enabled) {
        mock.start();
    }
};

module.exports = {
    start,
};
