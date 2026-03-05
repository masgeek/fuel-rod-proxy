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

import sys

import questionary as _q
from rich.console import Console

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
