const dayjs = require('dayjs');

const ensureDayJs = (input) => (dayjs.isDayjs(input) ? input : dayjs(input));

const toIso = (input = new Date()) => ensureDayJs(input).toISOString();

const subtract = (input, ms) => ensureDayJs(input).subtract(ms, 'millisecond');

const createBuckets = ({ rangeMs, bucketCount, end = dayjs() }) => {
    const durationPerBucket = rangeMs / bucketCount;
    const buckets = [];
    for (let index = bucketCount - 1; index >= 0; index -= 1) {
        const bucketEnd = end.subtract((bucketCount - 1 - index) * durationPerBucket, 'millisecond');
        const bucketStart = bucketEnd.subtract(durationPerBucket, 'millisecond');
        buckets.push({
            index,
            start: bucketStart,
            end: bucketEnd,
            label: formatBucketLabel({ bucketStart, bucketEnd, rangeMs }),
            values: [],
        });
    }
    return buckets;
};

const formatBucketLabel = ({ bucketStart, bucketEnd, rangeMs }) => {
    const durationMinutes = rangeMs / 60000;
    if (durationMinutes >= 120) {
        return bucketEnd.format('HH:mm');
    }
    if (durationMinutes >= 60) {
        return bucketEnd.format('HH:mm');
    }
    return bucketEnd.format('HH:mm:ss');
};

module.exports = {
    createBuckets,
    ensureDayJs,
    formatBucketLabel,
    subtract,
    toIso,
};
