const Dashboard = (() => {
    const state = {
        data: null,
        charts: {},
        autoRefreshTimer: null,
        eventSource: null,
        activeAlertId: null,
    };

    const elements = {
        timeRange: document.getElementById('time-range'),
        environment: document.getElementById('environment'),
        autoRefresh: document.getElementById('auto-refresh'),
        applyFilters: document.getElementById('apply-filters'),
        manualRefresh: document.getElementById('refresh-dashboard'),
        lastUpdated: document.getElementById('last-updated'),
        alertSearch: document.getElementById('alert-search'),
        alertTable: document.getElementById('alert-table'),
        ingestHealthTable: document.getElementById('ingest-health-table'),
        drilldownBody: document.getElementById('drilldown-body'),
        drilldownPanel: document.getElementById('drilldown-panel'),
    };

    const fetchData = async () => {
        const response = await fetch('/api/dashboard', { cache: 'no-store' });
        if (!response.ok) {
            throw new Error(`Failed to load dashboard data: ${response.status}`);
        }
        return response.json();
    };

    const getRangeData = () => {
        if (!state.data) return null;
        const timeRange = elements.timeRange.value;
        const env = elements.environment.value;
        const rangeKey = `${env}:${timeRange}`;
        return state.data.timeRanges[rangeKey] ?? state.data.timeRanges[`prod:${timeRange}`];
    };

    const formatNumber = (value, options = {}) => {
        if (value === null || value === undefined || Number.isNaN(value)) return '--';
        return Intl.NumberFormat('en-US', options).format(value);
    };

    const updateTimestamp = (ts) => {
        elements.lastUpdated.textContent = `Last updated: ${ts}`;
    };

    const applySeverityBadges = (rangeData) => {
        const severityMap = {
            critical: 'severity-critical',
            warning: 'severity-warning',
            stable: 'severity-stable',
        };

        document.querySelectorAll('.kpi-card').forEach((card) => {
            const metric = card.dataset.metric;
            const severity = rangeData?.kpi?.[metric]?.severity ?? 'stable';
            const badge = card.querySelector('.badge');
            badge.classList.remove('severity-critical', 'severity-warning', 'severity-stable');
            badge.classList.add(severityMap[severity] ?? 'severity-stable');
            badge.textContent = severity.charAt(0).toUpperCase() + severity.slice(1);
        });
    };

    const renderKpis = (rangeData) => {
        if (!rangeData?.kpi) return;

        const { kpi } = rangeData;
        document.getElementById('kpi-iis-5xx').textContent = `${formatNumber(kpi['iis-5xx'].rate, { maximumFractionDigits: 2 })}% error rate`;
        document.getElementById('kpi-iis-5xx-delta').textContent = `Baseline ${formatNumber(kpi['iis-5xx'].baseline, { maximumFractionDigits: 2 })}% · Δ ${formatNumber(kpi['iis-5xx'].delta, { maximumFractionDigits: 2 })}σ`;

        document.getElementById('kpi-auth-failures').textContent = `${formatNumber(kpi['auth-failures'].total)} attempts`;
        document.getElementById('kpi-auth-failures-delta').textContent = `Top offender: ${kpi['auth-failures'].topOffender} (${formatNumber(kpi['auth-failures'].topCount)} hits)`;

        document.getElementById('kpi-windows-events').textContent = `${formatNumber(kpi['windows-events'].count)} events`;
        document.getElementById('kpi-windows-events-delta').textContent = `Last 10 min: ${formatNumber(kpi['windows-events'].recent)} (${kpi['windows-events'].trend})`;

        document.getElementById('kpi-router-syslog').textContent = `${formatNumber(kpi['router-syslog'].bursts)} bursts`;
        document.getElementById('kpi-router-syslog-delta').textContent = `WAN drops: ${formatNumber(kpi['router-syslog'].wanDrops)} · Auth alerts: ${formatNumber(kpi['router-syslog'].authAlerts)}`;

        applySeverityBadges(rangeData);
    };

    const baseChartConfig = {
        type: 'line',
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                intersect: false,
                mode: 'index',
            },
            scales: {
                x: {
                    ticks: { color: 'rgba(203, 213, 225, 0.75)' },
                    grid: { color: 'rgba(148, 163, 184, 0.15)' },
                },
                y: {
                    ticks: { color: 'rgba(203, 213, 225, 0.75)' },
                    grid: { color: 'rgba(148, 163, 184, 0.12)' },
                },
            },
            plugins: {
                legend: {
                    labels: {
                        color: 'rgba(226, 232, 240, 0.9)',
                        boxWidth: 12,
                    },
                },
                tooltip: {
                    backgroundColor: 'rgba(15, 23, 42, 0.9)',
                    borderColor: 'rgba(148, 163, 184, 0.4)',
                    borderWidth: 1,
                },
            },
        },
    };

    const renderIisErrorsChart = (rangeData) => {
        const canvas = document.getElementById('chart-iis-errors');
        const { labels, series } = rangeData.charts['iis-5xx'];
        const datasets = [
            {
                label: '5xx %',
                data: series.actual,
                borderColor: '#f87171',
                backgroundColor: 'rgba(248, 113, 113, 0.15)',
                tension: 0.35,
                fill: true,
            },
            {
                label: 'Baseline %',
                data: series.baseline,
                borderColor: '#38bdf8',
                backgroundColor: 'rgba(56, 189, 248, 0.12)',
                tension: 0.35,
                borderDash: [6, 6],
            },
        ];

        updateChartInstance('iis-errors', canvas, datasets, labels);
    };

    const renderAuthFailuresChart = (rangeData) => {
        const canvas = document.getElementById('chart-auth-failures');
        const { labels, series } = rangeData.charts['auth-failures'];
        const datasets = [
            {
                type: 'bar',
                label: 'Attempts',
                data: series.counts,
                backgroundColor: '#38bdf8',
                borderRadius: 8,
                maxBarThickness: 42,
            },
        ];

        const chartConfig = {
            type: 'bar',
            options: {
                ...baseChartConfig.options,
                scales: {
                    ...baseChartConfig.options.scales,
                    x: {
                        ...baseChartConfig.options.scales.x,
                        ticks: {
                            ...baseChartConfig.options.scales.x.ticks,
                            maxRotation: 45,
                            minRotation: 45,
                        },
                    },
                    y: {
                        ...baseChartConfig.options.scales.y,
                        beginAtZero: true,
                    },
                },
            },
        };

        updateChartInstance('auth-failures', canvas, datasets, labels, chartConfig);
    };

    const renderWindowsEventsChart = (rangeData) => {
        const canvas = document.getElementById('chart-windows-events');
        const { labels, series } = rangeData.charts['windows-events'];
        const datasets = [
            {
                label: 'Critical',
                data: series.critical,
                borderColor: '#f87171',
                backgroundColor: 'rgba(248, 113, 113, 0.18)',
                fill: true,
                tension: 0.35,
            },
            {
                label: 'Error',
                data: series.error,
                borderColor: '#facc15',
                backgroundColor: 'rgba(250, 204, 21, 0.18)',
                fill: true,
                tension: 0.35,
            },
            {
                label: 'Warning',
                data: series.warning,
                borderColor: '#38bdf8',
                backgroundColor: 'rgba(56, 189, 248, 0.14)',
                fill: true,
                tension: 0.35,
            },
        ];

        updateChartInstance('windows-events', canvas, datasets, labels);
    };

    const renderRouterChart = (rangeData) => {
        const canvas = document.getElementById('chart-router-health');
        const { labels, series } = rangeData.charts['router'];
        const datasets = [
            {
                label: 'WAN Drops',
                data: series.wanDrops,
                borderColor: '#f87171',
                backgroundColor: 'rgba(248, 113, 113, 0.12)',
                fill: true,
                tension: 0.3,
            },
            {
                label: 'DHCP Storm',
                data: series.dhcp,
                borderColor: '#38bdf8',
                backgroundColor: 'rgba(56, 189, 248, 0.12)',
                fill: true,
                tension: 0.3,
            },
            {
                label: 'Admin Auth Fail',
                data: series.auth,
                borderColor: '#facc15',
                backgroundColor: 'rgba(250, 204, 21, 0.12)',
                fill: true,
                tension: 0.3,
            },
        ];

        updateChartInstance('router', canvas, datasets, labels);
    };

    const updateChartInstance = (chartKey, canvas, datasets, labels, overrides = baseChartConfig) => {
        if (state.charts[chartKey]) {
            state.charts[chartKey].data.datasets = datasets;
            state.charts[chartKey].data.labels = labels;
            state.charts[chartKey].update();
            return;
        }

        const config = {
            ...baseChartConfig,
            ...overrides,
            data: {
                labels,
                datasets,
            },
        };

        state.charts[chartKey] = new Chart(canvas.getContext('2d'), config);
    };

    const renderAlertsTable = (data) => {
        const alerts = data.alerts;
        const rows = alerts.map((alert) => {
            return `<tr data-alert-id="${alert.id}" data-metric="${alert.metric}">
                <td>
                    <div class="alert-title">${alert.title}</div>
                    <div class="muted">${alert.subtitle}</div>
                </td>
                <td>${alert.window}</td>
                <td><span class="badge severity-${alert.severity}">${alert.severityLabel}</span></td>
                <td>${alert.impact}</td>
            </tr>`;
        }).join('');
        elements.alertTable.innerHTML = rows;
    };

    const renderIngestHealth = (data) => {
        const rows = data.ingestHealth.map((task) => {
            return `<tr>
                <td>${task.name}</td>
                <td><span class="badge severity-${task.status}">${task.statusLabel}</span></td>
                <td>${task.lag}</td>
                <td>${task.lastRun}</td>
                <td>${task.notes}</td>
            </tr>`;
        }).join('');
        elements.ingestHealthTable.innerHTML = rows;
    };

    const findAlertById = (id) => state.data.alerts.find((alert) => alert.id === id);

    const renderDrilldown = (alert) => {
        if (!alert) {
            elements.drilldownBody.innerHTML = '<p class="muted">No alert selected.</p>';
            state.activeAlertId = null;
            return;
        }

        state.activeAlertId = alert.id;
        const offenders = alert.topOffenders?.map((offender) => `<li><strong>${offender.label}</strong> · ${offender.count} hits (${offender.detail})</li>`).join('') ?? '';
        const timeline = alert.timeline?.map((item) => `<li><strong>${item.time}</strong> – ${item.detail}</li>`).join('') ?? '';
        const actions = alert.actions?.map((action) => `<li>${action}</li>`).join('') ?? '';
        const tags = alert.tags?.map((tag) => `<span class="tag">${tag}</span>`).join('') ?? '';

        elements.drilldownBody.innerHTML = `
            <div>
                <h4>${alert.title}</h4>
                <p class="muted">${alert.detail}</p>
            </div>
            <dl class="detail-list">
                <div>
                    <dt>Window</dt>
                    <dd>${alert.window}</dd>
                </div>
                <div>
                    <dt>Impact</dt>
                    <dd>${alert.impact}</dd>
                </div>
                <div>
                    <dt>SQL</dt>
                    <dd><code>${alert.sql}</code></dd>
                </div>
            </dl>
            ${tags ? `<div class="tag-cloud">${tags}</div>` : ''}
            ${offenders ? `<section><h4>Top Offenders</h4><ul>${offenders}</ul></section>` : ''}
            ${timeline ? `<section><h4>Timeline</h4><ol>${timeline}</ol></section>` : ''}
            ${actions ? `<section><h4>Suggested Actions</h4><ul>${actions}</ul></section>` : ''}
            ${alert.links && alert.links.length ? `<section><h4>Drill-down Links</h4><ul>${alert.links.map((link) => `<li><a href="${link.href}" target="_blank" rel="noopener">${link.label}</a></li>`).join('')}</ul></section>` : ''}
        `;
    };

    const filterAlerts = () => {
        const query = elements.alertSearch.value.toLowerCase();
        Array.from(elements.alertTable.querySelectorAll('tr')).forEach((row) => {
            const text = row.textContent.toLowerCase();
            row.style.display = text.includes(query) ? '' : 'none';
        });
    };

    const attachEventListeners = () => {
        elements.applyFilters.addEventListener('click', () => refreshDashboard({ skipFetch: true }));
        elements.manualRefresh.addEventListener('click', () => refreshDashboard());
        elements.alertSearch.addEventListener('input', filterAlerts);

        document.querySelectorAll('.btn-link[data-alert-target]').forEach((btn) => {
            btn.addEventListener('click', () => {
                const alertId = btn.dataset.alertTarget;
                const alert = findAlertById(alertId);
                renderDrilldown(alert);
            });
        });

        elements.alertTable.addEventListener('click', (event) => {
            const row = event.target.closest('tr[data-alert-id]');
            if (!row) return;
            const alertId = row.dataset.alertId;
            const alert = findAlertById(alertId);
            renderDrilldown(alert);
        });

        elements.autoRefresh.addEventListener('change', () => {
            setAutoRefresh(elements.autoRefresh.value);
        });
    };

    const setAutoRefresh = (value) => {
        if (state.autoRefreshTimer) {
            clearInterval(state.autoRefreshTimer);
            state.autoRefreshTimer = null;
        }
        const interval = parseInt(value, 10);
        if (!Number.isNaN(interval) && interval > 0) {
            state.autoRefreshTimer = setInterval(refreshDashboard, interval * 1000);
        }
    };

    const refreshDashboard = async ({ skipFetch = false } = {}) => {
        try {
            if (!skipFetch || !state.data) {
                state.data = await fetchData();
            }
            const rangeData = getRangeData();
            if (!rangeData) {
                console.warn('No range data available for selection.');
                return;
            }

            renderKpis(rangeData);
            renderIisErrorsChart(rangeData);
            renderAuthFailuresChart(rangeData);
            renderWindowsEventsChart(rangeData);
            renderRouterChart(rangeData);
            renderAlertsTable(state.data);
            renderIngestHealth(state.data);
            updateTimestamp(state.data.generatedAt);
            filterAlerts();

            if (state.activeAlertId) {
                const alert = findAlertById(state.activeAlertId);
                if (alert) {
                    renderDrilldown(alert);
                }
            }
        } catch (error) {
            console.error('Dashboard refresh failed', error);
            elements.lastUpdated.textContent = 'Last updated: failed to refresh';
        }
    };

    const setupRealtimeStream = () => {
        if (state.eventSource) {
            state.eventSource.close();
            state.eventSource = null;
        }

        try {
            const eventSource = new EventSource('/api/stream');
            eventSource.onmessage = (event) => {
                try {
                    const payload = JSON.parse(event.data);
                    state.data = payload;
                    refreshDashboard({ skipFetch: true });
                } catch (error) {
                    console.error('Failed to parse realtime payload', error);
                }
            };
            eventSource.onerror = (error) => {
                console.error('Realtime stream disconnected', error);
                eventSource.close();
                state.eventSource = null;
                setTimeout(setupRealtimeStream, 5000);
            };
            state.eventSource = eventSource;
        } catch (error) {
            console.error('Realtime stream unavailable', error);
        }
    };

    const init = async () => {
        try {
            state.data = await fetchData();
            attachEventListeners();
            await refreshDashboard({ skipFetch: true });
            setAutoRefresh(elements.autoRefresh.value);
            setupRealtimeStream();
        } catch (error) {
            console.error('Failed to initialize dashboard', error);
            elements.lastUpdated.textContent = 'Last updated: failed to load data';
            elements.drilldownBody.innerHTML = '<p class="muted">Dashboard data unavailable.</p>';
        }
    };

    return { init };
})();

document.addEventListener('DOMContentLoaded', Dashboard.init);
