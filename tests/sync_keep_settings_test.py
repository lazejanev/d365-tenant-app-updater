"""Tests for scripts/sync_keep_settings.py (run by CI: python3 tests/sync_keep_settings_test.py)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from sync_keep_settings import keep  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..")
released = open(os.path.join(ROOT, "azure-pipelines.yml"), encoding="utf-8").read()
federated = open(os.path.join(ROOT, "pipelines", "azure-pipelines-federated.yml"), encoding="utf-8").read()

COMMENTED = """# schedules:
#   - cron: '0 2 * * *'
#     displayName: 'Scheduled tenant app update'
#     branches:
#       include:
#         - main
#     always: true
"""
ACTIVE = """schedules:
  - cron: '0 3 * * *'
    displayName: 'Nightly'
    branches:
      include:
        - main
    always: true
"""
assert COMMENTED in released, "the released pipeline no longer has the commented schedule this test expects"

# A user who changed nothing keeps the released file unchanged.
same, kept = keep(released, released)
assert same == released and kept == [], kept

# A user's approval environment and schedule are carried over.
user = released.replace("    default: none\n", "    default: d365-production\n", 1).replace(COMMENTED, ACTIVE)
out, kept = keep(user, released)
assert out == user, "user settings not carried over exactly"
assert kept == ["productionApprovalEnvironment default: d365-production", "schedules"], kept

# Running it twice changes nothing more.
again, kept = keep(user, out)
assert again == out and kept == [], kept

# The federated service connection is carried over.
fuser = federated.replace("value: 'd365-tenant-app-updater-wif'", "value: 'my-connection'")
fout, kept = keep(fuser, federated)
assert fout == fuser and kept == ["serviceConnection: 'my-connection'"], kept

print("sync_keep_settings: all tests passed")
