import importlib.metadata as md
import os
import re

spack_owned = set()
conf_path = "__CONF_PATH__"
if conf_path and os.path.isfile(conf_path):
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                spack_owned.add(line.lower())
for dist in sorted(
    md.distributions(), key=lambda d: (d.metadata.get("Name", "").lower(), d.version)
):
    name = dist.metadata.get("Name")
    if name and name.lower() in spack_owned:
        version = re.sub(r"\+.*$", "", dist.version)
        print(f"{name}=={version}")
