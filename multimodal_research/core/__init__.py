"""Core implementations of foundational multimodal model papers.

This package uses numeric module filenames (e.g. ``01_vqvae.py``) to preserve
paper ordering in the curriculum. Importing these modules eagerly would force
heavy dependencies (for example ``torch``) during package import, so symbols are
loaded lazily via ``__getattr__``.
"""

from __future__ import annotations

import importlib
from typing import Any

__version__ = "0.1.0"

_SYMBOL_TO_MODULE = {
    # 01_vqvae.py
    "VectorQuantizer": "01_vqvae",
    "Encoder": "01_vqvae",
    "Decoder": "01_vqvae",
    "VQVAE": "01_vqvae",
    # 02_siglip.py
    "SigLIPLoss": "02_siglip",
    "ImageEncoder": "02_siglip",
    "TextEncoder": "02_siglip",
    "SigLIPModel": "02_siglip",
    # 03_dit.py
    "DiT": "03_dit",
    "DiT_configs": "03_dit",
    # 04_flow_matching.py
    "ConditionalFlowMatcher": "04_flow_matching",
    "VectorFieldNetwork": "04_flow_matching",
    "ODESampler": "04_flow_matching",
}

__all__ = sorted(_SYMBOL_TO_MODULE)


def __getattr__(name: str) -> Any:
    module_name = _SYMBOL_TO_MODULE.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

    module = importlib.import_module(f"{__name__}.{module_name}")
    value = getattr(module, name)
    globals()[name] = value
    return value


def __dir__() -> list[str]:
    return sorted(set(globals()) | set(__all__))
