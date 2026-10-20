#!/usr/bin/env python3
"""
Generic container entrypoint: runs a challenge's unmodified app.py.

Importing app.py as a module skips its `if __name__ == "__main__":` block,
which is where small Flask apps usually do one-time setup (creating a
database, writing a flag file). Without that, a sqlite-backed app returns
500 "no such table". So this calls whichever common setup function the app
defines before serving.

Binds 0.0.0.0 so Docker's port mapping can reach it; threaded=True so one
student's slow request doesn't block everyone else.
"""
import importlib
import os

m = importlib.import_module("app")

for name in ("setup", "init_db", "write_flag"):
    if hasattr(m, name):
        getattr(m, name)()

m.app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5000")), threaded=True)
