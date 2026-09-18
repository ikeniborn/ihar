"""Load the hook pattern list into the package, by path.

The secret patterns are the union of what both wrappers block, and they must be one
list: a gateway that masks fewer kinds than the hook blocks would be a hole exactly
where the two layers are supposed to agree.

They live in `hooks/_shared/patterns.py` because a hook runs under the system
interpreter with `python3 -I` and cannot import this package. Loading the hook's
module by path here is the direction that keeps one copy; copying the list into the
package would make two that have to be kept in step by hand.
"""

from __future__ import annotations

import importlib.util
import os
import sys


def _hooks_shared_dir() -> str:
    root = os.environ.get("IHAR_ROOT")
    if root:
        candidate = os.path.join(root, "hooks", "_shared")
        if os.path.isdir(candidate):
            return candidate
    # lib/python/ihar/mask/_shared.py -> the checkout is four levels up.
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "..", "..", "..", "hooks", "_shared"))


def load_patterns():
    directory = _hooks_shared_dir()
    path = os.path.join(directory, "patterns.py")
    if "ihar_hook_patterns" in sys.modules:
        return sys.modules["ihar_hook_patterns"]
    spec = importlib.util.spec_from_file_location("ihar_hook_patterns", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load the shared hook patterns from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["ihar_hook_patterns"] = module
    spec.loader.exec_module(module)
    return module


patterns = load_patterns()
SECRET_PATTERNS = patterns.SECRET_PATTERNS
