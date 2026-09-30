"""Validates scenario files against priv/scenario.schema.json.

    pip install jsonschema
    python3 scripts/check_schema.py [FILE ...]   # default: priv/scenarios/*.json
"""

import glob
import json
import sys

import jsonschema

schema = json.load(open("priv/scenario.schema.json"))
validator = jsonschema.Draft7Validator(schema)
files = sys.argv[1:] or sorted(glob.glob("priv/scenarios/*.json"))
failed = False

for path in files:
    errors = list(validator.iter_errors(json.load(open(path))))
    for error in errors[:5]:
        location = ".".join(str(part) for part in error.absolute_path) or "(root)"
        print(f"{path}: {location}: {error.message}")
    failed = failed or bool(errors)

print(f"{len(files)} files checked against the scenario schema")
sys.exit(1 if failed else 0)
