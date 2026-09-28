"""A file moved out of the download folder and written in the ledger counts as downloaded."""

import inspect
import logging
import os
import shutil
from typing import Any
from unittest import TestCase, mock

import pytest
from requests import Response

from icloudpd import graduation
from pyicloud_ipd.services.photos import PhotoAsset
from tests.helpers import (
    path_from_project_root,
    recreate_path,
    run_cassette,
)

LISTING = [
    "--username",
    "jdoe@gmail.com",
    "--password",
    "password1",
    "--recent",
    "1",
    "--no-progress-bar",
    "--threads-num",
    "1",
]


def write_ledger(folder: str, *lines: str) -> str:
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, graduation.LEDGER_NAME)
    with open(path, "w", encoding="utf-8", newline="\n") as ledger:
        ledger.write(graduation.LEDGER_HEADER + "\n")
        for line in lines:
            ledger.write(line + "\n")
    return path


class LedgerParsingTestCase(TestCase):
    def test_reads_paths_and_sizes(self) -> None:
        content = (
            graduation.LEDGER_HEADER
            + "\n2018/07/31/IMG_7409.JPG\t1884695\tmoved\t/archive/x\n"
            + "# a note\n\n"
            + "2018/07/31/IMG_7409.MOV\t3294075\n"
        )
        self.assertEqual(
            graduation.parse_ledger("l", content),
            {"2018/07/31/IMG_7409.JPG": 1884695, "2018/07/31/IMG_7409.MOV": 3294075},
        )

    def test_an_empty_ledger_holds_nothing(self) -> None:
        self.assertEqual(graduation.parse_ledger("l", graduation.LEDGER_HEADER + "\n"), {})

    def test_refuses_what_it_cannot_trust(self) -> None:
        header = graduation.LEDGER_HEADER + "\n"
        for content, why in [
            ("", "incomplete"),
            ("# something else\n", "first line"),
            # The ledger is LF only; one saved with CRLF is refused, not guessed at.
            (graduation.LEDGER_HEADER + "\r\n", "first line"),
            (header + "2018/07/31/IMG_7409.JPG\t1884695\r\n", "not a number"),
            (header + "2018/07/31/IMG_7409.JPG\t1884695", "incomplete"),
            (header + "2018/07/31/IMG_7409.JPG\n", "expected"),
            (header + "2018/07/31/IMG_7409.JPG\tbig\n", "not a number"),
            (header + "2018/07/31/IMG_7409.JPG\t-1\n", "not a number"),
            (header + "/2018/07/31/IMG_7409.JPG\t1\n", "relative"),
            (header + "2018/../31/IMG_7409.JPG\t1\n", "canonical"),
            (header + "2018//31/IMG_7409.JPG\t1\n", "canonical"),
            (header + "./IMG_7409.JPG\t1\n", "canonical"),
        ]:
            with (
                self.subTest(content=content),
                self.assertRaisesRegex(graduation.LedgerError, why),
            ):
                graduation.parse_ledger("l", content)


