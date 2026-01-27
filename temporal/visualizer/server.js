const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const logDir = process.env.TEMPORAL_LOG_DIR || path.join(__dirname, '..', 'logs');
const eventsPath = path.join(logDir, 'events.jsonl');
const indexPath = path.join(__dirname, 'index.html');

function readEvents() {
  if (!fs.existsSync(eventsPath)) return [];
  const lines = fs.readFileSync(eventsPath, 'utf8').split('\n');
  const events = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch (_) {}
  }
  return events;
}

function summarizeRuns(events) {
  const runs = new Map();
  for (const ev of events) {
    if (!ev.workflowId || !ev.runId) continue;
    const key = `${ev.workflowId}::${ev.runId}`;
    if (!runs.has(key)) {
      runs.set(key, {
        workflowId: ev.workflowId,
        runId: ev.runId,
        last: ev.timestamp,
        steps: {},
      });
    }
    const run = runs.get(key);
    if (!run.last || (ev.timestamp && ev.timestamp > run.last)) run.last = ev.timestamp;
    const stepId = ev.stepId || ev.stepName || 'unknown';
    if (!run.steps[stepId]) run.steps[stepId] = { status: 'unknown' };
    if (ev.status === 'step_started') run.steps[stepId].status = 'running';
    if (ev.status === 'step_finished') {
      run.steps[stepId] = {
        status: ev.exitCode === 0 ? 'success' : 'failed',
        exitCode: ev.exitCode,
        durationSec: ev.durationSec,
        stdoutPath: ev.stdoutPath,
        stderrPath: ev.stderrPath,
      };
    }
  }

  const list = Array.from(runs.values()).map((run) => {
    const steps = Object.values(run.steps);
    const total = steps.length;
    const done = steps.filter((s) => s.status === 'success' || s.status === 'failed').length;
    const failed = steps.some((s) => s.status === 'failed');
    return {
      workflowId: run.workflowId,
      runId: run.runId,
      last: run.last,
      progress: `${done}/${total}`,
      status: failed ? 'failed' : done === total ? 'success' : 'running',
    };
  });

  return list.sort((a, b) => (a.last || '').localeCompare(b.last || '')).reverse();
}

function runDetails(events, runId) {
  const steps = {};
  let workflowId = null;
  for (const ev of events) {
    if (ev.runId !== runId) continue;
    workflowId = ev.workflowId || workflowId;
    const stepId = ev.stepId || ev.stepName || 'unknown';
    if (!steps[stepId]) steps[stepId] = { stepId };
    if (ev.status === 'step_started') steps[stepId].status = 'running';
    if (ev.status === 'step_finished') {
      steps[stepId].status = ev.exitCode === 0 ? 'success' : 'failed';
      steps[stepId].exitCode = ev.exitCode;
      steps[stepId].durationSec = ev.durationSec;
      steps[stepId].stdoutPath = ev.stdoutPath;
      steps[stepId].stderrPath = ev.stderrPath;
    }
  }
  return { workflowId, runId, steps: Object.values(steps) };
}

function sendJson(res, payload, code = 200) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload, null, 2));
}

function serveFile(res, filePath, contentType = 'text/plain') {
  if (!fs.existsSync(filePath)) {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  res.writeHead(200, { 'Content-Type': contentType });
  fs.createReadStream(filePath).pipe(res);
}

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);

  if (parsed.pathname === '/' || parsed.pathname === '/index.html') {
    return serveFile(res, indexPath, 'text/html');
  }

  if (parsed.pathname === '/api/events') {
    const runId = parsed.query.runId;
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });
    res.write('retry: 1000\n\n');

    let position = 0;
    const sendEvent = (ev) => {
      res.write(`data: ${JSON.stringify(ev)}\n\n`);
    };

    const bootstrap = () => {
      const events = readEvents();
      for (const ev of events) {
        if (!runId || ev.runId === runId) {
          sendEvent(ev);
        }
      }
      try {
        position = fs.statSync(eventsPath).size;
      } catch (_) {
        position = 0;
      }
    };

    const poll = () => {
      fs.stat(eventsPath, (err, stats) => {
        if (err || !stats) return;
        if (stats.size > position) {
          const stream = fs.createReadStream(eventsPath, { start: position, end: stats.size });
          let buffer = '';
          stream.on('data', (chunk) => { buffer += chunk.toString(); });
          stream.on('end', () => {
            position = stats.size;
            const lines = buffer.split('\n');
            for (const line of lines) {
              if (!line.trim()) continue;
              try {
                const ev = JSON.parse(line);
                if (!runId || ev.runId === runId) {
                  sendEvent(ev);
                }
              } catch (_) {}
            }
          });
        }
      });
    };

    bootstrap();
    const interval = setInterval(poll, 1000);

    req.on('close', () => {
      clearInterval(interval);
    });
    return;
  }

  if (parsed.pathname === '/api/runs') {
    const events = readEvents();
    return sendJson(res, summarizeRuns(events));
  }

  if (parsed.pathname.startsWith('/api/runs/')) {
    const runId = decodeURIComponent(parsed.pathname.replace('/api/runs/', ''));
    const events = readEvents();
    return sendJson(res, runDetails(events, runId));
  }

  if (parsed.pathname.startsWith('/logs/')) {
    const rel = parsed.pathname.replace('/logs/', '');
    const safe = rel.replace(/\.\./g, '');
    const filePath = path.join(logDir, safe);
    return serveFile(res, filePath, 'text/plain');
  }

  res.writeHead(404);
  res.end('not found');
});

const port = Number(process.env.PORT || 8787);
server.listen(port, () => {
  console.log(`Visualizer at http://localhost:${port}`);
  console.log(`Reading events from ${eventsPath}`);
});
