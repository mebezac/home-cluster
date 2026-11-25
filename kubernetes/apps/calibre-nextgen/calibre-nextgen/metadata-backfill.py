import argparse
from contextlib import closing
from pathlib import Path
import time

from cps import cli_param, config, config_sql, db, ub
from cps.calibre_init import init_calibre_db_from_app_db
from cps.cwa_db_loader import load_cwa_db
from cps.metadata_helper import fetch_and_apply_metadata


APP_DB = "/config/app.db"
MARKER = Path("/config/.metadata-backfill-hardcover-complete")


def load_cps_config(app_db_path: str) -> None:
    ub.init_db(app_db_path)
    encrypt_key, error = config_sql.get_encryption_key(str(Path(app_db_path).parent))
    config_sql.load_configuration(ub.session, encrypt_key)
    config.init_config(ub.session, encrypt_key, cli_param)
    if error:
        print(f"WARN: {error}", flush=True)


def format_series(book) -> str:
    if not book or not book.series:
        return "none"
    name = book.series[0].name
    index = getattr(book, "series_index", None)
    return f"{name} #{index}" if index is not None else name


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="Fetch and fill missing metadata for all books")
    options = parser.parse_args()

    if options.apply and MARKER.exists():
        print(f"Metadata backfill already completed. {MARKER.read_text().strip()}", flush=True)
        return

    settings_db = load_cwa_db().CWA_DB()
    with closing(settings_db.con):
        settings = settings_db.get_cwa_settings()
    if not (settings["auto_metadata_fetch_enabled"] and settings["auto_metadata_smart_application"]):
        raise SystemExit("Expected automatic metadata fetching in Smart Application mode")

    load_cps_config(APP_DB)
    try:
        if not config.resolved_hardcover_token():
            raise SystemExit("HARDCOVER_TOKEN is not configured")
        if not init_calibre_db_from_app_db(APP_DB):
            raise SystemExit("Could not open the NextGen library")

        library = db.CalibreDB(init=True)
        with closing(library.session):
            books = (
                library.session.query(db.Books.id, db.Books.title)
                .order_by(db.Books.id)
                .all()
            )
        print(f"Books to check: {len(books)}", flush=True)

        if not options.apply:
            return

        updated = 0
        failed = 0
        for book_id, title in books:
            try:
                changed = bool(fetch_and_apply_metadata(book_id))
            except Exception as exc:
                failed += 1
                print(f"[{book_id}] {title!r} -> error: {exc}", flush=True)
                time.sleep(1)
                continue

            updated += int(changed)
            check_db = db.CalibreDB(init=True)
            with closing(check_db.session):
                book = check_db.get_book(book_id)
                series_info = format_series(book)
            status = "updated" if changed else "unchanged"
            print(f"[{book_id}] {title!r} -> {status} (series: {series_info})", flush=True)
            time.sleep(1)

        summary = (
            f"Backfill complete: {updated} updated, "
            f"{len(books) - updated - failed} unchanged, {failed} failed (total: {len(books)})"
        )
        MARKER.write_text(summary + "\n")
        print(summary, flush=True)
    finally:
        ub.dispose()


if __name__ == "__main__":
    main()