class GraduationTestCase(TestCase):
    @pytest.fixture(autouse=True)
    def inject_fixtures(self, tmp_path: Any) -> None:
        self.top = str(tmp_path)
        self.library = os.path.join(self.top, "PrimarySync")
        self.day = os.path.join(self.library, "2026", "09", "27")
        os.makedirs(self.day)

    def test_a_graduated_file_counts_with_its_size(self) -> None:
        write_ledger(self.library, "2026/09/27/IMG_0001.HEIC\t1200")
        graduated = graduation.Graduation(self.top)
        path = os.path.join(self.day, "IMG_0001.HEIC")
        self.assertTrue(graduated.exists(path))
        self.assertEqual(graduated.size(path), 1200)
        self.assertFalse(graduated.exists(os.path.join(self.day, "IMG_0002.HEIC")))

    def test_a_file_on_disk_wins(self) -> None:
        write_ledger(self.library, "2026/09/27/IMG_0001.HEIC\t1200")
        path = os.path.join(self.day, "IMG_0001.HEIC")
        with open(path, "wb") as f:
            f.write(b"abc")
        self.assertEqual(graduation.Graduation(self.top).size(path), 3)

    def test_no_ledger_is_the_old_behaviour(self) -> None:
        graduated = graduation.Graduation(self.top)
        path = os.path.join(self.day, "IMG_0001.HEIC")
        self.assertFalse(graduated.exists(path))
        with self.assertRaises(FileNotFoundError):
            graduated.size(path)

    def test_the_nearest_ledger_holds_the_file(self) -> None:
        write_ledger(self.top, "PrimarySync/2026/09/27/IMG_0001.HEIC\t1")
        write_ledger(self.library, "2026/09/27/IMG_0001.HEIC\t2")
        path = os.path.join(self.day, "IMG_0001.HEIC")
        self.assertEqual(graduation.Graduation(self.top).size(path), 2)

    def test_a_ledger_outside_the_download_directory_is_ignored(self) -> None:
        write_ledger(os.path.dirname(self.top), os.path.basename(self.top) + "/x.JPG\t1")
        self.assertFalse(graduation.Graduation(self.top).exists(os.path.join(self.top, "x.JPG")))
        self.assertFalse(graduation.Graduation(self.library).exists(os.path.join(self.top, "y")))

    def test_a_line_added_during_the_run_is_seen(self) -> None:
        ledger = write_ledger(self.library)
        graduated = graduation.Graduation(self.top)
        path = os.path.join(self.day, "IMG_0001.HEIC")
        self.assertFalse(graduated.exists(path))
        with open(ledger, "a", encoding="utf-8", newline="\n") as f:
            f.write("2026/09/27/IMG_0001.HEIC\t1200\n")
        self.assertTrue(graduated.exists(path))

    def test_an_unreadable_ledger_stops_everything(self) -> None:
        with open(os.path.join(self.library, graduation.LEDGER_NAME), "w") as f:
            f.write("not a ledger\n")
        graduated = graduation.Graduation(self.top)
        with self.assertRaises(graduation.LedgerError):
            graduated.exists(os.path.join(self.day, "IMG_0001.HEIC"))
        # A file still on disk is answered from the disk alone.
        on_disk = os.path.join(self.day, "IMG_0002.HEIC")
        open(on_disk, "w").close()
        self.assertTrue(graduated.exists(on_disk))

    def test_a_ledger_that_is_a_folder_stops_everything(self) -> None:
        os.makedirs(os.path.join(self.library, graduation.LEDGER_NAME))
        with self.assertRaises(graduation.LedgerError):
            graduation.Graduation(self.top).exists(os.path.join(self.day, "IMG_0001.HEIC"))

    def test_a_phone_deletion_is_noted_once_and_only_at_the_right_size(self) -> None:
        write_ledger(self.library, "2026/09/27/IMG_0001.HEIC\t1200")
        logger = logging.getLogger("test")
        path = os.path.join(self.day, "IMG_0001.HEIC")
        graduated = graduation.Graduation(self.top)
        self.assertFalse(graduated.report_deletion(logger, path, [999], False))
        self.assertFalse(
            os.path.exists(os.path.join(self.library, graduation.DELETIONS_NAME)),
            "a photo of the same name but another size is someone else's",
        )
        self.assertTrue(graduated.report_deletion(logger, path, [1200], False))
        self.assertTrue(
            graduation.Graduation(self.top).report_deletion(logger, path, [1200], False)
        )
        with open(os.path.join(self.library, graduation.DELETIONS_NAME), encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], graduation.DELETIONS_HEADER)
        self.assertEqual(len(lines), 2, "a later run does not write it again")
        self.assertRegex(lines[1], r"^2026/09/27/IMG_0001\.HEIC\t1200\t\d{4}-\d\d-\d\dT")

    def test_a_dry_run_notes_nothing(self) -> None:
        write_ledger(self.library, "2026/09/27/IMG_0001.HEIC\t1200")
        path = os.path.join(self.day, "IMG_0001.HEIC")
        graduated = graduation.Graduation(self.top)
        self.assertTrue(graduated.report_deletion(logging.getLogger("t"), path, [1200], True))
        self.assertFalse(os.path.exists(os.path.join(self.library, graduation.DELETIONS_NAME)))


