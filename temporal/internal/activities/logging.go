package activities

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var maxLogBytes = func() int64 {
	const defaultMaxBytes = int64(10_000)
	v := os.Getenv("TEMPORAL_LOG_MAX_BYTES")
	if v == "" {
		return defaultMaxBytes
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n <= 0 {
		slog.Warn("TEMPORAL_LOG_MAX_BYTES invalid, using default",
			"value", v, "default", defaultMaxBytes)
		return defaultMaxBytes
	}
	return n
}()

type structuredLogLine struct {
	Timestamp  string `json:"timestamp"`
	WorkflowID string `json:"workflowId"`
	RunID      string `json:"runId"`
	StepID     string `json:"stepId"`
	StepName   string `json:"stepName"`
	Stream     string `json:"stream"`
	Message    string `json:"message"`
	Partial    bool   `json:"partial"`
}

type structuredLogSink struct {
	file       *os.File
	workflowID string
	runID      string
	stepID     string
	stepName   string
	mu         sync.Mutex
}

func (s *structuredLogSink) write(stream, message string, partial bool) {
	if s == nil || s.file == nil {
		return
	}
	line := structuredLogLine{
		Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID: s.workflowID,
		RunID:      s.runID,
		StepID:     s.stepID,
		StepName:   s.stepName,
		Stream:     stream,
		Message:    message,
		Partial:    partial,
	}
	data, err := json.Marshal(line)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.file.Write(append(data, '\n'))
}

type lineBufferWriter struct {
	sink   *structuredLogSink
	stream string
	buf    bytes.Buffer
}

func (w *lineBufferWriter) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 {
		idx := bytes.IndexByte(p, '\n')
		if idx < 0 {
			_, _ = w.buf.Write(p)
			return n, nil
		}
		_, _ = w.buf.Write(p[:idx])
		line := strings.TrimSuffix(w.buf.String(), "\r")
		w.buf.Reset()
		w.sink.write(w.stream, line, false)
		p = p[idx+1:]
	}
	return n, nil
}

func (w *lineBufferWriter) FlushPartial() {
	if w.buf.Len() == 0 {
		return
	}
	line := strings.TrimSuffix(w.buf.String(), "\r")
	w.buf.Reset()
	w.sink.write(w.stream, line, true)
}

type logWriters struct {
	logDir                 string
	stdoutWriter           io.Writer
	stderrWriter           io.Writer
	stdoutPath             string
	stderrPath             string
	structuredPath         string
	stdoutStructuredWriter *lineBufferWriter
	stderrStructuredWriter *lineBufferWriter
	closers                []io.Closer
}

func (lw *logWriters) Close() {
	for _, c := range lw.closers {
		c.Close()
	}
}

func (lw *logWriters) FlushPartial() {
	if lw.stdoutStructuredWriter != nil {
		lw.stdoutStructuredWriter.FlushPartial()
	}
	if lw.stderrStructuredWriter != nil {
		lw.stderrStructuredWriter.FlushPartial()
	}
}

func setupLogWriters(stdout, stderr *bytes.Buffer, logDirHint, workflowID, runID, stepID, name string) *logWriters {
	lw := &logWriters{
		stdoutWriter: stdout,
		stderrWriter: stderr,
	}

	logDir := strings.TrimSpace(logDirHint)
	if logDir == "" {
		logDir = os.Getenv("TEMPORAL_LOG_DIR")
	}
	if logDir == "" {
		logDir = "./logs"
	}
	if !filepath.IsAbs(logDir) {
		if cwd, cwdErr := os.Getwd(); cwdErr == nil {
			logDir = filepath.Join(cwd, logDir)
		}
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		logDir = "/tmp/temporal-logs"
		_ = os.MkdirAll(logDir, 0o755)
	}
	lw.logDir = logDir

	prefix := safeName(workflowID)
	if runID != "" {
		prefix += "_" + safeName(runID)
	}
	if stepID != "" {
		prefix += "_" + safeName(stepID)
	} else if name != "" {
		prefix += "_" + safeName(name)
	}
	if prefix == "" {
		prefix = "step"
	}

	lw.stdoutPath = filepath.Join(logDir, prefix+"_stdout.log")
	lw.stderrPath = filepath.Join(logDir, prefix+"_stderr.log")

	if file, err := os.Create(lw.stdoutPath); err == nil {
		lw.closers = append(lw.closers, file)
		lw.stdoutWriter = io.MultiWriter(lw.stdoutWriter, file)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (stdout): %v\n", err))
	}
	if file, err := os.Create(lw.stderrPath); err == nil {
		lw.closers = append(lw.closers, file)
		lw.stderrWriter = io.MultiWriter(lw.stderrWriter, file)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (stderr): %v\n", err))
	}

	structuredCandidate := filepath.Join(logDir, prefix+"_structured.jsonl")
	if file, err := os.Create(structuredCandidate); err == nil {
		lw.closers = append(lw.closers, file)
		lw.structuredPath = structuredCandidate
		sink := &structuredLogSink{
			file:       file,
			workflowID: workflowID,
			runID:      runID,
			stepID:     stepID,
			stepName:   name,
		}
		lw.stdoutStructuredWriter = &lineBufferWriter{sink: sink, stream: "stdout"}
		lw.stderrStructuredWriter = &lineBufferWriter{sink: sink, stream: "stderr"}
		lw.stdoutWriter = io.MultiWriter(lw.stdoutWriter, lw.stdoutStructuredWriter)
		lw.stderrWriter = io.MultiWriter(lw.stderrWriter, lw.stderrStructuredWriter)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (structured): %v\n", err))
	}

	return lw
}
