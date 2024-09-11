"""
Takes a func test target name as input.

 - Exit return code 0 == voting
 - Exit return code 1 == non-voting
"""
import os
import sys

import yaml

if __name__ == "__main__":
    target_name = sys.argv[1]
    if not os.path.exists('osci.yaml'):
        sys.stderr.write(f"ERROR: osci.yaml not found - assuming "
                         f"{target_name} is voting.\n")
        sys.exit(0)

    with open('osci.yaml', encoding='utf-8') as fd:
        osci_config = yaml.safe_load(fd)

    try:
        jobs = osci_config[0]['project']['check']['jobs']
        if target_name in jobs:
            # default is voting=True
            sys.exit(0)

        for check in jobs:
            if isinstance(check, dict) and target_name in check:
                if not check[target_name]['voting']:
                    sys.exit(1)
    except KeyError as exc:
        sys.stderr.write(f"ERROR: failed to process osci.yaml - assuming "
                         f"{target_name} is voting (key {exc} not found).\n")