class GraduatedDownloadTestCase(TestCase):
    @pytest.fixture(autouse=True)
    def inject_fixtures(self) -> None:
        self.root_path = path_from_project_root(__file__)
        self.fixtures_path = os.path.join(self.root_path, "fixtures")
        self.vcr_path = os.path.join(self.root_path, "vcr_cassettes")

    def folders(self, name: str) -> tuple[str, str]:
        base_dir = os.path.join(self.fixtures_path, name)
        cookie_dir = os.path.join(base_dir, "cookie")
        data_dir = os.path.join(base_dir, "data")
        for folder in [base_dir, data_dir]:
            recreate_path(folder)
        shutil.copytree(os.path.join(self.root_path, "cookie"), cookie_dir)
        return data_dir, cookie_dir

    def listing(self, data_dir: str, cookie_dir: str) -> Any:
        return run_cassette(
            os.path.join(self.vcr_path, "listing_photos.yml"),
            [*LISTING, "-d", data_dir, "--cookie-directory", cookie_dir],
        )

    def files(self, data_dir: str) -> list[str]:
        return sorted(
            os.path.relpath(os.path.join(folder, name), data_dir)
            for folder, _, names in os.walk(data_dir)
            for name in names
            if not name.startswith(".")
        )

    def test_graduated_files_are_not_downloaded_again(self) -> None:
        data_dir, cookie_dir = self.folders(inspect.stack()[0][3])
        write_ledger(
            data_dir,
            "2018/07/31/IMG_7409.JPG\t1884695\tmoved",
            "2018/07/31/IMG_7409.MOV\t3294075\tmoved",
        )
        result = self.listing(data_dir, cookie_dir)
        self.assertEqual(result.exit_code, 0, result.output)
        for name in ["IMG_7409.JPG", "IMG_7409.MOV"]:
            self.assertIn(
                f"{os.path.join(data_dir, os.path.normpath('2018/07/31/' + name))} already exists",
                result.output,
            )
        self.assertNotIn("Downloaded", result.output)
        self.assertEqual(self.files(data_dir), [])

    def test_another_photo_of_the_same_name_still_gets_its_suffix(self) -> None:
        data_dir, cookie_dir = self.folders(inspect.stack()[0][3])
        # What graduated under these names was another, smaller photo, so this
        # one comes down under the suffixed name, as it would have had the
        # other stayed in the folder.
        write_ledger(data_dir, "2018/07/31/IMG_7409.JPG\t1", "2018/07/31/IMG_7409.MOV\t1")
        orig_download = PhotoAsset.download
        downloaded: list[bool] = []

        def one_download(self: PhotoAsset, session: Any, _url: str, start: int) -> Response:
            if not downloaded:
                downloaded.append(True)
                return orig_download(self, session, _url, start)
            return mock.MagicMock()

        with mock.patch.object(PhotoAsset, "download", new=one_download):
            result = self.listing(data_dir, cookie_dir)
        self.assertEqual(result.exit_code, 0, result.output)
        # Paths are shortened in the log, so only the names are compared.
        for name in ["IMG_7409-1884695.JPG", "IMG_7409-3294075.MOV"]:
            self.assertIn(f"/{name} deduplicated", result.output)
        # Only suffixed names are written. The mocked second download may leave
        # an empty file, but never under a name that graduated.
        files = self.files(data_dir)
        self.assertIn(os.path.normpath("2018/07/31/IMG_7409-1884695.JPG"), files)
        self.assertLessEqual(
            set(files),
            {
                os.path.normpath("2018/07/31/IMG_7409-1884695.JPG"),
                os.path.normpath("2018/07/31/IMG_7409-3294075.MOV"),
            },
        )

    def test_a_photo_graduated_under_its_suffixed_name_is_not_downloaded_again(self) -> None:
        data_dir, cookie_dir = self.folders(inspect.stack()[0][3])
        write_ledger(
            data_dir,
            "2018/07/31/IMG_7409.JPG\t1",
            "2018/07/31/IMG_7409-1884695.JPG\t1884695",
            "2018/07/31/IMG_7409.MOV\t3294075",
        )
        result = self.listing(data_dir, cookie_dir)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertNotIn("Downloaded", result.output)
        self.assertEqual(self.files(data_dir), [])

    def test_a_damaged_ledger_stops_the_run_before_any_download(self) -> None:
        data_dir, cookie_dir = self.folders(inspect.stack()[0][3])
        with open(
            os.path.join(data_dir, graduation.LEDGER_NAME), "w", encoding="utf-8", newline="\n"
        ) as f:
            f.write(graduation.LEDGER_HEADER + "\n2018/07/31/IMG_7409.JPG\t18846")
        result = self.listing(data_dir, cookie_dir)
        self.assertNotEqual(result.exit_code, 0)
        self.assertIsInstance(result.exception, graduation.LedgerError)
        self.assertNotIn("Downloaded", result.output)
        self.assertEqual(self.files(data_dir), [])

    def test_auto_delete_notes_a_graduated_photo_deleted_on_the_phone(self) -> None:
        data_dir, cookie_dir = self.folders(inspect.stack()[0][3])
        write_ledger(
            data_dir,
            # In Recently Deleted, at the size it graduated at.
            "2018/07/30/IMG_7406.MOV\t2093808\tmoved",
            # Graduated under the name a second photo of that name gets.
            "2018/07/26/IMG_7383-55370.PNG\t55370\tmoved",
            # In Recently Deleted, but what graduated here was another photo.
            "2018/07/24/IMG_7378.PNG\t1\tmoved",
            # Not deleted on the phone.
            "2018/07/30/IMG_7407.JPG\t1\tmoved",
        )
        still_here = os.path.join(data_dir, "2018", "07", "23", "IMG_7331.PNG")
        os.makedirs(os.path.dirname(still_here))
        open(still_here, "w").close()

        def run() -> Any:
            return run_cassette(
                os.path.join(self.vcr_path, "autodelete_photos.yml"),
                [
                    "--username",
                    "jdoe@gmail.com",
                    "--password",
                    "password1",
                    "--recent",
                    "0",
                    "--skip-videos",
                    "--auto-delete",
                    "-d",
                    data_dir,
                    "--cookie-directory",
                    cookie_dir,
                ],
            )

        result = run()
        self.assertEqual(result.exit_code, 0, result.output)
        # A file still in the folder is deleted as before.
        self.assertIn(f"Deleted {still_here}", result.output)
        self.assertFalse(os.path.exists(still_here))
        deletions = os.path.join(data_dir, graduation.DELETIONS_NAME)
        with open(deletions, encoding="utf-8") as f:
            noted = [line.split("\t")[:2] for line in f.read().splitlines()[1:]]
        self.assertEqual(
            sorted(noted),
            [["2018/07/26/IMG_7383-55370.PNG", "55370"], ["2018/07/30/IMG_7406.MOV", "2093808"]],
        )
        self.assertIn("as deleted on the phone", result.output)

        again = run()
        self.assertEqual(again.exit_code, 0, again.output)
        with open(deletions, encoding="utf-8") as f:
            self.assertEqual(len(f.read().splitlines()), 3, "noted once, however often it runs")
