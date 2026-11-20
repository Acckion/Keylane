import copy
import datetime
import pathlib
import runpy
import unittest

check = runpy.run_path(str(pathlib.Path(__file__).resolve().parents[2] / "scripts/check-store-release-inputs.py"))["check"]


class StoreReleaseInputTests(unittest.TestCase):
    now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)

    def inputs(self):
        team = "A1B2C3D4E5"
        bundle = "org.example.storeqa"
        app = team + "." + bundle
        identifier = "01234567-89AB-CDEF-0123-456789ABCDEF"
        host = {
            "com.apple.application-identifier": app,
            "com.apple.developer.team-identifier": team,
            "keychain-access-groups": [app],
        }
        profile = {
            "UUID": identifier, "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team],
            "ExpirationDate": datetime.datetime(2027, 1, 1),
            "Entitlements": {**host, "keychain-access-groups": [team + ".*"]},
        }
        helper = {"com.apple.security.virtualization": True}
        pin = {
            "team": team, "bundle": bundle, "app_identifier": app, "access_group": app, "profile_uuid": identifier,
            "recipe": "approved-synthetic", "runtime_digest": "1" * 64, "approver_public_key_digest": "2" * 64,
            "artifact_public_key_digest": "3" * 64, "guest_lock_digest": "4" * 64, "qualified_api_versions": ["1.0.0"],
        }
        return pin, profile, host, helper

    def test_exact_entitlements_and_authenticated_profile_export_match(self):
        check(*self.inputs(), self.now)

    def test_normal_project_entitlements_without_profile_do_not_qualify(self):
        pin, profile, _, helper = self.inputs()
        with self.assertRaisesRegex(ValueError, "profile UUID"):
            check(pin, {}, {}, helper, self.now)
        with self.assertRaisesRegex(ValueError, "host must request"):
            check(pin, profile, {"com.apple.security.device.camera": True}, helper, self.now)

    def test_wrong_team_expiry_group_and_debug_or_helper_authority_fail(self):
        original = self.inputs()
        for index, action, reason in (
            (1, lambda value: value.update(TeamIdentifier=["ZZZZZZZZZZ"]), "profile UUID"),
            (1, lambda value: value.update(ExpirationDate=self.now), "expiration"),
            (2, lambda value: value.update({"keychain-access-groups": ["*"]}), "host must request"),
            (2, lambda value: value.update({"com.apple.security.get-task-allow": True}), "debug"),
            (3, lambda value: value.update({"keychain-access-groups": ["unrelated"]}), "guest helper"),
        ):
            args = copy.deepcopy(original)
            action(args[index])
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, reason):
                check(*args, self.now)

    def test_empty_api_or_missing_release_asset_pin_cannot_pass(self):
        pin, profile, host, helper = self.inputs()
        with self.assertRaisesRegex(ValueError, "qualified Store API"):
            check({**pin, "qualified_api_versions": []}, profile, host, helper, self.now)
        with self.assertRaisesRegex(ValueError, "guest_lock_digest"):
            check({**pin, "guest_lock_digest": "missing"}, profile, host, helper, self.now)
