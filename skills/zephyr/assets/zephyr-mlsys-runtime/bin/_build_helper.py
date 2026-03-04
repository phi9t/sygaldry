#!/usr/bin/env python3
"""
Build helper for build-mlsys.sh.

Parses config.yaml, resolves Python dependencies (inline, requirements file,
or pyproject.toml), copies in-container scripts to the build context, and
generates a Dockerfile.

Usage (called by build-mlsys.sh, not directly):
    python3 _build_helper.py <config.yaml> <build_ctx_dir> <repo_root> <kit_root>

Prints KEY=VALUE lines to stdout for the bash caller to read.
All diagnostic output goes to stderr.
"""

import os
import re
import shutil
import sys
from datetime import datetime, timezone


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"  [_build_helper] {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Minimal YAML parser (stdlib only -- avoids PyYAML dependency on host)
# ---------------------------------------------------------------------------

def strip_comment(s: str) -> str:
    return re.sub(r"\s+#.*$", "", s).strip()


def strip_quotes(s: str) -> str:
    return re.sub(r'^["\']|["\']$', "", s.strip())


def parse_flow_seq(s: str) -> list[str] | None:
    """Parse YAML flow sequence like [a, b, c]."""
    s = s.strip()
    if s.startswith("[") and s.endswith("]"):
        return [strip_quotes(x.strip()) for x in s[1:-1].split(",") if x.strip()]
    return None


def parse_config(path: str) -> dict:
    """Parse a simple YAML config file into a dict."""
    with open(path) as f:
        lines = f.readlines()

    result: dict = {}
    current_section: str | None = None
    section_indent = 0
    i = 0

    while i < len(lines):
        raw = lines[i]
        i += 1
        stripped = raw.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        content = stripped.lstrip()

        if indent == 0:
            if ":" not in content:
                continue
            key, _, rest = content.partition(":")
            key = key.strip()
            rest = strip_comment(rest).strip()
            flow = parse_flow_seq(rest)
            if flow is not None:
                result[key] = flow
                current_section = None
            elif rest:
                result[key] = strip_quotes(rest)
                current_section = None
            else:
                result[key] = {}
                current_section = key
                section_indent = indent

        elif current_section is not None and indent > section_indent:
            sec = result[current_section]
            if content.startswith("- "):
                item = strip_quotes(strip_comment(content[2:]))
                if not isinstance(sec, list):
                    result[current_section] = []
                result[current_section].append(item)
            elif ":" in content:
                key, _, rest = content.partition(":")
                key = key.strip()
                rest = strip_comment(rest).strip()
                if not isinstance(sec, dict):
                    result[current_section] = {}
                flow = parse_flow_seq(rest)
                if flow is not None:
                    result[current_section][key] = flow
                elif rest:
                    result[current_section][key] = strip_quotes(rest)
                else:
                    # Look ahead for nested list items
                    inner: list[str] = []
                    inner_indent: int | None = None
                    while i < len(lines):
                        nraw = lines[i]
                        nst = nraw.rstrip()
                        if not nst or nst.lstrip().startswith("#"):
                            i += 1
                            continue
                        nind = len(nraw) - len(nraw.lstrip())
                        ncnt = nst.lstrip()
                        if inner_indent is None:
                            if not ncnt.startswith("- "):
                                break
                            inner_indent = nind
                        if nind >= inner_indent and ncnt.startswith("- "):
                            inner.append(strip_quotes(strip_comment(ncnt[2:])))
                            i += 1
                        else:
                            break
                    result[current_section][key] = inner if inner else None

    return result


# ---------------------------------------------------------------------------
# Dependency resolution
# ---------------------------------------------------------------------------

