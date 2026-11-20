#!/usr/bin/env python3
"""Check Store release composition inputs, not signatures or authorization.

Input is a bounded JSON pin plus plists exported separately from an already
authenticated Apple profile and the intended host/helper signing configs.
This cannot prove CMS authenticity, sign/launch a bundle, or enable Store.
"""
import argparse
import datetime
import json
import pathlib
import plistlib
import re


def read(path, parser):
    with pathlib.Path(path).open("rb") as source:
        data = source.read(256 * 1024 + 1)
    if not data or len(data) > 256 * 1024:
        raise ValueError("missing or oversized release input")
    value = parser(data)
    if not isinstance(value, dict):
        raise ValueError("expected release metadata dictionary")
    return value


def check(pin, profile, host, helper, now):
    pins = {
        "team", "bundle", "app_identifier", "access_group", "profile_uuid",
        "recipe", "runtime_digest", "approver_public_key_digest",
        "artifact_public_key_digest", "guest_lock_digest", "qualified_api_versions",
    }
    if set(pin) != pins:
        raise ValueError("reviewed Store release pin fields do not match")
    team, bundle = pin["team"], pin["bundle"]
    if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("invalid signed team")
    if not isinstance(bundle, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,8}", bundle):
        raise ValueError("invalid signed host bundle")
    app_id, access = pin["app_identifier"], pin["access_group"]
    if app_id != access or not isinstance(app_id, str) or not app_id.endswith("." + bundle):
        raise ValueError("Store must use the host's exact private default Data Protection access group")
    prefix = app_id.removesuffix("." + bundle)
    if not re.fullmatch(r"[A-Z0-9]{10}", prefix):
        raise ValueError("invalid scoped App ID prefix")
    if not isinstance(pin["profile_uuid"], str) or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", pin["profile_uuid"]):
        raise ValueError("invalid reviewed provisioning profile UUID")
    if not isinstance(pin["recipe"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,63}", pin["recipe"]):
        raise ValueError("invalid qualified recipe")
    for key in ("runtime_digest", "approver_public_key_digest", "artifact_public_key_digest", "guest_lock_digest"):
        if not isinstance(pin[key], str) or not re.fullmatch(r"[a-f0-9]{64}", pin[key]):
            raise ValueError("missing or invalid verified " + key)
    versions = pin["qualified_api_versions"]
    if (not isinstance(versions, list) or not versions or len(versions) > 32
        or not all(isinstance(v, str) and re.fullmatch(r"[0-9]{1,6}(?:\.[0-9]{1,6}){2}", v) for v in versions)
        or len(set(versions)) != len(versions)):
        raise ValueError("requires explicit qualified Store API versions")
    if (profile.get("UUID") != pin["profile_uuid"] or profile.get("TeamIdentifier") != [team]
        or prefix not in profile.get("ApplicationIdentifierPrefix", [])):
        raise ValueError("profile UUID, team or app prefix does not match reviewed identity")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime) or expiration.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError("profile is missing a future expiration")
    allowed = profile.get("Entitlements")
    if (not isinstance(allowed, dict) or allowed.get("com.apple.application-identifier") != app_id
        or allowed.get("com.apple.developer.team-identifier") != team):
        raise ValueError("profile must authorize the exact host app identifier and team")
    allowed_groups = allowed.get("keychain-access-groups")
    if not isinstance(allowed_groups, list) or not (access in allowed_groups or prefix + ".*" in allowed_groups):
        raise ValueError("profile does not authorize the host's access group")
    if (host.get("com.apple.application-identifier") != app_id
        or host.get("com.apple.developer.team-identifier") != team or host.get("keychain-access-groups") != [access]):
        raise ValueError("host must request only its reviewed private Data Protection group")
    if host.get("com.apple.security.get-task-allow") is True or host.get("get-task-allow") is True:
        raise ValueError("debug entitlement is not a release authority")
    if host.get("com.apple.security.virtualization") is True or helper.get("com.apple.security.virtualization") is not True:
        raise ValueError("only the signed nested helper may request virtualization")
    if "keychain-access-groups" in helper or "com.apple.application-identifier" in helper:
        raise ValueError("guest helper must not claim the host's receipt keychain authority")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("pin", "profile", "host", "helper"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        check(read(args.pin, json.loads), read(args.profile, plistlib.loads),
              read(args.host, plistlib.loads), read(args.helper, plistlib.loads),
              datetime.datetime.now(datetime.timezone.utc))
    except (OSError, TypeError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit("Store release input preflight blocked: " + str(error))
    print("Store inputs consistent; profile CMS, final signatures and native qualification remain separate gates.")


if __name__ == "__main__":
    main()
