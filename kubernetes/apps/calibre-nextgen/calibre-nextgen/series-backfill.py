import argparse
from contextlib import closing
from pathlib import Path
import time

from cps import db
from cps.calibre_init import init_calibre_db_from_app_db
from cps.cwa_db_loader import load_cwa_db
from cps.metadata_helper import fetch_and_apply_metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="Fetch and save missing series")
    options = parser.parse_args()
    completed = Path("/config/.series-backfill-complete")
    if options.apply and completed.exists():
        print(f"Series backfill already completed. {completed.read_text().strip()}", flush=True)
        return

    settings_db = load_cwa_db().CWA_DB()
    with closing(settings_db.con):
        settings = settings_db.get_cwa_settings()
    enabled_fields = {
        name for name, enabled in settings.items()
        if name.startswith("auto_metadata_update_") and enabled
    }
    if not (settings["auto_metadata_fetch_enabled"]
            and settings["auto_metadata_smart_application"]
            and enabled_fields == {"auto_metadata_update_series"}):
        raise SystemExit("Expected automatic metadata fetching in Smart, Series-only mode")

    if not init_calibre_db_from_app_db("/config/app.db"):
        raise SystemExit("Could not open the NextGen library")

    library = db.CalibreDB(init=True)
    with closing(library.session):
        candidates = library.session.query(db.Books.id).filter(
            ~db.Books.series.any()
        ).order_by(db.Books.id).all()
    print(f"Books without a series: {len(candidates)}", flush=True)

    if not options.apply:
        return

    matched = 0
    for book_id, in candidates:
        matched += int(fetch_and_apply_metadata(book_id))
        time.sleep(1)
    summary = f"Series filled: {matched}; no update: {len(candidates) - matched}"
    completed.write_text(summary + "\n")
    print(summary, flush=True)


if __name__ == "__main__":
    main()
