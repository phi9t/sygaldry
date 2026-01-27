const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const logDir = process.env.TEMPORAL_LOG_DIR || path.join(__dirname, '..', 'logs');
const eventsPath = path.join(logDir, 'events.jsonl');
const indexPath = path.join(__dirname, 'index.html');

function readEvents() {
  if (!fs.existsSync(eventsPath)) {
    return [];
  }
  const lines = fs.readFileSync(eventsPath, 'utf8').split('\n');
  const events = [];
  for (const line of lines) {
    if (!line.trim()) {
      continue;
    }
    try {
      events.push(JSON.parse(line));
    } catch (_) {}
  }
  return events;
}

function parseTimestamp(value) {
  if (!value) {
    return null;
  }
  const timestamp = Date.parse(value);
  if (Number.isNaN(timestamp)) {
    return null;
  }
  return timestamp;
}

function safeName(value) {
  return String(value || '').trim().replace(/[\/\\\s:]+/g, '_');
}

function manifestPath(workflowId, runId) {
  return path.join(logDir, `${safeName(workflowId)}_${safeName(runId)}_plan.json`);
}

function readManifest(workflowId, runId) {
  const filePath = manifestPath(workflowId, runId);
  if (!fs.existsSync(filePath)) {
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_) {
    return null;
  }
}

function summarizeRuns(events) {
  const runs = new Map();
  for (const event of events) {
    const workflowId = event.workflowId;
    const runId = event.runId;
    if (!workflowId || !runId) {
      continue;
    }
    const key = `${workflowId}::${runId}`;
    if (!runs.has(key)) {
      runs.set(key, {
        workflowId,
        runId,
        last: null,
        steps: {},
      });
    }

    const run = runs.get(key);
    const timestamp = parseTimestamp(event.timestamp);
    if (timestamp !== null && (run.last === null || timestamp > run.last)) {
      run.last = timestamp;
    }

    const stepId = event.stepId || event.stepName || 'unknown';
    if (!run.steps[stepId]) {
      run.steps[stepId] = { status: 'pending' };
    }

    if (event.status === 'step_started') {
      run.steps[stepId].status = 'running';
    }
    if (event.status === 'step_finished') {
      run.steps[stepId] = {
        status: event.exitCode === 0 ? 'success' : 'failed',
        exitCode: event.exitCode,
        durationSec: event.durationSec,
        stdoutPath: event.stdoutPath,
        stderrPath: event.stderrPath,
      };
    }
  }

  const output = [];
  for (const run of runs.values()) {
    const steps = Object.values(run.steps);
    const doneCount = steps.filter((step) => step.status === 'success' || step.status === 'failed').length;
    const failed = steps.some((step) => step.status === 'failed');
    output.push({
      workflowId: run.workflowId,
      runId: run.runId,
      last: run.last ? new Date(run.last).toISOString() : null,
      progress: `${doneCount}/${steps.length}`,
      status: failed ? 'failed' : doneCount === steps.length ? 'success' : 'running',
    });
  }

  output.sort((a, b) => (b.last || '').localeCompare(a.last || ''));
  return output;
}

function buildRunDetails(events, workflowId, runId) {
  const steps = {};
  for (const event of events) {
    if (event.workflowId !== workflowId || event.runId !== runId) {
      continue;
    }
    const stepId = event.stepId || event.stepName || 'unknown';
    if (!steps[stepId]) {
      steps[stepId] = { stepId, status: 'pending' };
    }
    if (event.status === 'step_started') {
      steps[stepId].status = 'running';
    }
    if (event.status === 'step_finished') {
      steps[stepId].status = event.exitCode === 0 ? 'success' : 'failed';
      steps[stepId].exitCode = event.exitCode;
      steps[stepId].durationSec = event.durationSec;
      steps[stepId].stdoutPath = event.stdoutPath;
      steps[stepId].stderrPath = event.stderrPath;
    }
  }

  const manifest = readManifest(workflowId, runId);
  if (manifest && Array.isArray(manifest.steps)) {
    for (const manifestStep of manifest.steps) {
      const stepId = manifestStep.id;
      if (!stepId) {
        continue;
      }
      if (!steps[stepId]) {
        steps[stepId] = { stepId, status: 'pending' };
      }
      steps[stepId].name = manifestStep.name || stepId;
      steps[stepId].type = manifestStep.type || '';
      steps[stepId].dependsOn = manifestStep.dependsOn || [];
    }
  }

  return {
    workflowId,
    runId,
    steps: Object.values(steps),
  };
}