def resolve_packages(python_deps: dict | list | None, repo_root: str) -> list[str]:
    """Resolve Python packages from config python_deps section."""
    if not python_deps or not isinstance(python_deps, dict):
        return []

    packages: list[str] = []

    if python_deps.get("packages"):
        pkgs = python_deps["packages"]
        packages = pkgs if isinstance(pkgs, list) else [pkgs]

    elif python_deps.get("requirements"):
        req_path = os.path.join(repo_root, python_deps["requirements"])
        if not os.path.isfile(req_path):
            die(f"requirements file not found: {req_path}")
        with open(req_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and not line.startswith("-r "):
                    packages.append(line)

    elif python_deps.get("pyproject"):
        pyproject_path = os.path.join(repo_root, python_deps["pyproject"])
        if not os.path.isfile(pyproject_path):
            die(f"pyproject.toml not found: {pyproject_path}")
        extras = python_deps.get("extras") or []
        if isinstance(extras, str):
            extras = [extras]
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib  # type: ignore[no-redef]
            except ImportError:
                die("tomllib unavailable; requires Python 3.11+ or 'pip install tomli'")
        with open(pyproject_path, "rb") as f:
            pyproject = tomllib.load(f)
        project = pyproject.get("project", {})
        if extras:
            opt_deps = project.get("optional-dependencies", {})
            for extra in extras:
                if extra not in opt_deps:
                    die(f"extra '{extra}' not found in pyproject.toml optional-dependencies")
                packages.extend(opt_deps[extra])
        else:
            packages.extend(project.get("dependencies", []))

    return packages


# ---------------------------------------------------------------------------
# Dockerfile generation
# ---------------------------------------------------------------------------

def generate_dockerfile(
    base_image: str,
    apt_packages: list[str],
    packages: list[str],
    venv_path: str,
) -> str:
    """Generate Dockerfile content."""
    lines: list[str] = []

    lines.append("# Auto-generated by build-mlsys.sh -- do not edit")
    lines.append(f"FROM {base_image}")
    lines.append("")
    lines.append("ARG BUILT_AT=unknown")
    lines.append("ARG REPO_SOURCE_REV=unknown")
    lines.append("")
    lines.append('LABEL sygaldry.mlsys.repo_image="true"')
    lines.append('LABEL sygaldry.mlsys.built_at="${BUILT_AT}"')
    lines.append(f'LABEL sygaldry.mlsys.base_image_ref="{base_image}"')
    lines.append('LABEL sygaldry.mlsys.repo_source_rev="${REPO_SOURCE_REV}"')

    if apt_packages:
        lines.append("")
        lines.append("RUN apt-get update && apt-get install -y --no-install-recommends \\")
        for pkg in apt_packages:
            lines.append(f"    {pkg} \\")
        lines.append("    && rm -rf /var/lib/apt/lists/*")

    if packages:
        lines.append("")
        lines.append("# Python venv on top of Spack base -- uv-install.sh and constraint")
        lines.append("# files (spack_owned_packages.conf, nvidia_overrides.txt) are")
        lines.append("# baked into the base image at /opt/container_entrypoints/.")
        uv_line = f"RUN --mount=type=cache,target=/opt/uv_cache \\\n"
        uv_line += f"    VENV_DIR={venv_path} \\\n"
        uv_line += f"    UV_CACHE_DIR=/opt/uv_cache \\\n"
        uv_line += f"    /opt/container_entrypoints/uv-install.sh"
        for pkg in packages:
            uv_line += f" \\\n    {pkg}"
        lines.append(uv_line)

    # In-container scripts
    lines.append("")
    lines.append("COPY container/entrypoint.sh /opt/mlsys-entrypoint.sh")
    lines.append("COPY container/run-job.sh    /opt/mlsys-run-job.sh")
    lines.append("RUN chmod +x /opt/mlsys-entrypoint.sh /opt/mlsys-run-job.sh")

    if packages:
        lines.append("")
        lines.append(f"ENV VIRTUAL_ENV={venv_path}")
        lines.append(f"ENV PATH={venv_path}/bin:${{PATH}}")
        lines.append(f"ENV MLSYS_VENV_PATH={venv_path}")

    lines.append("")
    lines.append('LABEL sygaldry.mlsys.baked="true"')
    lines.append(f'LABEL sygaldry.mlsys.venv_path="{venv_path}"')
    lines.append("")
    lines.append('ENTRYPOINT ["/opt/mlsys-entrypoint.sh"]')
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if len(sys.argv) < 5:
        die("Usage: _build_helper.py <config.yaml> <build_ctx_dir> <repo_root> <kit_root>")

    config_file = sys.argv[1]
    build_ctx_dir = sys.argv[2]
    repo_root = sys.argv[3]
    kit_root = sys.argv[4]

    if not os.path.isfile(config_file):
        die(f"config not found: {config_file}")

    config = parse_config(config_file)

    # Validate required fields
    errors: list[str] = []
    if not config.get("base_image"):
        errors.append("base_image is required")
    if not config.get("image"):
        errors.append("image is required")
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    if errors:
        sys.exit(1)

    base_image = config["base_image"]
    output_image = config["image"]

    # Warn (not error) if base_image is not digest-pinned
    if "@sha256:" not in base_image:
        print(
            "WARNING: base_image is not digest-pinned (no @sha256: found). "
            "Builds may not be reproducible.",
            file=sys.stderr,
        )
    else:
        digest_part = base_image.split("@sha256:", 1)[-1]
        if not re.match(r"^[a-f0-9]{64}$", digest_part):
            print(
                f"WARNING: invalid sha256 digest in base_image: {digest_part!r}",
                file=sys.stderr,
            )

    # Resolve packages
    python_deps = config.get("python_deps") or {}
    packages = resolve_packages(python_deps, repo_root)

    apt_packages = config.get("apt_packages") or []
    if isinstance(apt_packages, str):
        apt_packages = [apt_packages]

    venv_path = config.get("venv_path") or "/opt/repo-venv"

    info(f"base_image:   {base_image}")
    info(f"output_image: {output_image}")
    info(f"venv_path:    {venv_path}")
    info(f"apt_packages: {apt_packages}")
    info(f"packages:     {packages}")

    # Copy in-container scripts to build context
    container_dir = os.path.join(build_ctx_dir, "container")
    os.makedirs(container_dir, exist_ok=True)

    # Look for container scripts in the kit's container/ directory
    kit_container_dir = os.path.join(kit_root, "container")
    for script_name in ("entrypoint.sh", "run-job.sh"):
        src = os.path.join(kit_container_dir, script_name)
        if not os.path.isfile(src):
            die(f"Missing in-container script: {src}")
        shutil.copy2(src, os.path.join(container_dir, script_name))

    # Generate Dockerfile
    dockerfile_content = generate_dockerfile(base_image, apt_packages, packages, venv_path)
    dockerfile_path = os.path.join(build_ctx_dir, "Dockerfile")
    with open(dockerfile_path, "w") as f:
        f.write(dockerfile_content)

    info("Generated Dockerfile:")
    for line in dockerfile_content.splitlines():
        print(f"  {line}", file=sys.stderr)

    # Print key=value output for bash caller
    print(f"IMAGE_NAME={output_image}")


if __name__ == "__main__":
    main()
