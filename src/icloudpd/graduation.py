"""
Files moved out of the download folder on purpose ("graduated").

icloudpd keeps no record of what it has downloaded: a file counts as downloaded
while a file of that name (and, under name-size-dedup-with-suffix, that size)
is still in the download folder. Anyone who moves files out to a long-term
archive therefore gets them all downloaded again on the next run, for as long
as the asset is still in the window icloudpd looks at.

A ledger lets them. Whatever moves a file out writes one line for it first:

    <path relative to the ledger's folder> TAB <size in bytes> [TAB anything]

in a file named ``.graduated`` in the folder the path is relative to, under a
first line that is exactly ``LEDGER_HEADER``. icloudpd then treats a path in
the ledger exactly as if the file were still there with that size, so every
decision it makes, including the ``-<size>`` suffix given to a second asset
of the same name, comes out as it would have had the file never moved.

The ledger is looked for in the folder of each file and in each folder above
it, up to the download directory; the first one found holds that file. With
one ledger per library root, ``<library>/.graduated`` holds lines like
``2026/09/27/IMG_0001.HEIC``.

WHY A BAD LEDGER STOPS THE RUN

A ledger that cannot be read is not the same as an empty one. Treating it as
empty would download again every graduated file still in the window, and a
photo already reviewed and thrown away in the archive would come back as new.
So a ledger that exists but cannot be parsed raises ``LedgerError``, which
ends the run; nothing is downloaded until it is repaired.

WHY THE LEDGER IS RE-READ WHEN IT CHANGES

A file can be moved while a run is in progress. The mover writes the ledger
line before it moves the file, and the check here looks for the file before
it looks at the ledger, so a file found missing always has its line on disk.
The parsed ledger is kept only while the ledger file's size and modification
time are unchanged, so that line is always seen.

PHOTOS DELETED ON THE PHONE

``--auto-delete`` removes the local copy of anything in Recently Deleted. For a
graduated file there is no local copy; the one that matters is in the archive,
which icloudpd knows nothing about. So the deletion is written down instead,
in ``.deleted-on-phone`` next to the ledger, once per path and size, for
whatever manages the archive to act on. Nothing in the archive is touched
from here.
"""

import datetime
import logging
import os
from typing import Dict, List, Set, Tuple

LEDGER_NAME = ".graduated"
LEDGER_HEADER = "# icloudpd graduation ledger v1"
DELETIONS_NAME = ".deleted-on-phone"
DELETIONS_HEADER = "# icloudpd phone deletions v1"


class LedgerError(Exception):
    """A ledger exists but cannot be trusted; the run must not go on."""


def _relative(line_number: int, ledger_path: str, text: str) -> str:
    if text == "" or text.startswith("/") or "\\" in text:
        raise LedgerError(f"{ledger_path}:{line_number}: path must be relative: {text!r}")
    parts = text.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise LedgerError(f"{ledger_path}:{line_number}: path is not canonical: {text!r}")
    return text


def parse_ledger(ledger_path: str, content: str) -> Dict[str, int]:
    """Path -> size for every line of a ledger, or LedgerError."""
    if not content.endswith("\n"):
        # A last line without its newline is a write that did not finish.
        raise LedgerError(f"{ledger_path}: last line is incomplete")
    lines = content[:-1].split("\n")
    if lines[0] != LEDGER_HEADER:
        raise LedgerError(f"{ledger_path}: first line is not {LEDGER_HEADER!r}")
    entries: Dict[str, int] = {}
    for number, line in enumerate(lines[1:], start=2):
        if line == "" or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 2:
            raise LedgerError(f"{ledger_path}:{number}: expected <path> TAB <size>")
        path = _relative(number, ledger_path, fields[0])
        if not fields[1].isdigit():
            raise LedgerError(f"{ledger_path}:{number}: size is not a number: {fields[1]!r}")
        entries[path] = int(fields[1])
    return entries