function buildDag(events, workflowId, runId) {
  const manifest = readManifest(workflowId, runId);
  if (!manifest || !Array.isArray(manifest.steps)) {
    return null;
  }

  const stepStatus = {};
  for (const event of events) {
    if (event.workflowId !== workflowId || event.runId !== runId) {
      continue;
    }
    const stepId = event.stepId || event.stepName || 'unknown';
    if (event.status === 'step_started') {
      stepStatus[stepId] = 'running';
    }
    if (event.status === 'step_finished') {
      stepStatus[stepId] = event.exitCode === 0 ? 'success' : 'failed';
    }
  }

  const nodes = [];
  const edges = [];
  for (const step of manifest.steps) {
    const id = step.id;
    if (!id) {
      continue;
    }
    nodes.push({
      id,
      name: step.name || id,
      type: step.type || '',
      status: stepStatus[id] || 'pending',
      dependsOn: step.dependsOn || [],
    });
    for (const dep of step.dependsOn || []) {
      edges.push({ from: dep, to: id });
    }
  }

  return {
    workflowId,
    runId,
    nodes,
    edges,
  };
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
      Connection: 'keep-alive',
    });
    res.write('retry: 1000\n\n');

    let position = 0;
    const sendEvent = (event) => {
      res.write(`data: ${JSON.stringify(event)}\n\n`);
    };

    const bootstrap = () => {
      const events = readEvents();
      for (const event of events) {
        if (!runId || event.runId === runId) {
          sendEvent(event);
        }
      }
      try {
        position = fs.statSync(eventsPath).size;
      } catch (_) {
        position = 0;
      }
    };

    const poll = () => {
      fs.stat(eventsPath, (error, stats) => {
        if (error || !stats) {
          return;
        }
        if (stats.size <= position) {
          return;
        }
        const stream = fs.createReadStream(eventsPath, { start: position, end: stats.size });
        let buffer = '';
        stream.on('data', (chunk) => {
          buffer += chunk.toString();
        });
        stream.on('end', () => {
          position = stats.size;
          const lines = buffer.split('\n');
          for (const line of lines) {
            if (!line.trim()) {
              continue;
            }
            try {
              const event = JSON.parse(line);
              if (!runId || event.runId === runId) {
                sendEvent(event);
              }
            } catch (_) {}
          }
        });
      });
    };

    bootstrap();
    const interval = setInterval(poll, 1000);
    req.on('close', () => clearInterval(interval));
    return;
  }

  if (parsed.pathname === '/api/runs') {
    return sendJson(res, summarizeRuns(readEvents()));
  }

  if (parsed.pathname.startsWith('/api/runs/')) {
    const runId = decodeURIComponent(parsed.pathname.replace('/api/runs/', ''));
    const events = readEvents();
    const runs = summarizeRuns(events);
    const run = runs.find((entry) => entry.runId === runId);
    if (!run) {
      return sendJson(res, { error: 'run not found' }, 404);
    }
    return sendJson(res, buildRunDetails(events, run.workflowId, run.runId));
  }

  if (parsed.pathname === '/api/dag') {
    const runId = parsed.query.runId;
    if (!runId) {
      return sendJson(res, { error: 'runId is required' }, 400);
    }
    const events = readEvents();
    const runs = summarizeRuns(events);
    const run = runs.find((entry) => entry.runId === runId);
    if (!run) {
      return sendJson(res, { error: 'run not found' }, 404);
    }
    const dag = buildDag(events, run.workflowId, run.runId);
    if (!dag) {
      return sendJson(res, { error: 'dag manifest not found' }, 404);
    }
    return sendJson(res, dag);
  }

  if (parsed.pathname.startsWith('/logs/')) {
    const rel = decodeURIComponent(parsed.pathname.replace('/logs/', '')).replace(/\.\./g, '');
    const filePath = path.join(logDir, rel);
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
