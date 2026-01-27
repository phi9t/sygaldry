# Tmux Command & Control Center - Technical Design

**Version:** 1.0  
**Status:** Draft  
**Author:** Engineering Team  
**Date:** 2026-02-15

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Design Philosophy](#design-philosophy)
3. [Architecture Overview](#architecture-overview)
4. [Core Data Structures](#core-data-structures)
5. [Configuration System](#configuration-system)
6. [Tool Registry](#tool-registry)
7. [Layout Engine](#layout-engine)
8. [Process Tracking & Auto-Filtering](#process-tracking--auto-filtering)
9. [Status Bar System](#status-bar-system)
10. [CLI Interface](#cli-interface)
11. [Event System](#event-system)
12. [File Organization](#file-organization)
13. [Extension Points](#extension-points)
14. [Implementation Phases](#implementation-phases)

---

## Executive Summary

This document describes a **tmux-based Command & Control Center** system that enables users to rapidly compose CLI tools and TUIs into cohesive monitoring dashboards. The system provides a declarative configuration interface while leveraging tmux as the underlying window management and persistence layer.

**Key Benefits:**
- **30-second setup** from concept to working dashboard
- **Declarative configuration** over imperative scripting
- **Composable architecture** - tools snap together like building blocks
- **Terminal-native** - leverages existing user knowledge
- **No web stack required** - pure terminal solution

---

## Design Philosophy

### Core Tenets

1. **Declarative over Imperative**: Users describe what they want, not how to build it
2. **Composition over Configuration**: Tools snap together like LEGO blocks
3. **Convention over Customization**: Sensible defaults, escape hatches when needed
4. **Terminal-Native**: Leverage what users already know (tmux, shell, CLI tools)

### The "30-Second Rule"

A user should be able to go from "I need to monitor X" to "I have a working dashboard" in under 30 seconds:

```bash
# Instead of:
# - Writing HTML/CSS/JS
# - Setting up a web server
# - Configuring WebSocket connections
# - Building custom widgets

# Just:
tmux-dashboard create --name qwen-training --from-template training --models 0.6b,1.7b,4b
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    User Interface Layer                      │
│  (tmux windows/panes + CLI commands + simple TUIs)          │
└─────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│                   Composition Layer                          │
│  (declarative configs, templates, layout presets)           │
└─────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│                    Tool Registry                             │
│  (TUI apps, CLI pipelines, custom scripts)                  │
└─────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│                    Data Sources                              │
│  (logs, metrics APIs, system stats, custom commands)        │
└─────────────────────────────────────────────────────────────┘
```

### Key Concepts

#### 1. The "Slot" Abstraction

Instead of managing tmux panes directly, users think in **slots** that can hold **tools**:

```yaml
# dashboard.yaml
name: training-control-center
layout: three-panel

slots:
  left-panel:
    tool: nvitop
    filter: "training"  # Process filter
    
  center-panel:
    tool: log-stream
    sources:
      - /data/outputs/qwen-0.6b/metrics.jsonl
      - /data/outputs/qwen-1.7b/metrics.jsonl
    format: jq '.step, .loss'
    
  right-panel:
    tool: system-status
    refresh: 5s
```

**Why this matters**: Users don't care about pane indices (`:0.1`). They care about semantic positions.

#### 2. Tool Registry

Pre-registered tools with sensible defaults:

```yaml
# ~/.config/tmux-dashboard/tools.yaml
tools:
  nvitop:
    command: nvitop
    category: gpu-monitor
    accepts_filter: true
    min_size: [80, 24]
    
  htop:
    command: htop
    category: system-monitor
    accepts_filter: true
    
  log-stream:
    command: "tail -f {source} | {format}"
    category: log-viewer
    accepts_multiple_sources: true
```

**Benefit**: New tools can be added without code changes.

#### 3. Layout Presets

Common patterns as named presets:

| Preset | Description | Use Case |
|--------|-------------|----------|
| `single` | One full-screen pane | Focus work |
| `split-h` | Two panes horizontal | Comparison |
| `three-panel` | 50/25/25 split | Dashboard |
| `quad` | 2x2 grid | Multi-task |
| `ide` | Editor + sidebar + terminal | Development |
| `monitoring` | Main + 3 stacked monitors | Ops view |

---

## Core Data Structures

### 4.1 Dashboard Configuration Schema

```yaml
# Schema definition (validated with JSON Schema or Python dataclasses)

dashboard:
  version: "1.0"
  name: string                    # Session name (required)
  description: string             # Human-readable (optional)
  
  layout:                         # Layout configuration
    preset: string               # single, split-h, split-v, three-panel, quad, ide, monitoring, custom
    custom:                      # Only if preset == "custom"
      type: tiled | even-vertical | even-horizontal | main-vertical | main-horizontal
      splits: []                 # Explicit split definitions
  
  slots:                          # Dictionary of slot_name -> slot_config
    <slot_name>:
      tool: string               # Reference to tool registry
      position: [x, y, w, h]     # Optional: explicit position
      config: {}                 # Tool-specific configuration
      
  status_bar:                     # Optional: custom status bar
    enabled: boolean
    left: [component_def]
    right: [component_def]
    
  hooks:                          # Optional: event handlers
    <event_name>:
      action: string
      config: {}
      
  key_bindings:                   # Optional: custom shortcuts
    <key>: action_def
```

### 4.2 Tool Registry Schema

```yaml
# ~/.config/tmux-dashboard/registry.yaml

tools:
  nvitop:
    name: "nvitop"
    category: "gpu-monitor"
    command: "nvitop"
    args: []                      # Default args
    env: {}                       # Environment variables
    accepts_filter: true
    filter_arg: "--filter"        # How to pass filter (if supported)
    interactive_filter: "\"       # Key to press for interactive filter
    min_size: [80, 24]           # Minimum viable size
    preferred_size: [120, 40]    # Optimal size
    
  log-stream:
    name: "Log Stream"
    category: "log-viewer"
    command_template: "tail -f {sources} | {processor}"
    config_schema:
      sources:
        type: array
        items: string            # File paths (glob supported)
      format:
        type: string             # jq expression or "raw"
      highlight_patterns:
        type: array
        items: string
    
  custom-script:
    name: "Custom Script"
    category: "custom"
    command_template: "{script_path} {args}"
    config_schema:
      script_path:
        type: string
        required: true
      args:
        type: array
        items: string
      working_dir:
        type: string
```

### 4.3 Layout Preset Definitions (Python)

```python
# Internal representation (Python dataclasses)

from dataclasses import dataclass
from typing import List, Dict, Optional, Tuple

@dataclass
class Split:
    direction: str  # 'h' or 'v'
    size: int       # Percentage or absolute cells
    size_type: str  # 'percent' or 'absolute'
    target: str     # Slot name or nested split

@dataclass  
class Layout:
    name: str
    description: str
    splits: List[Split]
    slot_order: List[str]  # Which slots get which pane numbers

# Predefined layouts
LAYOUTS = {
    "single": Layout(
        name="single",
        description="Single full-screen pane",
        splits=[],
        slot_order=["main"]
    ),
    
    "split-h": Layout(
        name="split-h",
        description="Two panes side by side",
        splits=[
            Split(direction='h', size=50, size_type='percent', target='left'),
            Split(direction='h', size=50, size_type='percent', target='right')
        ],
        slot_order=["left", "right"]
    ),
    
    "three-panel": Layout(
        name="three-panel",
        description="Main area with sidebar (50/25/25)",
        splits=[
            Split(direction='h', size=50, size_type='percent', target='main'),
            Split(direction='v', size=50, size_type='percent', target='sidebar-top'),
            Split(direction='v', size=50, size_type='percent', target='sidebar-bottom')
        ],
        slot_order=["main", "sidebar-top", "sidebar-bottom"]
    ),
    
    "quad": Layout(
        name="quad",
        description="2x2 grid",
        splits=[
            Split(direction='h', size=50, size_type='percent', 
                  target=[Split(direction='v', size=50, target='top-left'),
                          Split(direction='v', size=50, target='top-right')]),
            Split(direction='h', size=50, size_type='percent',
                  target=[Split(direction='v', size=50, target='bottom-left'),
                          Split(direction='v', size=50, target='bottom-right')])
        ],
        slot_order=["top-left", "top-right", "bottom-left", "bottom-right"]
    )
}
```

---

## Configuration System

### 5.1 Configuration Resolution

```python
def resolve_config(name: str, explicit_path: Optional[str] = None) -> DashboardConfig:
    """
    Resolution order (first found wins):
    1. Explicit path if provided
    2. ./.tmux-dashboard/<name>.yaml
    3. ~/.config/tmux-dashboard/dashboards/<name>.yaml  
    4. ~/.local/share/tmux-dashboard/templates/<name>.yaml
    5. System templates (/usr/share/tmux-dashboard/templates/<name>.yaml)
    """
    search_paths = [
        explicit_path,
        f".tmux-dashboard/{name}.yaml",
        f"~/.config/tmux-dashboard/dashboards/{name}.yaml",
        f"~/.local/share/tmux-dashboard/templates/{name}.yaml",
        f"/usr/share/tmux-dashboard/templates/{name}.yaml"
    ]
    
    for path in search_paths:
        if path and os.path.exists(os.path.expanduser(path)):
            return load_and_validate(path)
    
    raise ConfigNotFoundError(f"Dashboard '{name}' not found in search path")
```

### 5.2 Variable Substitution

```python
# Template variable resolution
VARIABLE_RESOLVERS = {
    # Built-in variables
    '${HOME}': lambda: os.path.expanduser('~'),
    '${USER}': lambda: os.environ.get('USER', 'unknown'),
    '${PWD}': lambda: os.getcwd(),
    '${DATE}': lambda: datetime.now().strftime('%Y-%m-%d'),
    '${TIME}': lambda: datetime.now().strftime('%H:%M:%S'),
    
    # Dynamic resolvers (registered at runtime)
    '${GPU_COUNT}': get_gpu_count,
    '${TRAINING_PIDS}': get_training_pids,
    '${LAST_CHECKPOINT}': get_last_checkpoint_step,
}

def substitute_variables(config_str: str, context: Dict = None) -> str:
    """Replace ${VAR} placeholders with actual values."""
    result = config_str
    context = context or {}
    
    # User-defined variables take precedence
    for key, value in context.items():
        result = result.replace(f'${{{key}}}', str(value))
    
    # Then built-in variables
    for pattern, resolver in VARIABLE_RESOLVERS.items():
        if pattern in result:
            result = result.replace(pattern, str(resolver()))
    
    return result
```

---

## Tool Registry

### 6.1 Tool Discovery

```python
class ToolRegistry:
    def __init__(self):
        self.tools: Dict[str, Tool] = {}
        self._load_builtin_tools()
        self._load_user_tools()
    
    def _load_builtin_tools(self):
        """Load tools from package resources."""
        builtin_path = pkg_resources.resource_filename('tmux_dashboard', 'tools')
        self._load_from_directory(builtin_path)
    
    def _load_user_tools(self):
        """Load user-defined tools."""
        user_path = os.path.expanduser('~/.config/tmux-dashboard/tools')
        if os.path.exists(user_path):
            self._load_from_directory(user_path)
    
    def _load_from_directory(self, path: str):
        """Load all .yaml files from directory."""
        for filename in os.listdir(path):
            if filename.endswith('.yaml'):
                with open(os.path.join(path, filename)) as f:
                    config = yaml.safe_load(f)
                    for tool_id, tool_config in config.get('tools', {}).items():
                        self.tools[tool_id] = Tool.from_config(tool_id, tool_config)
    
    def get_command(self, tool_id: str, slot_config: Dict) -> str:
        """Generate command string for tool with given config."""
        tool = self.tools.get(tool_id)
        if not tool:
            raise UnknownToolError(tool_id)
        
        if tool.command_template:
            return self._render_template(tool.command_template, slot_config)
        else:
            cmd = [tool.command] + tool.args
            if tool.accepts_filter and 'filter' in slot_config:
                cmd.extend([tool.filter_arg, slot_config['filter']])
            return ' '.join(cmd)
```

### 6.2 Tool Categories

```yaml
# Built-in tool definitions

tools:
  # GPU Monitors
  nvitop:
    category: gpu-monitor
    command: nvitop
    accepts_filter: true
    interactive_filter: "\\"
    min_size: [80, 24]
    
  nvtop:
    category: gpu-monitor
    command: nvtop
    min_size: [80, 24]
    
  # System Monitors
  htop:
    category: system-monitor
    command: htop
    accepts_filter: true
    filter_arg: "-F"
    min_size: [80, 24]
    
  btop:
    category: system-monitor
    command: btop
    min_size: [80, 24]
    
  # Log Viewers
  log-stream:
    category: log-viewer
    command_template: >
      {sources} | {processor}
    config_schema:
      sources:
        type: array
        default: []
      format:
        type: string
        default: "raw"
    pre_processors:
      sources: >
        sh -c 'tail -f {joined_sources}'
      joined_sources: >
        {sources} | join(' ')
      processor: >
        {format}
    
  # Container Tools
  docker-stats:
    category: container-monitor
    command: watch -n 2 docker stats
    
  lazydocker:
    category: container-monitor
    command: lazydocker
    
  # Custom
  custom:
    category: custom
    command_template: "{command}"
    config_schema:
      command:
        type: string
        required: true
```

---

## Layout Engine

### 7.1 Layout to Tmux Command Translation

```python
class LayoutEngine:
    def __init__(self, session_name: str):
        self.session = session_name
        self.commands = []
        self.pane_counter = 0
    
    def generate_tmux_commands(self, layout: Layout, slots: Dict[str, Slot]) -> List[str]:
        """Generate tmux commands to create layout."""
        self.commands = []
        self.pane_counter = 0
        
        # Create initial session
        self.commands.append(f'tmux new-session -d -s {self.session} -n main')
        
        # Apply layout
        self._apply_splits(layout.splits, target=f'{self.session}:main')
        
        # Send commands to each pane
        for slot_name, slot_config in slots.items():
            pane_idx = self._get_pane_index(slot_name, layout)
            tool_cmd = self.registry.get_command(slot_config.tool, slot_config.config)
            self.commands.append(
                f'tmux send-keys -t {self.session}:main.{pane_idx} "{tool_cmd}" Enter'
            )
        
        return self.commands
    
    def _apply_splits(self, splits: List[Split], target: str):
        """Recursively apply splits."""
        if not splits:
            return
        
        # Handle first split
        first = splits[0]
        size_flag = f'-p {first.size}' if first.size_type == 'percent' else f'-l {first.size}'
        
        if isinstance(first.target, str):
            # Leaf slot
            self.commands.append(
                f'tmux split-window -{first.direction} -t {target} {size_flag}'
            )
            self.pane_counter += 1
        else:
            # Nested split
            self.commands.append(
                f'tmux split-window -{first.direction} -t {target} {size_flag}'
            )
            self._apply_splits(first.target, f'{target}.{self.pane_counter}')
        
        # Handle remaining splits
        for split in splits[1:]:
            self._apply_splits([split], target)
    
    def execute(self):
        """Execute all commands."""
        for cmd in self.commands:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            if result.returncode != 0:
                logger.error(f"Command failed: {cmd}")
                logger.error(f"Error: {result.stderr}")
```

### 7.2 Handling Pane Numbering

```python
def calculate_pane_map(layout: Layout) -> Dict[str, int]:
    """
    Map slot names to tmux pane indices.
    
    tmux pane numbering is sequential within a window.
    Pane 0 is the initial pane.
    Each split creates a new pane with the next number.
    """
    pane_map = {}
    current_pane = 0
    
    for slot_name in layout.slot_order:
        pane_map[slot_name] = current_pane
        # After first slot, each subsequent slot needs a split
        if current_pane > 0:
            current_pane += 1
    
    return pane_map
```

---

## Process Tracking & Auto-Filtering

### 8.1 Process Monitor Architecture

```python
@dataclass
class TrackedProcess:
    pid: int
    cmdline: str
    start_time: datetime
    gpu_pids: List[int]  # Associated GPU processes
    session: str         # Which tmux session owns this process

class ProcessMonitor:
    def __init__(self):
        self.tracked: Dict[int, TrackedProcess] = {}
        self.callbacks: List[Callable] = []
        self.running = False
    
    def start(self):
        """Start monitoring in background thread."""
        self.running = True
        self.monitor_thread = threading.Thread(target=self._monitor_loop)
        self.monitor_thread.daemon = True
        self.monitor_thread.start()
    
    def _monitor_loop(self):
        """Main monitoring loop."""
        while self.running:
            self._discover_training_processes()
            self._update_gpu_associations()
            self._notify_callbacks()
            time.sleep(5)  # Check every 5 seconds
    
    def _discover_training_processes(self):
        """Find processes matching training patterns."""
        patterns = [
            r'torchrun',
            r'python.*train\.py',
            r'ray.*worker',
        ]
        
        current_pids = set()
        for proc in psutil.process_iter(['pid', 'cmdline', 'create_time']):
            try:
                cmdline = ' '.join(proc.info['cmdline'] or [])
                if any(re.search(p, cmdline) for p in patterns):
                    pid = proc.info['pid']
                    current_pids.add(pid)
                    
                    if pid not in self.tracked:
                        self.tracked[pid] = TrackedProcess(
                            pid=pid,
                            cmdline=cmdline,
                            start_time=datetime.fromtimestamp(proc.info['create_time']),
                            gpu_pids=[],
                            session=self._detect_session(pid)
                        )
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        
        # Remove dead processes
        for pid in list(self.tracked.keys()):
            if pid not in current_pids:
                del self.tracked[pid]
    
    def _detect_session(self, pid: int) -> Optional[str]:
        """Detect which tmux session a process belongs to."""
        try:
            proc = psutil.Process(pid)
            # Walk up process tree looking for tmux session
            while proc:
                if 'tmux' in proc.name():
                    # Extract session from tmux environment
                    env = proc.environ()
                    return env.get('TMUX_SESSION')
                proc = proc.parent()
        except:
            pass
        return None
    
    def get_pids_for_session(self, session: str) -> List[int]:
        """Get all tracked PIDs for a session."""
        return [tp.pid for tp in self.tracked.values() if tp.session == session]
```

### 8.2 Auto-Filter Implementation

```python
class AutoFilterManager:
    def __init__(self, monitor: ProcessMonitor):
        self.monitor = monitor
        self.filters: Dict[str, List[int]] = {}  # session -> pids
    
    def apply_filter(self, session: str, slot_name: str, tool: str):
        """Apply auto-filter to a specific slot."""
        pids = self.monitor.get_pids_for_session(session)
        
        if tool == 'nvitop':
            # nvitop uses interactive filtering
            # We need to send keys to the pane
            filter_expr = '|'.join(str(p) for p in pids)
            self._send_nvitop_filter(session, slot_name, filter_expr)
        
        elif tool == 'htop':
            # htop supports CLI filter
            filter_expr = '|'.join(str(p) for p in pids)
            # Restart htop with filter
            subprocess.run([
                'tmux', 'send-keys', '-t', f'{session}:{slot_name}',
                f'htop -F "{filter_expr}"', 'Enter'
            ])
    
    def _send_nvitop_filter(self, session: str, slot_name: str, filter_expr: str):
        """Send interactive filter to nvitop."""
        # Send \ to enter filter mode
        subprocess.run([
            'tmux', 'send-keys', '-t', f'{session}:{slot_name}',
            '\\\\',  # Escaped backslash
        ])
        time.sleep(0.1)
        # Type filter expression
        subprocess.run([
            'tmux', 'send-keys', '-t', f'{session}:{slot_name}',
            filter_expr, 'Enter'
        ])
```

---

## Status Bar System

### 9.1 Component Definitions

```python
@dataclass
class StatusComponent:
    name: str
    command: str
    interval: int  # Refresh interval in seconds
    format: str    # Output format

STATUS_COMPONENTS = {
    'gpu_utilization': StatusComponent(
        name='GPU Util',
        command='nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1',
        interval=5,
        format='GPU: {}%'
    ),
    
    'gpu_memory': StatusComponent(
        name='GPU Mem',
        command='nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | head -1 | awk -F", " \'{printf "%.1fGB/%.1fGB", $1/1024, $2/1024}\'',
        interval=5,
        format='{}'
    ),
    
    'training_jobs': StatusComponent(
        name='Jobs',
        command='ps aux | grep -E "torchrun|train.py" | grep -v grep | wc -l',
        interval=10,
        format='Jobs: {}'
    ),
    
    'last_checkpoint': StatusComponent(
        name='Checkpoint',
        command='find /data/outputs -name "*.pt" -mmin -60 | wc -l',
        interval=30,
        format='CKPT: {} new'
    ),
    
    'session_name': StatusComponent(
        name='Session',
        command='echo "#{session_name}"',
        interval=0,  # Static
        format='[{}]'
    ),
    
    'time': StatusComponent(
        name='Time',
        command='date +%H:%M',
        interval=1,
        format='{}'
    )
}
```

### 9.2 Tmux Status Bar Generation

```python
class StatusBarManager:
    def __init__(self, session: str):
        self.session = session
    
    def configure(self, left: List[str], right: List[str]):
        """Configure tmux status bar."""
        left_segments = []
        right_segments = []
        
        for component_id in left:
            component = STATUS_COMPONENTS[component_id]
            if component.interval > 0:
                # Dynamic component - use #() for periodic refresh
                left_segments.append(
                    f'#(every {component.interval}s {component.command})'
                )
            else:
                # Static component
                left_segments.append(component.format.format(component.command))
        
        for component_id in right:
            component = STATUS_COMPONENTS[component_id]
            if component.interval > 0:
                right_segments.append(
                    f'#(every {component.interval}s {component.command})'
                )
            else:
                right_segments.append(component.format.format(component.command))
        
        # Apply to tmux
        left_str = ' '.join(left_segments)
        right_str = ' '.join(right_segments)
        
        subprocess.run([
            'tmux', 'set-option', '-t', self.session,
            'status-left', left_str
        ])
        subprocess.run([
            'tmux', 'set-option', '-t', self.session,
            'status-right', right_str
        ])
        subprocess.run([
            'tmux', 'set-option', '-t', self.session,
            'status-interval', '1'
        ])
```

---

## CLI Interface

### 10.1 Command Structure

```bash
# Main command
tmux-dashboard

# Subcommands
tmux-dashboard create <name> [options]
tmux-dashboard attach <name>
tmux-dashboard kill <name>
tmux-dashboard list
tmux-dashboard edit <name>
tmux-dashboard validate <path>
tmux-dashboard template <action>

# Template subcommands
tmux-dashboard template list
tmux-dashboard template show <name>
tmux-dashboard template create <name> --from <dashboard>
```

### 10.2 Create Command Options

```python
@click.command()
@click.argument('name')
@click.option('--from-template', '-t', help='Base on template')
@click.option('--layout', '-l', help='Layout preset')
@click.option('--tool', '-T', multiple=True, help='Add tool to slot')
@click.option('--slot', '-s', multiple=True, help='Configure slot (name:tool)')
@click.option('--var', '-v', multiple=True, help='Template variables (key=value)')
@click.option('--dry-run', is_flag=True, help='Show commands without executing')
@click.option('--attach', '-a', is_flag=True, help='Attach after creation')
def create(name, from_template, layout, tool, slot, var, dry_run, attach):
    """Create a new dashboard session."""
    
    # Resolve variables
    context = {}
    for v in var:
        key, value = v.split('=')
        context[key] = value
    
    # Load configuration
    if from_template:
        config = template_manager.load(from_template, context)
    else:
        config = DashboardConfig(name=name)
        if layout:
            config.layout.preset = layout
    
    # Override with CLI options
    if slot:
        for s in slot:
            slot_name, tool_id = s.split(':')
            config.slots[slot_name] = Slot(tool=tool_id)
    
    # Validate
    validator = ConfigValidator()
    errors = validator.validate(config)
    if errors:
        for error in errors:
            click.echo(f"Error: {error}", err=True)
        sys.exit(1)
    
    # Generate and execute
    engine = DashboardEngine()
    commands = engine.generate_commands(config)
    
    if dry_run:
        for cmd in commands:
            click.echo(cmd)
    else:
        engine.execute(commands)
        
        if attach:
            subprocess.run(['tmux', 'attach', '-t', name])
```

---

## Event System

### 11.1 Event Types

```python
class EventType(Enum):
    # Training events
    TRAINING_STARTED = "training_started"
    TRAINING_COMPLETED = "training_completed"
    CHECKPOINT_SAVED = "checkpoint_saved"
    EVAL_COMPLETED = "eval_completed"
    
    # System events
    GPU_OOM = "gpu_oom"
    HIGH_GPU_UTIL = "high_gpu_util"
    PROCESS_DIED = "process_died"
    
    # User events
    SESSION_ATTACHED = "session_attached"
    SESSION_DETACHED = "session_detached"
    WINDOW_CHANGED = "window_changed"

@dataclass
class Event:
    type: EventType
    timestamp: datetime
    session: str
    data: Dict
    source: str  # Which component generated the event
```

### 11.2 Hook Execution

```python
class HookExecutor:
    def __init__(self):
        self.handlers: Dict[EventType, List[Callable]] = {}
    
    def register(self, event_type: EventType, handler: Callable):
        if event_type not in self.handlers:
            self.handlers[event_type] = []
        self.handlers[event_type].append(handler)
    
    def trigger(self, event: Event):
        """Execute all handlers for an event."""
        handlers = self.handlers.get(event.type, [])
        for handler in handlers:
            try:
                handler(event)
            except Exception as e:
                logger.error(f"Hook handler failed: {e}")
    
    def load_from_config(self, config: DashboardConfig):
        """Load hooks from dashboard configuration."""
        for event_name, hook_config in config.hooks.items():
            event_type = EventType(event_name)
            
            def create_handler(config):
                def handler(event):
                    self._execute_hook_action(config, event)
                return handler
            
            self.register(event_type, create_handler(hook_config))
    
    def _execute_hook_action(self, config: Dict, event: Event):
        """Execute a hook action."""
        action = config['action']
        
        if action == 'display_message':
            message = config['message'].format(**event.data)
            subprocess.run([
                'tmux', 'display-message',
                '-d', str(config.get('duration', 3000)),
                message
            ])
        
        elif action == 'create_window':
            window_name = config['window']['name']
            tool = config['window']['tool']
            # Create window and run tool
            pass
        
        elif action == 'switch_window':
            window = config['window']
            subprocess.run([
                'tmux', 'select-window',
                '-t', f'{event.session}:{window}'
            ])
        
        elif action == 'run_command':
            cmd = config['command']
            subprocess.run(cmd, shell=True)
```

---

## File Organization

```
~/.config/tmux-dashboard/
├── config.yaml              # Global settings
├── dashboards/              # User dashboards
│   ├── training.yaml
│   └── ray-cluster.yaml
├── templates/               # User templates
│   ├── my-template.yaml
│   └── team-standard.yaml
└── tools/                   # Custom tools
    └── my-script.yaml

~/.local/share/tmux-dashboard/
├── state/                   # Runtime state
│   ├── process-cache.json
│   └── session-index.json
└── logs/                    # Debug logs
    └── dashboard.log

/usr/share/tmux-dashboard/   # System-wide (optional)
├── templates/
│   ├── training.yaml
│   ├── ray-cluster.yaml
│   ├── docker-dev.yaml
│   └── system-ops.yaml
└── tools/
    └── builtin-tools.yaml
```

---

## Extension Points

### 13.1 Custom Tool Plugins

```python
# ~/.config/tmux-dashboard/plugins/my_plugin.py

from tmux_dashboard import ToolPlugin, register_tool

class MyCustomTool(ToolPlugin):
    name = "my-tool"
    category = "custom"
    
    def get_command(self, config: Dict) -> str:
        return f"python /path/to/my/script.py {config['arg1']}"
    
    def get_min_size(self) -> Tuple[int, int]:
        return (80, 24)
    
    def validate_config(self, config: Dict) -> List[str]:
        errors = []
        if 'arg1' not in config:
            errors.append("arg1 is required")
        return errors

register_tool(MyCustomTool())
```

### 13.2 Custom Layout Plugins

```python
class MyCustomLayout(LayoutPlugin):
    name = "my-layout"
    
    def generate_splits(self, slot_names: List[str]) -> List[Split]:
        # Custom layout logic
        return [
            Split(direction='h', size=30, target=slot_names[0]),
            Split(direction='v', size=50, target=[
                Split(direction='h', size=50, target=slot_names[1]),
                Split(direction='h', size=50, target=slot_names[2])
            ])
        ]
```

---

## Implementation Phases

### Phase 1: Core (Week 1-2)
- YAML parser for dashboard definitions
- Basic layout presets (single, split, quad)
- Tool registry with 5-10 built-in tools
- `tmux-dashboard create/attach/kill/list` commands

**Deliverables:**
- Working CLI with basic commands
- 5 layout presets
- 10 built-in tools
- Configuration validation

### Phase 2: Templates (Week 3)
- Template system with variable substitution
- 5 common templates (training, ray, docker, system, empty)
- Template repository (git-based sharing)

**Deliverables:**
- Template loader/resolver
- Variable substitution engine
- Template creation wizard
- 5 reference templates

### Phase 3: Smart Features (Week 4-6)
- Process tracking and auto-filtering
- Status bar aggregations
- Event hooks system
- Custom TUI tool integration

**Deliverables:**
- Process monitor daemon
- Auto-filter system for nvitop/htop
- Status bar component library
- Hook execution engine

### Phase 4: Polish (Ongoing)
- Interactive wizard mode
- Live reload of configs
- Dashboard sharing/import
- Performance optimizations

---

## Comparison: This vs Alternatives

| Approach | Setup Time | Flexibility | Maintenance | Skill Required |
|----------|-----------|-------------|-------------|----------------|
| **tmux-dashboard** | 30 sec | High | Low | Terminal basics |
| Custom web UI | 2-4 weeks | Very High | High | JS/React/DevOps |
| Grafana + Loki | 1-2 days | Medium | Medium | Prometheus/Grafana |
| Jupyter Dashboard | 1 day | Medium | Low | Python/widgets |
| Tmuxinator | 5 min | Medium | Low | YAML/tmux |

**Sweet spot**: Teams that know tmux, want something now, but need more than manual pane management.

---

## Open Questions

1. **Multi-Session Coordination**: How should multiple related sessions (overview + details) be coordinated?
2. **State Persistence**: Should dashboard state persist across tmux server restarts?
3. **Remote Dashboards**: How to support dashboards for remote hosts (SSH + tmux forwarding)?
4. **Plugin Security**: How to safely load user plugins without code injection risks?

---

## References

- [Tmux Manual](https://man7.org/linux/man-pages/man1/tmux.1.html)
- [nvitop Documentation](https://github.com/XuehaiPan/nvitop)
- [Click Framework](https://click.palletsprojects.com/) (for CLI)
- [Textual](https://textual.textualize.io/) (for future custom TUI)

---

*Document Version: 1.0*  
*Last Updated: 2026-02-15*
