"""
Drop-in questionary wrapper that aborts the entire process on Ctrl+C.

questionary.ask() returns None when the user presses Ctrl+C (it catches
KeyboardInterrupt internally). Without this wrapper, callers that do
  `result = question.ask() or default`
silently continue with the default — Ctrl+C has no effect.

Usage: replace `import questionary` with `from . import prompt as questionary`
in any module that uses questionary prompts. All call sites stay unchanged.
"""

from __future__ import annotations

import concurrent.futures
import sys
import time

import questionary as _q
from rich.console import Console
from rich.text import Text

_console = Console()


class _GuardedQuestion:
    """Wraps a questionary Question so .ask() aborts on None (Ctrl+C)."""

    def __init__(self, question: _q.Question) -> None:
        self._q = question

    def ask(self, **kwargs):
        result = self._q.ask(**kwargs)
        if result is None:
            _console.print("\n[yellow]Aborted.[/]")
            sys.exit(0)
        return result


# Re-export every questionary factory with the guard applied

def text(*args, **kwargs) -> _GuardedQuestion:
    return _GuardedQuestion(_q.text(*args, **kwargs))

def password(*args, **kwargs) -> _GuardedQuestion:
    return _GuardedQuestion(_q.password(*args, **kwargs))

def confirm(*args, **kwargs) -> _GuardedQuestion:
    return _GuardedQuestion(_q.confirm(*args, **kwargs))

def select(*args, **kwargs) -> _GuardedQuestion:
    return _GuardedQuestion(_q.select(*args, **kwargs))

def checkbox(*args, **kwargs) -> _GuardedQuestion:
    return _GuardedQuestion(_q.checkbox(*args, **kwargs))

# Re-export Choice so callers can still do `prompt.Choice(...)`
Choice = _q.Choice


def check_connection_with_countdown(check_fn, timeout: int) -> None:
    """
    Run *check_fn* in a background thread while displaying a live countdown.

    Raises the original exception if check_fn fails.
    Raises TimeoutError if *timeout* seconds elapse with no result.
    """
    from rich.live import Live

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(check_fn)
        with Live(console=_console, refresh_per_second=4) as live:
            elapsed = 0
            while elapsed < timeout:
                remaining = timeout - elapsed
                live.update(
                    Text(
                        f"  Testing connection...  \u23f1  {remaining}s remaining",
                        style="cyan",
                    )
                )
                try:
                    future.result(timeout=1)
                    live.update(Text(""))
                    return  # success
                except concurrent.futures.TimeoutError:
                    elapsed += 1
                except Exception:
                    live.update(Text(""))
                    raise  # propagate real connection errors

        raise TimeoutError(
            f"Connection timed out after {timeout}s. "
            "Check host/port or increase CONNECTION_TIMEOUT in .backup."
        )