class _Ledger:
    def __init__(self, folder: str) -> None:
        self.folder = folder
        self.path = os.path.join(folder, LEDGER_NAME)
        self._stamp: Tuple[int, int] | None = None
        self._entries: Dict[str, int] = {}
        self._reported: Set[Tuple[str, int]] | None = None

    def entries(self) -> Dict[str, int]:
        try:
            info = os.stat(self.path)
        except OSError as error:
            raise LedgerError(f"{self.path}: {error}") from error
        stamp = (info.st_size, info.st_mtime_ns)
        if stamp != self._stamp:
            try:
                with open(self.path, encoding="utf-8", newline="\n") as ledger:
                    content = ledger.read()
            except (OSError, UnicodeDecodeError) as error:
                raise LedgerError(f"{self.path}: {error}") from error
            self._entries = parse_ledger(self.path, content)
            self._stamp = stamp
        return self._entries

    def _deletions_path(self) -> str:
        return os.path.join(self.folder, DELETIONS_NAME)

    def _load_reported(self) -> Set[Tuple[str, int]]:
        reported: Set[Tuple[str, int]] = set()
        try:
            with open(self._deletions_path(), encoding="utf-8", newline="\n") as deletions:
                for line in deletions:
                    fields = line.rstrip("\n").split("\t")
                    if len(fields) >= 2 and fields[1].isdigit():
                        reported.add((fields[0], int(fields[1])))
        except FileNotFoundError:
            pass
        except (OSError, UnicodeDecodeError) as error:
            raise LedgerError(f"{self._deletions_path()}: {error}") from error
        return reported

    def report_deletion(self, relative: str, size: int, when: datetime.datetime) -> bool:
        """Write the deletion down once; True when this call wrote it."""
        if self._reported is None:
            self._reported = self._load_reported()
        if (relative, size) in self._reported:
            return False
        target = self._deletions_path()
        fresh = not os.path.exists(target)
        line = f"{relative}\t{size}\t{when.isoformat(timespec='seconds')}\n"
        try:
            with open(target, "a", encoding="utf-8", newline="\n") as deletions:
                deletions.write((DELETIONS_HEADER + "\n" if fresh else "") + line)
                deletions.flush()
                os.fsync(deletions.fileno())
        except OSError as error:
            raise LedgerError(f"{target}: {error}") from error
        self._reported.add((relative, size))
        return True


class Graduation:
    """The ledgers under one download directory."""

    def __init__(self, directory: str) -> None:
        self.directory = os.path.normpath(directory)
        self._ledgers: Dict[str, _Ledger] = {}

    def _holder(self, path: str) -> Tuple[_Ledger, str] | None:
        """The ledger that would hold path, and path relative to it."""
        path = os.path.normpath(path)
        folder = os.path.dirname(path)
        inside = os.path.relpath(folder, self.directory)
        if inside == ".." or inside.startswith(".." + os.sep) or os.path.isabs(inside):
            return None
        while True:
            if os.path.lexists(os.path.join(folder, LEDGER_NAME)):
                ledger = self._ledgers.get(folder)
                if ledger is None:
                    ledger = self._ledgers[folder] = _Ledger(folder)
                return ledger, os.path.relpath(path, folder).replace(os.sep, "/")
            if folder == self.directory:
                return None
            folder = os.path.dirname(folder)

    def graduated_size(self, path: str) -> int | None:
        """Size the file at path had when it graduated, or None."""
        holder = self._holder(path)
        if holder is None:
            return None
        ledger, relative = holder
        return ledger.entries().get(relative)

    def exists(self, path: str) -> bool:
        """Whether a file is at path, or was until it graduated."""
        # The file is looked for first: see "why the ledger is re-read".
        return os.path.isfile(path) or self.graduated_size(path) is not None

    def size(self, path: str) -> int:
        """Size of the file at path, or of the one that graduated from there."""
        try:
            return os.stat(path).st_size
        except FileNotFoundError:
            size = self.graduated_size(path)
            if size is None:
                raise
            return size

    def report_deletion(
        self, logger: logging.Logger, path: str, sizes: List[int], dry_run: bool
    ) -> bool:
        """For a path gone from the folder: note it if it graduated at one of sizes."""
        holder = self._holder(path)
        if holder is None:
            return False
        ledger, relative = holder
        size = ledger.entries().get(relative)
        # The size must match as well as the name: a second photo of the same
        # name, graduated under the plain name, is not the one deleted here.
        if size is None or size not in sizes:
            return False
        if dry_run:
            logger.info(
                "[DRY RUN] Would note the archived copy of %s as deleted on the phone", path
            )
            return True
        if ledger.report_deletion(relative, size, datetime.datetime.now(datetime.timezone.utc)):
            logger.info("Noted the archived copy of %s as deleted on the phone", path)
        return True


_graduations: Dict[str, Graduation] = {}


def for_directory(directory: str) -> Graduation:
    key = os.path.normpath(directory)
    graduation = _graduations.get(key)
    if graduation is None:
        graduation = _graduations[key] = Graduation(key)
    return graduation
