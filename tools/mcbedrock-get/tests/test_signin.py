from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
sys.modules.setdefault("gpsoauth", mock.Mock())
import mcbedrock_get  # noqa: E402
import signin  # noqa: E402


class AddressExtractionTests(unittest.TestCase):
    def test_reads_the_address_out_of_a_listaccounts_response(self):
        body = '[["gaia.l.a.r",1,"A Name","person@gmail.com","",null,1,1]]'
        self.assertEqual(signin.email_from_text(body), "person@gmail.com")

    def test_falls_back_to_an_unquoted_address_in_page_text(self):
        self.assertEqual(
            signin.email_from_text("You are signed in as person@example.co.uk now"),
            "person@example.co.uk",
        )

    def test_no_address_is_not_a_guess(self):
        self.assertEqual(signin.email_from_text("400. That's an error."), "")
        self.assertEqual(signin.email_from_text(""), "")


class ReadAccountTests(unittest.TestCase):
    def test_the_window_is_never_navigated(self):
        # Navigating it is what put Google's 400 page inside the sign-in window.
        window = mock.Mock()
        window.evaluate_js.return_value = "ok:person@gmail.com"
        signin.read_account_email(window)
        window.load_url.assert_not_called()

    def test_gives_up_as_soon_as_the_page_says_it_found_nothing(self):
        window = mock.Mock()
        window.evaluate_js.side_effect = ["", "none", "document text with no address"]
        self.assertEqual(signin.read_account_email(window), "")
        self.assertEqual(window.evaluate_js.call_count, 3)

    def test_scripting_failure_is_silent(self):
        window = mock.Mock()
        window.evaluate_js.side_effect = RuntimeError("scripting refused")
        self.assertEqual(signin.read_account_email(window, timeout_seconds=0), "")


class SingleSignInTests(unittest.TestCase):
    """The token from one sign-in must never be thrown away."""

    def setUp(self):
        self.credentials = signin.Credentials("person@gmail.com", "TOKEN")

    def test_detected_address_is_used_without_asking(self):
        with mock.patch.object(
            signin, "harvest_session", return_value=("person@gmail.com", "OAUTH")
        ), mock.patch.object(
            signin, "complete_login", return_value=self.credentials
        ) as complete, mock.patch.object(mcbedrock_get, "ask_for_address") as ask:
            mcbedrock_get.interactive_login()
        ask.assert_not_called()
        complete.assert_called_once_with("person@gmail.com", "OAUTH")

    def test_undetected_address_is_asked_for_and_the_same_token_is_used(self):
        with mock.patch.object(
            signin, "harvest_session", return_value=("", "OAUTH")
        ), mock.patch.object(
            signin, "complete_login", return_value=self.credentials
        ) as complete, mock.patch.object(
            mcbedrock_get, "ask_for_address", return_value="typed@gmail.com"
        ) as ask:
            mcbedrock_get.interactive_login()
        ask.assert_called_once_with()
        # Same sign-in, not a second one.
        complete.assert_called_once_with("typed@gmail.com", "OAUTH")

    def test_a_supplied_address_beats_detection(self):
        with mock.patch.object(
            signin, "harvest_session", return_value=("detected@gmail.com", "OAUTH")
        ), mock.patch.object(
            signin, "complete_login", return_value=self.credentials
        ) as complete:
            mcbedrock_get.interactive_login("chosen@gmail.com")
        complete.assert_called_once_with("chosen@gmail.com", "OAUTH")

    def test_cancelling_the_prompt_saves_nothing(self):
        with mock.patch.object(
            signin, "harvest_session", return_value=("", "OAUTH")
        ), mock.patch.object(signin, "complete_login") as complete, mock.patch.object(
            mcbedrock_get, "ask_for_address", return_value=""
        ):
            with self.assertRaises(signin.SignInError):
                mcbedrock_get.interactive_login()
        complete.assert_not_called()


if __name__ == "__main__":
    unittest.main()
