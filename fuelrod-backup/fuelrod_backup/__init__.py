"""fuelrod-backup: Interactive PostgreSQL backup and restore CLI."""

from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("fuelrod-backup")
except PackageNotFoundError:
    __version__ = "0.1.0"
